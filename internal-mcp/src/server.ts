import express from "express";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { createTools, type Dependencies } from "./tools.js";
export function createApp(token: string, deps: Dependencies) {
  if (Buffer.byteLength(token) < 32)
    throw new Error("MCP_TOKEN must contain at least 32 bytes.");
  const app = express();
  app.disable("x-powered-by");
  const sessions = new Map<
    string,
    {
      transport: StreamableHTTPServerTransport;
      server: ReturnType<typeof createTools>;
      touched: number;
      active: number;
    }
  >();
  app.use((req, res, next) => {
    const start = performance.now();
    res.on("finish", () =>
      deps.log({
        event: "http",
        method: req.method,
        status: res.statusCode,
        latencyMs: Math.round(performance.now() - start),
      }),
    );
    const supplied = Buffer.from(req.headers.authorization ?? ""),
      expected = Buffer.from(`Bearer ${token}`);
    if (
      supplied.length !== expected.length ||
      !timingSafeEqual(supplied, expected)
    ) {
      res.setHeader("WWW-Authenticate", "Bearer");
      res.status(401).json({ error: "Unauthorized" });
      return;
    }
    const host = req.headers.host;
    if (!host || !/^(localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$/.test(host)) {
      res.status(403).json({ error: "Invalid host" });
      return;
    }
    if (req.headers.origin) {
      try {
        const origin = new URL(req.headers.origin);
        if (
          origin.host !== host ||
          !["http:", "https:"].includes(origin.protocol)
        )
          throw new Error();
      } catch {
        res.status(403).json({ error: "Invalid origin" });
        return;
      }
    }
    next();
  });
  app.use(express.json({ limit: "2mb" }));
  app.all("/mcp", async (req, res) => {
    let entry;
    try {
      const sid = req.headers["mcp-session-id"];
      if (typeof sid === "string") {
        entry = sessions.get(sid);
        if (!entry) {
          res.status(404).json({ error: "Unknown session; initialize again." });
          return;
        }
      } else if (req.method === "POST" && isInitializeRequest(req.body)) {
        if (sessions.size >= 100) {
          res.status(503).json({ error: "Session capacity reached" });
          return;
        }
        const server = createTools(deps);
        const transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          enableJsonResponse: true,
          onsessioninitialized: (id) => {
            sessions.set(id, entry!);
          },
        });
        entry = { transport, server, touched: Date.now(), active: 0 };
        transport.onclose = () => {
          if (transport.sessionId) sessions.delete(transport.sessionId);
        };
        await server.connect(transport);
      } else {
        res.status(400).json({ error: "Initialize a session first." });
        return;
      }
      entry.touched = Date.now();
      entry.active++;
      await entry.transport.handleRequest(req, res, req.body);
    } catch {
      if (!res.headersSent)
        res.status(500).json({ error: "MCP transport failed" });
    } finally {
      if (entry) {
        entry.active = Math.max(0, entry.active - 1);
        entry.touched = Date.now();
      }
    }
  });
  app.use((_req, res) => {
    res.status(404).json({ error: "Not found" });
  });
  app.use(
    (
      err: unknown,
      _req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      const status = (err as { status?: number }).status;
      res
        .status(status === 413 ? 413 : 400)
        .json({ error: "Invalid request body" });
    },
  );
  const reaper = setInterval(() => {
    for (const [id, s] of sessions)
      if (!s.active && Date.now() - s.touched > 30 * 60_000) {
        sessions.delete(id);
        void s.server.close();
      }
  }, 60_000).unref();
  return {
    app,
    close: async () => {
      clearInterval(reaper);
      await Promise.all([...sessions.values()].map((s) => s.server.close()));
      sessions.clear();
    },
  };
}
