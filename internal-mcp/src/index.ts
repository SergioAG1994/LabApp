import { readFileSync } from "node:fs";
import { z } from "zod";
import pg from "pg";
import { PostgresDatabase } from "./database.js";
import { GraphQLClient } from "./linear/client.js";
import { LinearService } from "./linear/service.js";
import { createApp } from "./server.js";
function secret(name: string) {
  const file = process.env[`${name}_FILE`];
  return (
    (file ? readFileSync(file, "utf8").trim() : process.env[name]) || undefined
  );
}
const config = z
  .object({
    token: z.string().min(32),
    database: z.string().url().optional(),
    linear: z.string().min(1).optional(),
    port: z.coerce.number().int().min(1).max(65535),
    uploads: z.string(),
  })
  .parse({
    token: secret("MCP_TOKEN"),
    database: secret("DATABASE_URL"),
    linear: secret("LINEAR_API_KEY"),
    port: process.env.PORT ?? 3100,
    uploads: process.env.UPLOAD_DIRECTORY ?? "/uploads",
  });
// The container binds all interfaces internally; Docker publishes loopback only.
const pool = config.database
  ? new pg.Pool({
      connectionString: config.database,
      max: 5,
      connectionTimeoutMillis: 5000,
      statement_timeout: 15000,
      idle_in_transaction_session_timeout: 20000,
      application_name: "labapp-internal-mcp",
    })
  : undefined;
const log = (entry: Record<string, unknown>) =>
  process.stdout.write(
    JSON.stringify({ time: new Date().toISOString(), ...entry }) + "\n",
  );
pool?.on("error", () => log({ event: "database_pool_error", status: "error" }));
const runtime = createApp(config.token, {
  database: pool ? new PostgresDatabase(pool) : undefined,
  linear: config.linear
    ? new LinearService(new GraphQLClient(config.linear), config.uploads)
    : undefined,
  log,
});
const http = runtime.app.listen(
  config.port,
  process.env.BIND_ADDRESS ?? "127.0.0.1",
  () => log({ event: "listening", port: config.port }),
);
for (const signal of ["SIGINT", "SIGTERM"])
  process.once(signal, async () => {
    await runtime.close();
    http.close();
    await pool?.end();
  });
