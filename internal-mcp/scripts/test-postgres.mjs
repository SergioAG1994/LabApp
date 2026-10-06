import { execFileSync, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
const name = `labapp-mcp-test-${randomUUID().slice(0, 8)}`;
const docker = (...args) =>
  execFileSync("docker", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
try {
  docker(
    "run",
    "--detach",
    "--rm",
    "--name",
    name,
    "-e",
    "POSTGRES_PASSWORD=mcp-test-only",
    "-p",
    "127.0.0.1::5432",
    "postgres:17-alpine",
  );
  for (let i = 0; ; i++) {
    if (
      spawnSync("docker", ["exec", name, "pg_isready"], { stdio: "ignore" })
        .status === 0
    )
      break;
    if (i === 60)
      throw new Error("Disposable PostgreSQL failed to become ready.");
    await new Promise((r) => setTimeout(r, 500));
  }
  const port = docker("port", name, "5432").split(":").at(-1);
  const run = spawnSync(
    process.execPath,
    ["--import", "tsx", "--test", "test/postgres.integration.ts"],
    {
      stdio: "inherit",
      env: {
        ...process.env,
        LABAPP_MCP_DISPOSABLE_DB: "1",
        TEST_DATABASE_URL: `postgresql://postgres:mcp-test-only@127.0.0.1:${port}/postgres`,
      },
    },
  );
  process.exitCode = run.status ?? 1;
} finally {
  docker("stop", name);
}
