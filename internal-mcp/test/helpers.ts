import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createApp } from "../src/server.js";
import type { Dependencies } from "../src/tools.js";
export const token = "test-token-that-is-at-least-thirty-two-bytes";
export async function harness(deps: Partial<Dependencies> = {}) {
  const logs: Record<string, unknown>[] = [];
  const runtime = createApp(token, { log: (e) => logs.push(e), ...deps });
  const http = runtime.app.listen(0, "127.0.0.1");
  await new Promise<void>((r) => http.once("listening", r));
  const url = new URL(`http://127.0.0.1:${(http.address() as any).port}/mcp`);
  const clients: Client[] = [];
  async function connect(auth = token) {
    const client = new Client({ name: "integration-tests", version: "1.0" });
    const transport = new StreamableHTTPClientTransport(url, {
      requestInit: { headers: { Authorization: `Bearer ${auth}` } },
    });
    await client.connect(transport);
    clients.push(client);
    return { client, transport };
  }
  const { client, transport } = await connect();
  return {
    client,
    transport,
    url,
    logs,
    connect,
    call: async (name: string, args: Record<string, unknown> = {}) => {
      const result = await client.callTool({ name, arguments: args });
      let value;
      try {
        value = JSON.parse((result.content as any)[0].text);
      } catch {
        value = { message: (result.content as any)[0].text };
      }
      return { error: result.isError === true, value, raw: result };
    },
    close: async () => {
      await Promise.all(clients.map((c) => c.close()));
      await runtime.close();
      http.closeAllConnections();
      await new Promise<void>((r) => http.close(() => r()));
    },
  };
}
