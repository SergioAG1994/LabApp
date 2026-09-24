import { ToolError } from "../errors.js";
export interface LinearClient {
  request<T = Record<string, any>>(
    query: string,
    variables?: Record<string, unknown>,
    write?: boolean,
  ): Promise<T>;
  upload(
    url: string,
    headers: Record<string, string>,
    bytes: Buffer,
  ): Promise<void>;
}
export class GraphQLClient implements LinearClient {
  constructor(
    private key: string,
    private fetcher: typeof fetch = fetch,
    private timeoutMs = 15_000,
  ) {}
  async request<T = Record<string, any>>(
    query: string,
    variables: Record<string, unknown> = {},
    write = false,
  ): Promise<T> {
    try {
      const response = await this.fetcher("https://api.linear.app/graphql", {
        method: "POST",
        headers: {
          Authorization: this.key,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(this.timeoutMs),
        redirect: "error",
      });
      if (!response.ok)
        throw new ToolError(
          "LINEAR_HTTP_ERROR",
          `Linear returned HTTP ${response.status}.`,
          { status: response.status },
        );
      const text = await readBounded(response, 8_000_000);
      const body = JSON.parse(text);
      if (body.errors?.length || !body.data)
        throw new ToolError(
          "LINEAR_GRAPHQL_ERROR",
          "Linear returned GraphQL errors; no result can be assumed.",
          {
            upstreamCodes: body.errors
              ?.map((e: any) =>
                String(e.extensions?.code ?? "UNKNOWN")
                  .replace(/[^A-Z_]/g, "")
                  .slice(0, 60),
              )
              .slice(0, 10),
          },
        );
      return body.data;
    } catch (error) {
      const details = {
        outcome: write
          ? "unknown; inspect Linear before trying this write again"
          : "failed",
        automaticallyRetried: false,
      };
      if (error instanceof ToolError)
        throw new ToolError(error.code, error.message, {
          ...error.details,
          ...details,
        });
      throw new ToolError(
        "LINEAR_UNAVAILABLE",
        "Linear request failed or timed out.",
        details,
      );
    }
  }
  async upload(url: string, headers: Record<string, string>, bytes: Buffer) {
    const target = new URL(url);
    if (
      target.protocol !== "https:" ||
      target.username ||
      target.password ||
      !["uploads.linear.app", "storage.googleapis.com"].includes(
        target.hostname,
      )
    )
      throw new ToolError(
        "INVALID_UPLOAD_URL",
        "Linear returned an unsupported upload host.",
      );
    try {
      const response = await this.fetcher(target, {
        method: "PUT",
        headers,
        body: new Uint8Array(bytes),
        signal: AbortSignal.timeout(30_000),
        redirect: "error",
      });
      if (!response.ok) throw new Error();
    } catch {
      throw new ToolError(
        "UPLOAD_FAILED",
        "Upload failed or timed out. No automatic retry was attempted; inspect Linear before retrying.",
      );
    }
  }
}
async function readBounded(response: Response, max: number) {
  const reader = response.body?.getReader();
  if (!reader)
    throw new ToolError(
      "LINEAR_RESPONSE_INVALID",
      "Linear returned an empty response.",
    );
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > max)
        throw new ToolError(
          "LINEAR_RESPONSE_TOO_LARGE",
          "Complete response exceeds the safe limit. No partial body will be used.",
        );
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  return Buffer.concat(chunks).toString("utf8");
}
