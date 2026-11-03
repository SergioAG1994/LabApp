import assert from "node:assert/strict";
import { test } from "node:test";
import { countPackageParameters } from "../../src/lib/package-parameter-count.ts";

test("counts E. coli, fecal coliforms and oils once each across subsamples and summaries", () => {
  const names = ["pH", "Temperatura", "E. coli MG", "Col fec MG", "GyA ponderado"];
  for (let n = 1; n <= 6; n++) names.push("E. coli (" + n + ")", "Col fec (" + n + ")", "GyA (" + n + ")");
  assert.equal(countPackageParameters(names), 5);
  assert.equal(countPackageParameters(["E. coli 1", "E. coli media geométrica", "E. coli O157", "Grasas y aceites", "GyA ponderado"]), 3);
  assert.equal(countPackageParameters(["Dureza Ca", "Dureza T", "N Total", "N-TKN"]), 4);
});

test("the CPD 24 package counts the same 24 parameters for all sampling durations", () => {
  const other = ["Al", "Cu", "As", "Cd", "CE", "CN", "Cr VI", "DBO5", "DQO", "Dureza T", "Dureza Ca",
    "MF", "Hg", "Ni", "N-TKN", "pH muestreo", "Pb", "PT", "S. Sed", "SAAM", "SST", "Temperatura", "Zn"];
  for (const samples of [1, 4, 6]) {
    const oils = Array.from({ length: samples }, (_, index) => "GyA (" + (index + 1) + ")");
    if (samples > 1) oils.push("GyA ponderado");
    assert.equal(countPackageParameters([...other, ...oils]), 24);
  }
});
