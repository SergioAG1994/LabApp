import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Database } from "./database.js";
import type { LinearService } from "./linear/service.js";
import { entities, display, type Entity } from "./linear/entities.js";
import { publicError } from "./errors.js";
export type Log = (entry: Record<string, unknown>) => void;
export interface Dependencies {
  database?: Database;
  linear?: LinearService;
  log: Log;
}
const ref = z.string().trim().min(1).max(300);
const short = z.string().min(1).max(500);
const body = z.string().max(1_000_000);
const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
export function createTools(deps: Dependencies) {
  const server = new McpServer({ name: "labapp-internal", version: "0.1.0" });
  function register(
    name: string,
    description: string,
    schema: z.ZodRawShape,
    readOnly: boolean,
    handler: (args: any) => Promise<any>,
  ) {
    server.registerTool(
      name,
      {
        description,
        inputSchema: z.strictObject(schema),
        annotations: {
          readOnlyHint: readOnly,
          destructiveHint: !readOnly,
          idempotentHint: readOnly,
          openWorldHint: true,
        },
      },
      async (args) => {
        const start = performance.now();
        let status = "ok";
        try {
          const result = await handler(args);
          return {
            content: [{ type: "text" as const, text: JSON.stringify(result) }],
            structuredContent: result,
          };
        } catch (error) {
          status = "error";
          const result = display(publicError(error));
          return {
            isError: true,
            content: [
              { type: "text" as const, text: JSON.stringify(result.data) },
            ],
            structuredContent: result,
          };
        } finally {
          deps.log({
            event: "tool",
            tool: name,
            status,
            latencyMs: Math.round(performance.now() - start),
          });
        }
      },
    );
  }
  register(
    "health",
    "Local server readiness and configured capabilities. Does not claim upstream connectivity.",
    {},
    true,
    async () => ({
      status: "ok",
      databaseConfigured: !!deps.database,
      linearConfigured: !!deps.linear,
      upstreams: "not probed",
    }),
  );
  if (deps.database)
    register(
      "query",
      "Run one PostgreSQL query with $1 positional parameters. SELECT-only database grants enforce access. Results are capped at 1,000 rows / 1 MB, not database work. rowCount counts all result rows. 15-second statement timeout.",
      {
        sql: z.string().min(1).max(100_000),
        params: z.array(z.json()).max(100).optional(),
      },
      true,
      async (a) => deps.database!.query(a.sql, a.params),
    );
  const linear = deps.linear;
  if (!linear) return server;
  for (const kind of Object.keys(entities) as Entity[]) {
    register(
      `linear_${kind}_get`,
      `Read a ${kind}. Accepts UUIDs and human references; ambiguity returns candidates. Issue/document bodyHash covers the complete body even if display is truncated.`,
      { ref, team: ref.optional() },
      true,
      async (a) => display(await linear.get(kind, a.ref, a.team)),
    );
    register(
      `linear_${kind}_list`,
      `List/search ${kind} objects. Names/titles use substring search; use parent filters for comments/status updates. Returned text and pages are bounded.`,
      {
        limit: z.number().int().min(1).max(50).default(25),
        after: z.string().max(1000).optional(),
        search: ref.optional(),
        team: ref.optional(),
        project: ref.optional(),
        issue: ref.optional(),
      },
      true,
      async (a) => display(await linear.list(kind, a)),
    );
  }
  const issueFields = {
    title: short,
    description: body,
    team: ref,
    project: ref.nullable(),
    assignee: ref.nullable(),
    state: ref,
    cycle: ref.nullable(),
    labels: z.array(ref).max(50),
    priority: z.number().int().min(0).max(4),
    dueDate: date.nullable(),
  };
  const projectFields = {
    name: short,
    description: z.string().max(255),
    content: body,
    teams: z.array(ref).min(1).max(20),
    lead: ref.nullable(),
    targetDate: date.nullable(),
  };
  const schemas: Partial<
    Record<Entity, { fields: Record<string, z.ZodType>; required: string[] }>
  > = {
    issue: { fields: issueFields, required: ["title", "team"] },
    project: { fields: projectFields, required: ["name", "teams"] },
    comment: { fields: { body, issue: ref }, required: ["body", "issue"] },
    document: {
      fields: { title: short, content: body, project: ref },
      required: ["title", "project"],
    },
    milestone: {
      fields: {
        name: short,
        description: body,
        project: ref,
        targetDate: date.nullable(),
      },
      required: ["name", "project"],
    },
    status_update: {
      fields: {
        body,
        project: ref,
        health: z.enum(["onTrack", "atRisk", "offTrack"]),
      },
      required: ["body", "project"],
    },
    label: {
      fields: {
        name: short,
        team: ref,
        description: z.string().max(1000),
        color: z.string().regex(/^#[0-9a-f]{6}$/i),
      },
      required: ["name", "team"],
    },
  };
  for (const [kind, config] of Object.entries(schemas)) {
    const create = Object.fromEntries(
      Object.entries(config.fields).map(([k, v]) => [
        k,
        config.required.includes(k) ? v : v.optional(),
      ]),
    );
    register(
      `linear_${kind}_create`,
      `Create ${kind}. Resolves names on the server. Writes are never automatically retried; after timeout inspect Linear before retrying.`,
      create,
      false,
      async (a) => display(await linear.write(kind as Entity, a)),
    );
    if (kind === "label") continue;
    const update = Object.fromEntries(
      Object.entries(config.fields)
        .filter(
          ([k]) =>
            !(
              (kind === "comment" && k === "issue") ||
              (kind === "status_update" && k === "project")
            ),
        )
        .map(([k, v]) => [k, v.optional()]),
    );
    register(
      `linear_${kind}_update`,
      `Update explicit ${kind} fields. No automatic retries. Use anchored patches for issue/document body edits.`,
      { ref, ...update },
      false,
      async ({ ref, ...input }) =>
        display(await linear.write(kind as Entity, input, ref)),
    );
  }
  for (const kind of ["issue", "document"] as const)
    register(
      `linear_${kind}_patch`,
      "Patch the complete body using unique exact anchors and its expected SHA-256 bodyHash. All operations refer to the original body and must not overlap. Reads again before writing; Linear has no atomic compare-and-swap, so concurrent edits can still race. No automatic retries.",
      {
        ref,
        expectedHash: z.string().regex(/^[a-f0-9]{64}$/),
        patches: z
          .array(
            z.strictObject({
              anchor: z.string().min(1).max(100_000),
              replacement: body,
            }),
          )
          .min(1)
          .max(50),
      },
      false,
      async (a) =>
        display(await linear.patch(kind, a.ref, a.patches, a.expectedHash)),
    );
  register(
    "linear_dependencies_list",
    "List outgoing issue relationships with relation UUIDs. A blocks B means A must finish before B.",
    {
      issue: ref,
      after: z.string().max(1000).optional(),
      limit: z.number().int().min(1).max(50).default(25),
    },
    true,
    async (a) => display(await linear.dependencies(a.issue, a.after, a.limit)),
  );
  register(
    "linear_dependency_add",
    "Add A blocks B. No automatic retries.",
    { issue: ref, blockedIssue: ref },
    false,
    async (a) =>
      display(await linear.dependency("add", a.issue, a.blockedIssue)),
  );
  register(
    "linear_dependency_remove",
    "Remove only the specified blocks dependency after verifying both endpoints.",
    { issue: ref, blockedIssue: ref, relationId: z.string().uuid() },
    false,
    async (a) =>
      display(
        await linear.dependency(
          "remove",
          a.issue,
          a.blockedIssue,
          a.relationId,
        ),
      ),
  );
  register(
    "linear_attachment_upload",
    "Upload a local file from the configured allowed directory and attach it to an issue. Maximum 10 MiB. No symlinks, arbitrary URLs, or base64 arguments. No automatic retry at any stage.",
    { issue: ref, path: z.string().min(1).max(1000), title: short.optional() },
    false,
    async (a) => display(await linear.attach(a.issue, a.path, a.title)),
  );
  return server;
}
