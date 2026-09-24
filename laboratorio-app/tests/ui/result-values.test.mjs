import assert from "node:assert/strict";
import { test } from "node:test";
import { numericEditorParts, numericResultValue, parseNumericResult, resultValidationError, resultWriteFields } from "../../src/lib/result-values.ts";
import { loadWorksheetColumns } from "../../src/lib/staff-attribution.ts";

test("measurements keep exact decimals, signs, zero and comparison qualifiers", () => {
  for (const [raw, qualifier, value] of [
    ["9007199254740993.12345678901234567890", "eq", "9007199254740993.12345678901234567890"],
    ["0", "eq", "0"], ["-0.001", "eq", "-0.001"], ["  <  .0500  ", "lt", ".0500"],
    ["<=+01.50", "lte", "+01.50"], ["≥-2", "gte", "-2"], [">3", "gt", "3"], ["≤0.5", "lte", "0.5"],
  ]) assert.deepEqual(parseNumericResult(raw), { qualifier, value });
});

test("numeric validation rejects ambiguous formats and shares database bounds", () => {
  for (const raw of ["1,2", "1e2", "NaN", "Infinity", "=1", "1.", "<", "1 2", "1".repeat(101), "<" + " ".repeat(128) + "1", "\u00a01", "≤\u00a01"]) {
    assert.equal(parseNumericResult(raw), null, raw);
    assert.ok(resultValidationError({ result_value: raw, result_input_kind: "number" }), raw);
    assert.equal(resultValidationError({ result_value: raw, result_input_kind: "text" }), null);
  }
  assert.ok(parseNumericResult("0".repeat(100)));
  assert.equal(resultValidationError({ result_value: " \t\n", result_input_kind: "number" }), null);
});

test("typing qualifier first and an incomplete decimal preserves both until valid", () => {
  const pending = numericResultValue("", "lt");
  assert.deepEqual(numericEditorParts(pending), { qualifier: "lt", value: "" });
  const decimal = numericResultValue("0.", numericEditorParts(pending).qualifier);
  assert.deepEqual(numericEditorParts(decimal), { qualifier: "lt", value: "0." });
  assert.equal(numericResultValue("0.05", numericEditorParts(decimal).qualifier), "<0.05");
  const cleared = numericResultValue("", numericEditorParts(decimal).qualifier);
  assert.deepEqual(numericEditorParts(cleared), { qualifier: "lt", value: "" });
  const negative = numericResultValue("-", numericEditorParts(cleared).qualifier);
  assert.deepEqual(numericEditorParts(negative), { qualifier: "lt", value: "-" });
  const negativeDecimal = numericResultValue("-0.", numericEditorParts(negative).qualifier);
  assert.deepEqual(numericEditorParts(negativeDecimal), { qualifier: "lt", value: "-0." });
  assert.equal(numericResultValue("-0.05", numericEditorParts(negativeDecimal).qualifier), "<-0.05");
});

test("save preserves untouched raw legacy values, numeric-looking text and explicit modes", () => {
  for (const raw of [null, "", "  < 0.0500  ", "No detectado", "1,000", "0012", "\t"])
    for (const mode of ["auto", "text", "number"]) {
      assert.deepEqual(resultWriteFields({ result_value: raw, result_input_kind: mode }, true), { result_value: raw, result_input_kind: mode });
      assert.deepEqual(resultWriteFields({ result_value: raw, result_input_kind: mode }, false), { result_value: raw });
    }
});

test("missing 044 retries with 043 columns and keeps atomic staff-aware saves", async () => {
  const requests = [];
  const loaded = await loadWorksheetColumns(async (request) => {
    requests.push(request);
    return request.structured ? { error: { code: "42703", message: "column worksheet_results.result_input_kind does not exist" } } : { error: null, data: [{ worksheet_revision: 4 }] };
  });
  assert.deepEqual(requests, [{ staff: true, structured: true }, { staff: true, structured: false }]);
  assert.equal(loaded.legacyWorksheet, false);
  assert.equal(loaded.structuredResults, false);
  assert.equal(loaded.result.data[0].worksheet_revision, 4);
});

test("only confirmed missing 043 allows legacy writes; other errors never downgrade", async () => {
  for (const error of [
    { code: "42501", message: "denied result_input_kind" },
    { code: "42703", message: "column unrelated does not exist" },
    { code: "42703", message: "column result_type_extra does not exist" },
    { code: "PGRST202", message: "missing save_analysis_worksheet" },
    { message: "network error result_input_kind" },
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
    return { error: request.staff ? { code: "42703", message: "column worksheet_revision does not exist" } : null };
  });
  assert.equal(loaded.legacyWorksheet, true);
  assert.equal(loaded.structuredResults, false);
  assert.deepEqual(requests, [{ staff: true, structured: true }, { staff: false, structured: false }]);
});
