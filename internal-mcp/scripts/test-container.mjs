import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import os from "node:os";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
const root = await mkdtemp(path.join(os.tmpdir(), "labapp-mcp-smoke-"));
const project = `labapp-smoke-${randomBytes(4).toString("hex")}`;
const secrets = path.join(root, "secrets"),
  uploads = path.join(root, "uploads"),
  override = path.join(root, "override.yaml");
await mkdir(secrets);
await mkdir(uploads);
const token = randomBytes(32).toString("hex");
await writeFile(path.join(secrets, "mcp_token"), token);
await writeFile(path.join(secrets, "database_url"), "");
await writeFile(path.join(secrets, "linear_api_key"), "");
await writeFile(
  override,
  'services:\n  mcp:\n    ports: !override ["127.0.0.1::3100"]\n',
);
const args = ["compose", "-p", project, "-f", "compose.yaml", "-f", override];
const env = {
  ...process.env,
  LABAPP_MCP_SECRETS: secrets,
  LABAPP_MCP_UPLOADS: uploads,
};
const compose = (...command) =>
  execFileSync("docker", [...args, ...command], {
    env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
let client;
try {
  compose("config", "--quiet");
  compose("up", "--build", "--detach");
  const address = compose("port", "mcp", "3100");
  assert(address.startsWith("127.0.0.1:"));
  const url = new URL(`http://${address}/mcp`);
  for (let i = 0; ; i++) {
    try {
      const result = await fetch(url);
      if (result.status === 401) break;
    } catch {}
    if (i === 40) throw new Error("Container failed to become ready");
    await new Promise((r) => setTimeout(r, 250));
  }
  client = new Client({ name: "docker-smoke", version: "1" });
  const transport = new StreamableHTTPClientTransport(url, {
    requestInit: { headers: { Authorization: `Bearer ${token}` } },
  });
  await client.connect(transport);
  assert(transport.sessionId);
  assert.deepEqual(
    (await client.listTools()).tools.map((t) => t.name),
    ["health"],
  );
  const result = await client.callTool({ name: "health", arguments: {} });
  assert.equal(result.structuredContent.status, "ok");
  assert.equal(result.structuredContent.databaseConfigured, false);
  assert.equal(result.structuredContent.linearConfigured, false);
  assert.equal(
    compose(
      "exec",
      "-T",
      "mcp",
      "node",
      "-e",
      "process.stdout.write(String(process.getuid()))",
    ),
    "1000",
  );
  await transport.terminateSession();
  console.log(
    "Docker Compose smoke passed: localhost binding, non-root runtime, bearer auth, stateful MCP discovery and health.",
  );
} finally {
  await client?.close();
  compose("down", "--remove-orphans");
  await rm(root, { recursive: true, force: true });
}
