# LabApp internal MCP

One project-owned TypeScript service for shared agent sessions. Implements the
requested Derny-style interface using the official MCP SDK, Express, Zod, `pg`,
and direct Linear GraphQL requests. Independent of the Next.js application.

## Start the shared Docker server

1. Review and provision the dedicated database login as described below. Never
   use the Supabase service-role key, database owner, `postgres`, or an application
   credential for this server.
2. In the intended **work** Linear workspace, create a dedicated account/API key.
   Restrict it to the LabApp team(s), with **Read + Write**, no Admin permission.
   Create-issues/comments-only permissions cannot support project, document,
   milestone and update edits; Write is needed for the requested tool surface.
   Confirm the key's selected workspace and team scope in Linear's UI.
3. Create a private secrets directory **outside every checkout**, and a separate
   dedicated uploads directory. Do not place secrets in the uploads directory.
   Store three newline-terminated files: `database_url`, `linear_api_key`, and
   `mcp_token`. Generate the server token with `openssl rand -hex 32`. Provision
   secrets through the operator's secret manager or editor, not agent prompts or
   shell history. Use restrictive host permissions; files must be readable by
   the container's non-root UID 1000. Use a PostgreSQL URL with certificate
   verification (e.g. `sslmode=verify-full`) and install the provider CA if needed.
4. Set directory paths (not credentials) and start **once per project**:

   ```sh
   export LABAPP_MCP_SECRETS=/absolute/private/labapp-mcp-secrets
   export LABAPP_MCP_UPLOADS=/absolute/private/labapp-mcp-uploads
   docker compose up --build -d
   docker compose ps
   ```

   Run these commands from `internal-mcp`. The fixed Compose project name
   `labapp-internal-mcp` and port prevent each worktree from creating its own
   competing server. Use the same service from every agent session. Only the
   localhost port `127.0.0.1:3100` is published. The service runs as non-root with
   a read-only filesystem and upload mount, dropped capabilities and resource
   limits. Secrets are mounted at runtime and excluded from the build context.
5. Give agents only `http://127.0.0.1:3100/mcp` and the server bearer token.
   Configure the client's HTTP `Authorization: Bearer <server token>` header.
   Do not put the database URL or Linear key in agent MCP configuration. Store
   the token in the client's private credential/configuration store, outside Git.
   Authentication is checked on POST, GET, DELETE, and all other HTTP requests,
   including initialized sessions. Host and Origin checks reject browser rebinding.

The token authorizes **all exposed tools** for this project; it is not a per-user
identity. Anyone possessing it can use the scoped Linear write capabilities.
Rotate it by replacing the secret file and recreating the container; clients
must update their token and initialize new sessions. Recreate after upstream
credential rotation as well. Sessions expire after 30 minutes of inactivity,
with a maximum of 100; sessions are in-memory and do not survive restarts.

For local development: `npm ci && npm run build`, then `npm start` with
`MCP_TOKEN_FILE`, `DATABASE_URL_FILE`, `LINEAR_API_KEY_FILE` and
`UPLOAD_DIRECTORY` set. Environment variable equivalents are supported for
server-only secret injection. Missing/empty upstream secret files disable that
capability; the token is mandatory. Docker Compose expects all three files
(the upstream files may be empty for a health-only smoke test).

## Database access decision and provisioning

**No global RLS bypass.** The role is `labapp_mcp_reader`, with `NOBYPASSRLS`, no
memberships, no ownership or administrative capabilities. Explicit SELECT
policies allow this operator to read across users **only in approved catalogs**:

| Table | Granted columns |
| --- | --- |
| `public.parameters` | `id`, `name`, `par_form`, `unit`, `method_reference`, `decimal_places`, `result_kind`, `active` |
| `public.analysis_packages` | `id`, `code`, `name`, `active` |
| `public.package_parameters` | `package_id`, `parameter_id` |

`parameters.assigned_analyst_id`, clients, staff/profiles, orders, samples,
results, reports, audit events, and Supabase auth/storage data have no grants.
New tables/columns receive no automatic grants. Extend the provisioning SQL
**and** the runtime allowlist together after reviewing sensitivity and RLS.
Metadata in PostgreSQL system catalogs remains visible according to PostgreSQL's
normal permissions.

