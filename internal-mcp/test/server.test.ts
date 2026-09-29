import test from "node:test";
import assert from "node:assert/strict";
import {
  readFile,
  mkdtemp,
  writeFile,
  mkdir,
  symlink,
  rm,
} from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { buildSchema, parse, validate, getVariableValues } from "graphql";
import { harness, token } from "./helpers.js";
import { LinearService } from "../src/linear/service.js";
import { GraphQLClient, type LinearClient } from "../src/linear/client.js";
import { bodyHash } from "../src/linear/patch.js";
import { validateStatement } from "../src/database.js";
const schema = buildSchema(
  await readFile(
    new URL("./fixtures/linear-schema.graphql", import.meta.url),
    "utf8",
  ),
);
const ID = "11111111-1111-4111-8111-111111111111",
  SECOND = "22222222-2222-4222-8222-222222222222";
class FakeLinear implements LinearClient {
  calls: { query: string; vars: Record<string, any>; write: boolean }[] = [];
  body = "complete body";
  ambiguous = false;
  uploadCount = 0;
  writes = 0;
  async request<T = Record<string, any>>(
    query: string,
    vars: Record<string, any> = {},
    write = false,
  ): Promise<T> {
    const errors = validate(schema, parse(query)).map((e) => e.message);
    if (errors.length) console.error(errors, query);
    assert.deepEqual(errors, [], query);
    const op = parse(query).definitions.find(
      (d) => d.kind === "OperationDefinition",
    ) as any;
    const checked = getVariableValues(
      schema,
      op.variableDefinitions ?? [],
      vars,
    );
    assert.equal(checked.errors, undefined, JSON.stringify(checked.errors));
    this.calls.push({ query, vars, write });
    if (write) this.writes++;
    let result: any;
    if (query.includes("query ResolveIssue")) result = { issue: { id: ID } };
    else if (query.includes("query Resolve")) {
      const plural = /\{\s*(\w+)\(first/.exec(query)![1]!;
      result = {
        [plural]: {
          nodes: this.ambiguous
            ? [
                { id: ID, name: "Duplicate" },
                { id: SECOND, name: "Duplicate" },
              ]
            : [
                {
                  id: ID,
                  name: "Name",
                  key: "LAB",
                  email: "operator@example.test",
                },
              ],
          pageInfo: { hasNextPage: false, endCursor: null },
        },
      };
    } else if (query.includes("query Get")) {
      const singular = /\{\s*(\w+)\(id/.exec(query)![1]!;
      result = {
        [singular]: {
          id: ID,
          description: this.body,
          content: this.body,
          title: "Title",
          team: { id: ID, name: "Lab", key: "LAB" },
          secret: "never forward",
        },
      };
    } else if (query.includes("query List")) {
      const plural = /\{\s*(\w+)\(first/.exec(query)![1]!;
      result = {
        [plural]: {
          nodes: [{ id: ID, name: "Name", secret: "never forward" }],
          pageInfo: { hasNextPage: true, endCursor: "next" },
        },
      };
    } else if (query.includes("mutation Write")) {
      const op = /\{\s*(\w+)\(input/.exec(query)![1]!,
        singular = op.replace(/(Create|Update)$/, "");
      if (vars.input.description !== undefined)
        this.body = vars.input.description;
      if (vars.input.content !== undefined) this.body = vars.input.content;
      result = {
        [op]: {
          success: true,
          [singular]: { id: ID, ...vars.input, secret: "never forward" },
        },
      };
    } else if (query.includes("mutation Upload"))
      result = {
        fileUpload: {
          success: true,
          uploadFile: {
            uploadUrl: "https://uploads.linear.app/test",
            assetUrl: "https://uploads.linear.app/asset",
            headers: [],
          },
        },
      };
    else if (query.includes("mutation Attach"))
      result = {
        attachmentCreate: {
          success: true,
          attachment: { id: ID, title: vars.input.title, url: vars.input.url },
        },
      };
    else if (query.includes("query Dependencies"))
      result = {
        issue: {
          relations: {
            nodes: [],
            pageInfo: { hasNextPage: false, endCursor: null },
          },
        },
      };
    else if (query.includes("mutation Dependency"))
      result = {
        issueRelationCreate: {
          success: true,
          issueRelation: { id: ID, type: "blocks" },
        },
      };
    else if (query.includes("query Relation"))
      result = {
        issueRelation: {
          id: ID,
          type: "blocks",
          issue: { id: ID },
          relatedIssue: { id: SECOND },
        },
      };
    else if (query.includes("mutation RemoveDependency"))
      result = { issueRelationDelete: { success: true } };
    else throw new Error("Unhandled test operation");
    return result;
  }
  async upload() {
    this.uploadCount++;
  }
}

test("every HTTP method needs authentication; sessions remain independent; logs exclude payloads", async (t) => {
  const h = await harness({
    database: {
      query: async () => ({
        rows: [],
        columns: [],
        rowCount: 0,
        truncated: false,
        truncationNotice: null,
      }),
    },
  });
  t.after(h.close);
  for (const method of ["GET", "POST", "DELETE", "OPTIONS"]) {
    assert.equal((await fetch(h.url, { method })).status, 401);
    assert.equal(
      (
        await fetch(h.url, {
          method,
          headers: { Authorization: "Bearer wrong" },
        })
      ).status,
      401,
    );
  }
  await assert.rejects(h.connect("wrong"));
  assert.equal(
    (
      await fetch(h.url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          Origin: "https://evil.test",
        },
      })
    ).status,
    403,
  );
  const second = await h.connect();
  assert.notEqual(second.transport.sessionId, h.transport.sessionId);
  assert.equal((await h.call("health")).value.status, "ok");
  await h.call("query", { sql: "SELECT secret_payload" });
  const log = JSON.stringify(h.logs);
  assert(!log.includes(token));
  assert(!log.includes("secret_payload"));
  assert(log.includes('"tool":"query"'));
  await h.transport.terminateSession();
  assert.equal(
    (await second.client.callTool({ name: "health", arguments: {} })).isError,
    undefined,
  );
});

test("discovery is local; upstream HTTP/GraphQL/timeout errors are explicit and writes never retry", async (t) => {
  let calls = 0;
  const api = new GraphQLClient("upstream-secret", async () => {
    calls++;
    return new Response("private error", { status: 503 });
  });
  const h = await harness({ linear: new LinearService(api, "/unused") });
  t.after(h.close);
  const tools = await h.client.listTools();
  assert(tools.tools.some((t) => t.name === "linear_issue_create"));
  assert.equal(calls, 0);
  const result = await h.call("linear_issue_create", {
    title: "Test",
    team: ID,
  });
  assert(result.error);
  assert.equal(result.value.code, "LINEAR_HTTP_ERROR");
  assert.equal(calls, 1);
  assert.match(result.value.outcome, /unknown/);
  assert(!JSON.stringify(result).includes("upstream-secret"));
  for (const fetcher of [
    async () =>
      new Response(
        JSON.stringify({
          errors: [{ message: "private", extensions: { code: "FORBIDDEN" } }],
        }),
      ),
    async () => {
      throw new Error("secret timeout");
    },
  ]) {
    const s = await harness({
      linear: new LinearService(
        new GraphQLClient("key", fetcher as typeof fetch),
        "/unused",
      ),
    });
    try {
      const r = await s.call("linear_project_get", { ref: ID });
      assert(r.error);
      assert(!JSON.stringify(r).includes("private"));
      assert(!JSON.stringify(r).includes("secret timeout"));
    } finally {
      await s.close();
    }
  }
});

test("all published tools use valid GraphQL selections and allowlisted results", async (t) => {
  const fake = new FakeLinear(),
    h = await harness({ linear: new LinearService(fake, "/unused") });
  t.after(h.close);
  for (const kind of [
    "issue",
    "project",
    "comment",
    "document",
    "milestone",
    "status_update",
    "team",
    "user",
    "cycle",
    "workflow_state",
    "label",
  ]) {
    for (const op of ["get", "list"]) {
      const r = await h.call(
        `linear_${kind}_${op}`,
        op === "get" ? { ref: ID } : {},
      );
      assert(!r.error, JSON.stringify(r.value));
      assert(!JSON.stringify(r).includes("never forward"));
    }
  }
  const creates = {
    issue: {
      title: "X",
      team: "LAB",
      state: "Todo",
      assignee: "operator@example.test",
      project: "Project",
      cycle: "Cycle",
      labels: ["Label"],
    },
    project: { name: "X", teams: ["LAB"] },
    comment: { body: "Text", issue: "LAB-1" },
    document: { title: "X", content: "Text", project: "Project" },
    milestone: { name: "M", project: "Project" },
    status_update: { body: "Text", project: "Project", health: "onTrack" },
    label: { name: "Label", team: "LAB" },
  };
  for (const [kind, input] of Object.entries(creates)) {
    const r = await h.call(`linear_${kind}_create`, input);
    assert(!r.error, JSON.stringify(r.value));
    if (kind !== "label") {
      const update =
        kind === "comment"
          ? { body: "new" }
          : kind === "status_update"
            ? { body: "new", health: "atRisk" }
            : kind === "document"
              ? { title: "new" }
              : kind === "issue"
                ? { title: "new" }
                : { name: "new" };
      const u = await h.call(`linear_${kind}_update`, { ref: ID, ...update });
      assert(!u.error, JSON.stringify(u.value));
    }
  }
  for (const [kind, args] of [
    ["project", { team: "LAB", search: "Name" }],
    ["issue", { team: "LAB", project: "Project", search: "Title" }],
    ["document", { project: "Project", issue: "LAB-1" }],
    ["comment", { issue: "LAB-1" }],
    ["milestone", { project: "Project" }],
    ["status_update", { project: "Project" }],
    ["workflow_state", { team: "LAB", search: "Todo" }],
    ["label", { team: "LAB" }],
    ["cycle", { team: "LAB" }],
  ] as const) {
    const r = await h.call(`linear_${kind}_list`, args);
    assert(!r.error, JSON.stringify(r.value));
  }
  for (const [name, args] of [
    ["linear_dependencies_list", { issue: ID }],
    ["linear_dependency_add", { issue: ID, blockedIssue: SECOND }],
    [
      "linear_dependency_remove",
      { issue: ID, blockedIssue: SECOND, relationId: ID },
    ],
  ] as const) {
    const r = await h.call(name, args);
    assert(!r.error, JSON.stringify(r.value));
  }
  assert((await h.call("linear_issue_list", { limit: 51 })).error);
});

test("ambiguous human references return candidates and never write", async (t) => {
  const fake = new FakeLinear();
  fake.ambiguous = true;
  const h = await harness({ linear: new LinearService(fake, "/unused") });
  t.after(h.close);
  const result = await h.call("linear_issue_create", {
    title: "X",
    team: "LAB",
  });
  assert(result.error);
  assert.equal(result.value.code, "AMBIGUOUS_REFERENCE");
  assert.equal(result.value.candidates.length, 2);
  assert.equal(fake.writes, 0);
});

test("patches use full bodies; all anchors validate before any write", async (t) => {
  const fake = new FakeLinear();
  fake.body = "a".repeat(9000) + "unique tail";
  const h = await harness({ linear: new LinearService(fake, "/unused") });
  t.after(h.close);
  const read = await h.call("linear_issue_get", { ref: ID });
  assert(read.value.textTruncated);
  assert.equal(read.value.data.description.length, 8000);
  for (const patches of [
    [{ anchor: "missing", replacement: "X" }],
    [{ anchor: "a", replacement: "X" }],
    [
      { anchor: "unique tail", replacement: "X" },
      { anchor: "tail", replacement: "Y" },
    ],
    [
      { anchor: "unique tail", replacement: "X" },
      { anchor: "missing", replacement: "Y" },
    ],
  ]) {
    const r = await h.call("linear_issue_patch", {
      ref: ID,
      expectedHash: bodyHash(fake.body),
      patches,
    });
    assert(r.error);
    assert.equal(fake.writes, 0);
  }
  const conflict = await h.call("linear_issue_patch", {
    ref: ID,
    expectedHash: bodyHash("stale"),
    patches: [{ anchor: "unique tail", replacement: "X" }],
  });
  assert(conflict.error);
  const r = await h.call("linear_issue_patch", {
    ref: ID,
    expectedHash: read.value.data.bodyHash,
    patches: [{ anchor: "unique tail", replacement: "changed" }],
  });
  assert(!r.error);
  assert.equal(fake.body, "a".repeat(9000) + "changed");
  const d = await h.call("linear_document_patch", {
    ref: ID,
    expectedHash: bodyHash(fake.body),
    patches: [{ anchor: "changed", replacement: "document" }],
  });
  assert(!d.error);
  assert(fake.body.endsWith("document"));
});

test("attachment traversal, symlinks, content types and sizes are rejected before upload", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "labapp-files-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const uploads = path.join(root, "uploads");
  await mkdir(uploads);
  await writeFile(path.join(root, "outside.txt"), "private");
  await writeFile(path.join(uploads, "good.txt"), "hello");
  await symlink(path.join(root, "outside.txt"), path.join(uploads, "link.txt"));
  await symlink(
    path.join(uploads, "good.txt"),
    path.join(uploads, "inside.txt"),
  );
  await writeFile(path.join(uploads, "fake.png"), "not a png");
  await writeFile(path.join(uploads, "bad.txt"), Buffer.from([0, 1, 2]));
  await writeFile(
    path.join(uploads, "large.txt"),
    Buffer.alloc(10 * 1024 * 1024 + 1),
  );
  const fake = new FakeLinear(),
    h = await harness({ linear: new LinearService(fake, uploads) });
  t.after(h.close);
  for (const file of [
    "../outside.txt",
    "link.txt",
    "inside.txt",
    "fake.png",
    "bad.txt",
    "large.txt",
    ".",
    "missing.txt",
  ]) {
    const r = await h.call("linear_attachment_upload", {
      issue: ID,
      path: file,
    });
    assert(r.error, file);
    assert.equal(fake.uploadCount, 0);
    assert.equal(fake.writes, 0);
  }
  const result = await h.call("linear_attachment_upload", {
    issue: ID,
    path: "good.txt",
  });
  assert(!result.error, JSON.stringify(result.value));
  assert.equal(fake.uploadCount, 1);
  assert.equal(fake.writes, 2);
});

test("SQL parser handles comments, quoted semicolons and multiple statements", async () => {
  for (const sql of [
    "select ';'",
    "/* comment; */ SELECT $1",
    "select $$;$$",
    "select 1; -- comment",
  ])
    await validateStatement(sql);
  for (const sql of [
    "select 1;select 2",
    "-- nothing",
    "BEGIN",
    "SET ROLE admin",
  ])
    await assert.rejects(validateStatement(sql));
});
