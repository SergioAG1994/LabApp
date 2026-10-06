import assert from "node:assert/strict";
import { test } from "node:test";
import { eligibleStaff, loadWorksheetColumns } from "../../src/lib/staff-attribution.ts";

test("Libera accepts active analysts, samplers, reviewers and authorizers", () => {
  const makeStaff = (fn, active = true) => ({ id: fn, full_name: fn, initials: fn, active, functions: [fn] });
  for (const fn of ["analista", "muestreador", "revisor", "responsable_autorizacion"])
    assert.equal(eligibleStaff(makeStaff(fn), "revisor"), true, fn);
  assert.equal(eligibleStaff(makeStaff("muestreador", false), "revisor"), false);
  assert.equal(eligibleStaff(makeStaff("muestreador"), "analista"), true);
});

test("worksheet loading uses ordinary result fields and retries only for missing staff columns", async () => {
  const requests = [];
  const loaded = await loadWorksheetColumns(async (request) => {
    requests.push(request);
    return request ? { error: null, data: [{ result_value: "<5", worksheet_revision: 4 }] } : { error: { code: "42703", message: "column worksheet_revision does not exist" }, data: [{ result_value: "<5" }] };
  });
  assert.deepEqual(requests, [true]);
  assert.equal(loaded.legacyWorksheet, false);
  assert.equal(loaded.result.data[0].result_value, "<5");
});

test("only confirmed missing staff columns allow legacy loading; other errors never downgrade", async () => {
  for (const error of [
    { code: "42501", message: "permission denied" },
    { code: "42703", message: "column unrelated does not exist" },
    { code: "PGRST202", message: "missing save_analysis_worksheet" },
    { message: "network error" },
  ]) {
    let calls = 0;
    const loaded = await loadWorksheetColumns(async () => { calls++; return { error }; });
    assert.equal(calls, 1);
    assert.equal(loaded.legacyWorksheet, false);
    assert.equal(loaded.result.error, error);
  }
  const requests = [];
  const loaded = await loadWorksheetColumns(async (request) => {
    requests.push(request);
    return { error: request ? { code: "42703", message: "column worksheet_revision does not exist" } : null };
  });
  assert.equal(loaded.legacyWorksheet, true);
  assert.deepEqual(requests, [true, false]);
});
