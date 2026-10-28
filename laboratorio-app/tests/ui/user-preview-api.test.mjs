import assert from "node:assert/strict";
import { test } from "node:test";
import { GET, POST, PATCH } from "../../src/app/api/admin/users/route.ts";

test("server-key account API rejects observed analyst/reception access and all preview writes", async () => {
  const originalFetch = globalThis.fetch;
  const configuration = ["NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "SUPABASE_SECRET_KEY"];
  const previous = configuration.map((name) => process.env[name]);
  process.env.NEXT_PUBLIC_SUPABASE_URL = "https://preview-test.supabase.co";
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "sb_publishable_test";
  process.env.SUPABASE_SECRET_KEY = "sb_secret_test";
  let preview = null;
  let actualRole = "administrador";
  let secretWrites = 0;
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: "actor-id", email: "actor@test.invalid" });
    if (url.endsWith("/rpc/get_user_preview")) return Response.json(preview);
    if (url.includes("/rest/v1/profiles")) return Response.json({ role: actualRole });
    if (init?.method && init.method !== "GET") secretWrites++;
    throw new Error(`Unexpected network call: ${url}`);
  };
  const request = (method, headers = {}) => new Request("https://app.test/api/admin/users", {
    method, headers: { Authorization: "Bearer actor-session", "Content-Type": "application/json", ...headers },
    ...(method !== "GET" ? { body: JSON.stringify({ fullName: "Test", email: "test@test.invalid", role: "recepcion" }) } : {}),
  });
  try {
    assert.equal((await GET(new Request("https://app.test/api/admin/users"))).status, 401);
    for (const role of ["analista", "recepcion"]) {
      preview = { id: "preview-id", role };
      assert.equal((await GET(request("GET"))).status, 403);
      assert.equal((await POST(request("POST"))).status, 403);
      assert.equal((await PATCH(request("PATCH"))).status, 403);
    }
    preview = { id: "preview-id", role: "administrador" };
    assert.equal((await POST(request("POST"))).status, 403);
    assert.equal((await PATCH(request("PATCH"))).status, 403);
    preview = null;
    assert.equal((await POST(request("POST", { "x-user-preview": "ended-preview" }))).status, 403);
    actualRole = "recepcion";
    assert.equal((await GET(request("GET"))).status, 403);
    assert.equal(secretWrites, 0, "preview requests never reach server-key writes");
  } finally {
    globalThis.fetch = originalFetch;
    configuration.forEach((name, index) => {
      if (previous[index] === undefined) delete process.env[name]; else process.env[name] = previous[index];
    });
  }
});
