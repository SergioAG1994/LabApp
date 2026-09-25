import type { LinearClient } from "./client.js";
import { metadata, selection, pick, type Entity } from "./entities.js";
import { bodyHash, patchBody, type Patch } from "./patch.js";
import { readAttachment } from "./files.js";
import { ToolError } from "../errors.js";
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export class LinearService {
  constructor(
    private client: LinearClient,
    private uploadDirectory: string,
  ) {}
  async get(kind: Entity, ref: string, team?: string): Promise<any> {
    const id = await this.resolve(kind, ref, team),
      m = metadata(kind);
    const data = await this.client.request(
      `query Get($id:String!){ ${m.singular}(id:$id){ ${selection(m.shape)} } }`,
      { id },
    );
    const result = pick(data[m.singular], m.shape);
    if (!result) throw new ToolError("NOT_FOUND", "Linear object not found.");
    if (kind === "issue" || kind === "document")
      result.bodyHash = bodyHash(
        result[kind === "issue" ? "description" : "content"] ?? "",
      );
    return result;
  }
  async list(
    kind: Entity,
    args: {
      limit: number;
      after?: string;
      search?: string;
      team?: string;
      project?: string;
      issue?: string;
    },
  ): Promise<any> {
    const m = metadata(kind),
      filter: Record<string, unknown> = {};
    if (args.search) {
      if (kind === "issue" || kind === "document")
        filter[kind === "issue" ? "title" : "title"] = {
          containsIgnoreCase: args.search,
        };
      else if (
        [
          "project",
          "team",
          "user",
          "cycle",
          "workflow_state",
          "label",
          "milestone",
        ].includes(kind)
      )
        filter.name = { containsIgnoreCase: args.search };
      else
        throw new ToolError(
          "INVALID_FILTER",
          "Search is not supported for this entity; scope it to a parent.",
        );
    }
    if (args.team) {
      const id = await this.resolve("team", args.team);
      if (kind === "project")
        filter.accessibleTeams = { some: { id: { eq: id } } };
      else if (
        ["issue", "cycle", "workflow_state", "label", "document"].includes(kind)
      )
        filter.team = { id: { eq: id } };
      else
        throw new ToolError(
          "INVALID_FILTER",
          "This entity does not support team filtering.",
        );
    }
    if (args.project) {
      if (
        ![
          "issue",
          "document",
          "milestone",
          "status_update",
          "comment",
        ].includes(kind)
      )
        throw new ToolError(
          "INVALID_FILTER",
          "This entity does not support project filtering.",
        );
      filter.project = {
        id: { eq: await this.resolve("project", args.project) },
      };
    }
    if (args.issue) {
      if (!["comment", "document"].includes(kind))
        throw new ToolError(
          "INVALID_FILTER",
          "This entity does not support issue filtering.",
        );
      filter.issue = { id: { eq: await this.resolve("issue", args.issue) } };
    }
    const data = await this.client.request(
      `query List($first:Int!,$after:String,$filter:${m.type}Filter){ ${m.plural}(first:$first,after:$after,filter:$filter){ nodes { ${selection(m.shape)} } pageInfo { hasNextPage endCursor } } }`,
      { first: args.limit, after: args.after, filter },
    );
    const connection = data[m.plural];
    if (!connection || !Array.isArray(connection.nodes))
      throw new ToolError(
        "LINEAR_RESPONSE_INVALID",
        "Linear returned an invalid list.",
      );
    return {
      items: connection.nodes
        .slice(0, args.limit)
        .map((x: any) => pick(x, m.shape)),
      hasMore: connection.pageInfo.hasNextPage,
      nextCursor: connection.pageInfo.endCursor,
      truncated:
        connection.pageInfo.hasNextPage || connection.nodes.length > args.limit,
      truncationNotice: connection.pageInfo.hasNextPage
        ? "More results are available; pass nextCursor as after."
        : null,
    };
  }
  async resolve(kind: Entity, ref: string, team?: string): Promise<string> {
    if (uuid.test(ref)) return ref;
    if (kind === "issue" && /^[A-Za-z][A-Za-z0-9]*-\d+$/.test(ref)) {
      const data = await this.client.request(
        "query ResolveIssue($id:String!){ issue(id:$id){ id } }",
        { id: ref },
      );
      if (!data.issue?.id) throw new ToolError("NOT_FOUND", "Issue not found.");
      return data.issue.id;
    }
    if (["comment", "status_update"].includes(kind))
      throw new ToolError(
        "INVALID_REFERENCE",
        "Use the object UUID for this entity.",
      );
    const m = metadata(kind);
    const field =
      kind === "team"
        ? "key"
        : kind === "user" && ref.includes("@")
          ? "email"
          : kind === "document"
            ? "title"
            : kind === "issue"
              ? "title"
              : "name";
    const filter: Record<string, unknown> = { [field]: { eqIgnoreCase: ref } };
    if (
      team &&
      ["issue", "cycle", "workflow_state", "label", "document"].includes(kind)
    ) {
      const teamId = await this.resolve("team", team);
      filter.team =
        kind === "label"
          ? { or: [{ id: { eq: teamId } }, { null: true }] }
          : { id: { eq: teamId } };
    }
    const candidateShape = {
      id: true,
      [field]: true,
      ...(["workflow_state", "cycle", "label"].includes(kind)
        ? { team: { id: true, name: true, key: true } }
        : {}),
    } as any;
    const data = await this.client.request(
      `query Resolve($filter:${m.type}Filter!){ ${m.plural}(first:50,filter:$filter){ nodes { ${selection(candidateShape)} } pageInfo { hasNextPage endCursor } } }`,
      { filter },
    );
    const connection = data[m.plural],
      candidates = connection?.nodes;
    if (!Array.isArray(candidates))
      throw new ToolError(
        "LINEAR_RESPONSE_INVALID",
        "Linear returned invalid reference candidates.",
      );
    if (candidates.length === 0)
      throw new ToolError("NOT_FOUND", `No ${kind} matches the reference.`);
    if (candidates.length !== 1 || connection.pageInfo.hasNextPage)
      throw new ToolError(
        "AMBIGUOUS_REFERENCE",
        `Reference matches multiple ${kind} objects; use an explicit UUID.`,
        {
          candidates: candidates
            .slice(0, 50)
            .map((x: any) => pick(x, candidateShape)),
          truncated: connection.pageInfo.hasNextPage,
        },
      );
    return candidates[0].id;
  }
  async write(
    kind: Entity,
    input: Record<string, any>,
    ref?: string,
  ): Promise<any> {
    const m = metadata(kind),
      id = ref ? await this.resolve(kind, ref, input.team) : undefined;
    const mapped: Record<string, unknown> = { ...input };
    let team = input.team;
    if (
      kind === "issue" &&
      ref &&
      !team &&
      (input.state || input.cycle || input.labels)
    ) {
      const issue = await this.get("issue", id!);
      team = issue.team.id;
    }
    for (const [field, entity, target] of [
      ["team", "team", "teamId"],
      ["project", "project", "projectId"],
      ["issue", "issue", "issueId"],
      ["assignee", "user", "assigneeId"],
      ["lead", "user", "leadId"],
      ["state", "workflow_state", "stateId"],
      ["cycle", "cycle", "cycleId"],
    ] as const) {
      if (field in input) {
        mapped[target] =
          input[field] === null
            ? null
            : await this.resolve(entity, input[field], team);
        delete mapped[field];
      }
    }
    if (input.teams) {
      mapped.teamIds = await Promise.all(
        input.teams.map((r: string) => this.resolve("team", r)),
      );
      delete mapped.teams;
    }
    if (input.labels) {
      mapped.labelIds = await Promise.all(
        input.labels.map((r: string) => this.resolve("label", r, team)),
      );
      delete mapped.labels;
    }
    const op = `${m.singular}${ref ? "Update" : "Create"}`,
      type = `${m.type}${ref ? "Update" : "Create"}Input`;
    const data = await this.client.request(
      `mutation Write($input:${type}!${ref ? ",$id:String!" : ""}){ ${op}(input:$input${ref ? ",id:$id" : ""}){ success ${m.singular}{ ${selection(m.shape)} } } }`,
      { input: mapped, ...(ref ? { id } : {}) },
      true,
    );
    if (data[op]?.success !== true)
      throw new ToolError(
        "LINEAR_WRITE_FAILED",
        "Linear did not confirm the write; inspect it before retrying.",
        { automaticallyRetried: false },
      );
    return pick(data[op][m.singular], m.shape);
  }
  async patch(
    kind: "issue" | "document",
    ref: string,
    patches: Patch[],
    expectedHash: string,
  ) {
    const current = await this.get(kind, ref),
      field = kind === "issue" ? "description" : "content";
    const body = current[field] ?? "",
      updated = patchBody(body, patches, expectedHash);
    // Detect edits during validation. Linear offers no conditional body mutation;
    // a narrow read/write race remains and is documented in the tool description.
    const fresh = await this.get(kind, current.id);
    if (bodyHash(fresh[field] ?? "") !== bodyHash(body))
      throw new ToolError(
        "BODY_CONFLICT",
        "Body changed during patch validation.",
      );
    return this.write(kind, { [field]: updated }, current.id);
  }
  async dependencies(issue: string, after?: string, limit = 50) {
    const id = await this.resolve("issue", issue);
    const data = await this.client.request(
      "query Dependencies($id:String!,$after:String,$first:Int!){ issue(id:$id){ relations(first:$first,after:$after){nodes{id type issue{id identifier} relatedIssue{id identifier}} pageInfo{hasNextPage endCursor}} } }",
      { id, after, first: limit },
    );
    const c = data.issue.relations;
    return {
      items: c.nodes.slice(0, limit).map((r: any) =>
        pick(r, {
          id: true,
          type: true,
          issue: { id: true, identifier: true },
          relatedIssue: { id: true, identifier: true },
        }),
      ),
      truncated: c.pageInfo.hasNextPage,
      nextCursor: c.pageInfo.endCursor,
    };
  }
  async dependency(
    action: "add" | "remove",
    issue: string,
    blockedIssue: string,
    relationId?: string,
  ) {
    const issueId = await this.resolve("issue", issue),
      relatedIssueId = await this.resolve("issue", blockedIssue);
    if (action === "add") {
      const data = await this.client.request(
        "mutation Dependency($input:IssueRelationCreateInput!){ issueRelationCreate(input:$input){success issueRelation{id type}} }",
        { input: { issueId, relatedIssueId, type: "blocks" } },
        true,
      );
      if (!data.issueRelationCreate?.success)
        throw new ToolError(
          "LINEAR_WRITE_FAILED",
          "Dependency was not confirmed; inspect Linear before retrying.",
        );
      return pick(data.issueRelationCreate.issueRelation, {
        id: true,
        type: true,
      });
    }
    if (!relationId || !uuid.test(relationId))
      throw new ToolError(
        "INVALID_REFERENCE",
        "Removal requires the dependency relation UUID from linear_dependencies_list.",
      );
    const data = await this.client.request(
      "query Relation($id:String!){issueRelation(id:$id){id type issue{id} relatedIssue{id}}}",
      { id: relationId },
    );
    const r = data.issueRelation;
    if (
      r?.type !== "blocks" ||
      r.issue.id !== issueId ||
      r.relatedIssue.id !== relatedIssueId
    )
      throw new ToolError(
        "INVALID_RELATION",
        "Relation does not match the specified dependency.",
      );
    const result = await this.client.request(
      "mutation RemoveDependency($id:String!){issueRelationDelete(id:$id){success}}",
      { id: relationId },
      true,
    );
    if (!result.issueRelationDelete?.success)
      throw new ToolError(
        "LINEAR_WRITE_FAILED",
        "Dependency removal was not confirmed.",
      );
    return { removed: true };
  }
  async attach(issue: string, filePath: string, title?: string) {
    const issueId = await this.resolve("issue", issue),
      file = await readAttachment(this.uploadDirectory, filePath);
    const data = await this.client.request(
      "mutation Upload($contentType:String!,$filename:String!,$size:Int!){fileUpload(contentType:$contentType,filename:$filename,size:$size){success uploadFile{uploadUrl assetUrl headers{key value}}}}",
      {
        contentType: file.contentType,
        filename: file.name,
        size: file.bytes.length,
      },
      true,
    );
    const upload = data.fileUpload?.uploadFile;
    if (!data.fileUpload?.success || !upload)
      throw new ToolError(
        "UPLOAD_FAILED",
        "Linear did not provide an upload URL.",
      );
    const headers: Record<string, string> = {
      "Content-Type": file.contentType,
      "Cache-Control": "public, max-age=31536000",
    };
    for (const h of upload.headers) {
      if (/^(authorization|cookie|host)$/i.test(h.key))
        throw new ToolError(
          "INVALID_UPLOAD_HEADERS",
          "Unsupported signed upload header.",
        );
      headers[h.key] = h.value;
    }
    await this.client.upload(upload.uploadUrl, headers, file.bytes);
    const result = await this.client.request(
      "mutation Attach($input:AttachmentCreateInput!){attachmentCreate(input:$input){success attachment{id title url}}}",
      { input: { issueId, title: title ?? file.name, url: upload.assetUrl } },
      true,
    );
    if (!result.attachmentCreate?.success)
      throw new ToolError(
        "ATTACHMENT_FAILED",
        "Upload completed but attachment was not confirmed. Inspect Linear before retrying.",
      );
    return pick(result.attachmentCreate.attachment, {
      id: true,
      title: true,
      url: true,
    });
  }
}