As a database administrator, inspect `sql/hardening-audit.sql`, then apply the
reviewed `sql/provision-reader.sql` with `psql -v ON_ERROR_STOP=1`. Set the login
password interactively with `\password labapp_mcp_reader`. The provisioning
script is a one-time migration, not an idempotent startup task; it contains no
password and is never executed by the MCP service.

**Supabase hardening requires operator review.** PostgreSQL grants EXECUTE on
new functions and TEMP on databases to PUBLIC by default. An individual role
cannot opt out of PUBLIC grants. Existing LabApp migrations include SECURITY
DEFINER functions. Transfer PUBLIC privileges that legitimate application roles
need to those roles, then revoke the broad PUBLIC grants in a reviewed migration.
Do not blindly revoke privileges used by Supabase authentication or existing RPCs.
Include the listed built-in large-object mutation routines: they can write
without table grants. Apply default-privilege changes for every routine-creating owner and audit again
after migrations/extensions. The audit SQL is read-only and lists the relevant
routines and grants; its suggested revokes are comments, not executable changes.

Before **every query**, the service refuses a credential with role memberships,
admin capabilities, schema/database CREATE or TEMP, table/column writes,
unapproved reads, sequence writes, large-object mutation routines, or callable SECURITY DEFINER routines.
It also rejects callable non-system invoker routines (which can wrap privileged
or network routines), non-system operator implementations in usable schemas,
and non-system cast functions. This deliberately conservative policy can require
extension hardening before use. It fails closed; it never falls back to a
privileged credential. Schema migrations must preserve these invariants; avoid
changing grants concurrently with operator queries.

`query({sql, params?})` accepts one parsed PostgreSQL query, SHOW or EXPLAIN statement.
The parser handles comments, dollar strings and quoted semicolons; PostgreSQL's
extended protocol also rejects multiple statements. Statement-type validation
protects the transaction wrapper; **database privileges are the write boundary**,
including writable CTEs and EXPLAIN ANALYZE. Each query runs in `BEGIN READ ONLY`,
with a 15-second statement timeout, and the connection is destroyed afterwards
to roll back and discard session settings/locks. Pool size is five.

Results use row arrays so duplicate column names remain unambiguous:

```json
{
  "rows": [["pH"]],
  "columns": ["name"],
  "rowCount": 1,
  "returnedRowCount": 1,
  "truncated": false,
  "truncationNotice": null
}
```

At most 1,000 rows and approximately 1 MB of serialized row data are returned.
Rows are streamed and counted without retaining the complete result. No SQL
LIMIT is injected: a query may process far more rows; `rowCount` is its total
result row count. Timeout errors return no partial result. Large values can
still require PostgreSQL/driver memory before they are excluded from output.
Database error messages are sanitized to avoid exposing SQL or row data.

## Linear tools

Discovery depends only on whether a key is configured, never a startup API call.
The server uses the intended key directly at `https://api.linear.app/graphql`;
agent personal OAuth accounts are not involved. No generic GraphQL passthrough,
entity delete, or archive tool exists. Dependency removal is the sole supported
relationship deletion.

| Tools | Operations |
| --- | --- |
| `linear_issue_*`, `linear_project_*` | `get`, `list` (including search), `create`, `update` |
| `linear_comment_*`, `linear_document_*`, `linear_milestone_*`, `linear_status_update_*` | `get`, `list`, `create`, `update` |
| `linear_team_*`, `linear_user_*`, `linear_cycle_*`, `linear_workflow_state_*` | `get`, `list` |
| `linear_label_*` | `get`, `list`, `create` |
| `linear_issue_patch`, `linear_document_patch` | Validated anchored body patches |
| `linear_dependencies_list`, `linear_dependency_add`, `linear_dependency_remove` | Read/add/remove outgoing blocks relations |
| `linear_attachment_upload` | Local-file upload followed by issue attachment |
| `health` | Local readiness and configured capabilities; does not claim upstream connectivity |

