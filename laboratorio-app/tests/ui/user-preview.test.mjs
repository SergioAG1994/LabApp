import assert from "node:assert/strict";
import { test } from "node:test";
import { createPreviewFetch } from "../../src/lib/user-preview.ts";

const origin = "https://example.supabase.co";
test("preview preserves actor authorization and attaches context only to data reads", async () => {
  const sent = [];
  const transport = createPreviewFetch(() => "preview-1", async (input, init) => {
    sent.push({ input, init });
    return Response.json([]);
  });
  await transport(`${origin}/rest/v1/parameters?select=id`, { headers: { Authorization: "Bearer actor-session" } });
  const headers = sent[0].init.headers;
  assert.equal(headers.get("authorization"), "Bearer actor-session");
  assert.equal(headers.get("x-user-preview"), "preview-1");
  await transport(`${origin}/auth/v1/user`);
  assert.equal(sent[1].init, undefined);
});

test("preview rejects table writes and unapproved RPCs even with GET", async () => {
  let calls = 0;
  const transport = createPreviewFetch(() => "preview-1", async () => { calls++; return Response.json([]); });
  for (const [path, method] of [["/parameters", "PATCH"], ["/profiles", "POST"], ["/rpc/issue_report", "GET"], ["/rpc/save_analysis_worksheet", "POST"]]) {
    assert.equal((await transport(`${origin}/rest/v1${path}`, { method })).status, 403);
  }
  assert.equal(calls, 0);
  await transport(`${origin}/rest/v1/rpc/list_staff_samples`, { method: "POST" });
  await transport(`${origin}/rest/v1/rpc/end_user_preview`, { method: "POST" });
  assert.equal(calls, 2);
});

test("ending preview discards in-flight reads and restores normal transport", async () => {
  let preview = "preview-1";
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  const transport = createPreviewFetch(() => preview, async () => pending);
  const request = transport(`${origin}/rest/v1/parameters`);
  preview = null;
  resolve(Response.json([]));
  await assert.rejects(request, /vista cambió/);
  let called = false;
  const normal = createPreviewFetch(() => null, async () => { called = true; return Response.json({}); });
  assert.equal((await normal(`${origin}/rest/v1/parameters`, { method: "PATCH" })).status, 200);
  assert.equal(called, true);
});
