import assert from "node:assert/strict";
import { test } from "node:test";
import { buildSubsampleLayout, subsampleValue } from "../../src/lib/report-subsamples.ts";

const row = (id, label, result_value, unit = "NMP/100ml") => ({ id, label, result_value, unit });

test("NOM-001 24H uses three analytes, six positions, and only summaries in the main table", () => {
  const summaries = [
    row("ec-summary", "E. coli MG", "< 3"),
    row("cf-summary", "Col fec MG", "< 3"),
    row("gya-summary", "GyA ponderado", "< 8", "mg/L"),
  ];
  const readings = [6, 2, 4, 3, 1, 5].flatMap((n) => [
    row("ec-" + n, "E. coli (" + n + ")", String(n + 10)),
    row("cf-" + n, "Col fec (" + n + ")", String(n + 20)),
    row("gya-" + n, "GyA (" + n + ")", String(n + 30), "mg/L"),
  ]);
  const { columns, requiresSix, mainRows } = buildSubsampleLayout([...readings, ...summaries, row("ph", "pH", "7.1")]);
  assert.equal(requiresSix, true);
  assert.deepEqual(columns.map(({ label }) => label), ["Grasas y aceites", "Coliformes fecales", "E. coli"]);
  assert.deepEqual(mainRows.map(({ id }) => id), ["ec-summary", "cf-summary", "gya-summary", "ph"]);
  const oldDraft = { "ec-summary": Array(6).fill("99") };
  assert.deepEqual(Array.from({ length: 6 }, (_, i) => subsampleValue(columns[2], oldDraft, i)), ["11", "12", "13", "14", "15", "16"]);
  assert.equal(subsampleValue(columns[0], {}, 5), "36");
});

test("keeps historical manual breakdowns, but doesn't create values from a summary", () => {
  const { columns } = buildSubsampleLayout([row("cf-summary", "Col fec MG", "< 3")]);
  assert.equal(subsampleValue(columns[0], {}, 0), "");
  assert.equal(subsampleValue(columns[0], { "cf-summary": ["20", "25"] }, 1), "25");
  assert.equal(subsampleValue(columns[0], { "cf-summary": ["20"], "subsample:fecal-coliforms": [""] }, 0), "");
});

test("a lone measurement in an instantaneous package stays in the main results", () => {
  const { columns, mainRows } = buildSubsampleLayout([row("gya-1", "GyA (1)", "8", "mg/L")]);
  assert.equal(columns.length, 0);
  assert.equal(mainRows.length, 1);
});

for (const [count, summaryLabel] of [[4, "Enterococcos"], [6, "Enterococos (media geométrica)"]]) {
  test(`enterococci has one column and a separate summary for ${count} readings`, () => {
    const readings = Array.from({ length: count }, (_, i) => row(`ent-${i + 1}`, `Enterococcos (${i + 1})`, String(i + 10)));
    const summary = row("ent-summary", summaryLabel, "< 3");
    const ecoli = row("ec-summary", "E. coli MG", "25");
    const { columns, requiresSix, mainRows } = buildSubsampleLayout([...readings.reverse(), summary, ecoli]);
    assert.equal(requiresSix, count === 6);
    assert.deepEqual(mainRows, [summary, ecoli]);
    assert.deepEqual(columns.map(({ label }) => label), ["E. coli", "Enterococos"]);
    assert.deepEqual(Array.from({ length: count }, (_, i) => subsampleValue(columns[1], {}, i)), Array.from({ length: count }, (_, i) => String(i + 10)));
  });
}

test("enterococci without numbered readings does not add a breakdown column", () => {
  for (const label of ["Enterococos", "Enterococcos (media geométrica)"]) {
    const rows = [row("ent", label, "12"), row("gya-1", "GyA (1)", "8", "mg/L")];
    const { columns, mainRows } = buildSubsampleLayout(rows);
    assert.deepEqual(columns, []);
    assert.deepEqual(mainRows, rows);
  }
});