References accept UUIDs, issue identifiers (`LAB-123`), team keys, exact project,
cycle, label and workflow-state names, document titles, and user emails/names.
Names are matched without case sensitivity. Team context scopes cycle/state/label
resolution; updates infer the issue's current team when necessary. Comment and
status-update references use UUIDs. Duplicate matches return at most 50 candidates
and an explicit truncation flag; even one match on an incomplete page is not
silently selected. Use an explicit UUID to disambiguate. Key team scope is the
upstream permission boundary, including for UUID references.

Lists accept `limit` (1–50, default 25), `after`, optional `search` and supported
`team`/`project`/`issue` filters. Search matches name/title substrings; comments
and status updates use parent filters. Outputs contain allowlisted fields only,
maximum 8,000 characters per text field and 100,000 total text characters, with
`textTruncated`, `truncatedFields` and `truncationNotice`. Lists also report page
truncation and `nextCursor` inside `data`. No raw GraphQL objects are forwarded.
Upstream responses above 8 MB fail completely rather than yielding partial bodies.

For a patch, first read the issue/document and retain its complete-body SHA-256
`bodyHash`. Supply `expectedHash` and `patches: [{anchor, replacement}]`. Every
anchor must occur exactly once in the **original complete body**; anchors cannot
overlap. The service validates all operations, reads again to check for concurrent
changes, and only then writes. A display-truncated body is never used as patch
input. Linear does not offer an atomic conditional body mutation: a concurrent
edit in the final read/write interval can still race. Coordinate edits to the
same body. Explicit update body fields replace the entire body; prefer patches
when editing existing text.

Attachments use paths relative to the dedicated upload directory (container
absolute `/uploads/...` paths also work). The server verifies real path
containment, rejects symlink components and non-regular files, validates extension
and content, and limits files to 10 MiB. Supported formats are PNG, JPEG, PDF and
UTF-8 TXT/MD/CSV/JSON. The Linux container also validates the opened descriptor's
path. The mount is read-only; keep host writers trusted. The server requests a
signed URL, uploads bytes with returned headers (no API key on the upload), then
creates the issue attachment. Redirects and unsupported upload hosts are rejected;
only `uploads.linear.app` and `storage.googleapis.com` are accepted. No base64
argument is exposed.

Requests have bounded timeouts and **no automatic retries**, including reads,
writes and each upload stage. A timed-out write may have succeeded. Errors mark
write outcomes as unknown and instruct inspection before retrying. A successful
upload followed by a failed attachment may leave an unattached asset in Linear;
inspect the issue before any manual retry.

Logs are JSON containing HTTP method/status and tool name/status/latency. They
exclude payloads, SQL, parameters, file paths, upstream response bodies, headers,
and secrets. Restrict Docker log access and rotate logs operationally.

## Validation

```sh
npm ci
npm run build
npm test
npm run test:postgres   # Docker required; owns and removes a disposable PostgreSQL 17 container
npm run test:container  # Builds and verifies Docker Compose with temporary credentials
npm run format:check
```

Tests use real official MCP clients over local stateful HTTP. Fake upstreams
exercise authentication, multiple sessions, offline discovery, bounded outputs,
reference ambiguity, full-body patching, file containment/type/size checks, and
HTTP/GraphQL/network errors without retries. Generated GraphQL queries and input
variables are validated against an offline fixture of Linear's published schema.
The PostgreSQL test verifies permissions even with default read-only disabled,
RLS catalog access, denied sensitive columns/tables and writable CTEs, timeout,
row/byte caps and callable SECURITY DEFINER rejection. It uses only a disposable
local database; it never needs production credentials.

Sources: [MCP TypeScript SDK](https://ts.sdk.modelcontextprotocol.io/),
[Linear GraphQL](https://linear.app/developers/graphql),
[Linear key permissions](https://linear.app/docs/api-and-webhooks),
[Linear upload guide](https://linear.app/developers/how-to-upload-a-file-to-linear),
[published Linear schema](https://github.com/linear/linear/blob/master/packages/sdk/src/schema.graphql).
