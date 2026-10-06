import { readFileSync } from "node:fs";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const state = process.argv[2];
if (!state) throw new Error("Provide the private state directory path.");
const token = readFileSync(
  path.join(state, "secrets", "mcp_token"),
  "utf8",
).trim();
const client = new Client({ name: "labapp-live-check", version: "1.0" });
const transport = new StreamableHTTPClientTransport(
  new URL("http://127.0.0.1:3100/mcp"),
  { requestInit: { headers: { Authorization: `Bearer ${token}` } } },
);
try {
  await client.connect(transport);
  const health = await client.callTool({ name: "health", arguments: {} });
  const readiness = health.structuredContent;
  if (health.isError || !readiness || readiness.status !== "ok")
    throw new Error("Health verification failed.");
  const { tools } = await client.listTools();
  console.log(JSON.stringify({ ...readiness, toolCount: tools.length }));
  if (readiness.linearConfigured) {
    const teams = await client.callTool({
      name: "linear_team_list",
      arguments: { limit: 10 },
    });
    if (teams.isError) throw new Error("Linear read verification failed.");
    console.log(JSON.stringify({ linearRead: "passed" }));
  }
  if (readiness.databaseConfigured) {
    const query = await client.callTool({
      name: "query",
      arguments: { sql: "SELECT count(*) FROM public.parameters" },
    });
    if (query.isError)
      throw new Error("Restricted database read verification failed.");
    console.log(JSON.stringify({ databaseRead: "passed" }));
  }
} catch {
  // Do not print raw errors, headers or upstream responses from live credentials.
  console.error("Live MCP verification failed; credentials were not printed.");
  process.exitCode = 1;
} finally {
  await client.close();
}
