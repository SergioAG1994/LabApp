import assert from "node:assert/strict";
import { test } from "node:test";
import { eligibleStaff, staffDisplayName, missingStaffColumns } from "../../src/lib/staff-attribution.ts";

const analyst = { id: "person-a", full_name: "Ana García", initials: "AG", active: true, functions: ["analista"] };
const renamed = { ...analyst, full_name: "Ana Gómez", initials: "AGO" };
const other = { ...analyst, id: "person-b", full_name: "Adriana García" };

test("stable identity survives renamed staff and duplicate legacy initials", () => {
  assert.equal(staffDisplayName([renamed, other], analyst.id, "AG"), "Ana Gómez");
  assert.equal(staffDisplayName([renamed, other], null, "AG"), "AG");
  assert.equal(staffDisplayName([other], "missing", "Preserved text"), "Preserved text");
});

test("inactive historical staff remains readable but cannot receive new assignments", () => {
  const inactive = { ...analyst, active: false };
  assert.equal(staffDisplayName([inactive], inactive.id, "AG"), "Ana García");
  assert.equal(eligibleStaff(inactive, "analista"), false);
  assert.equal(eligibleStaff(analyst, "analista"), true);
  assert.equal(eligibleStaff(analyst, "muestreador"), false);
  assert.equal(eligibleStaff({ ...analyst, functions: ["responsable_autorizacion"] }, "revisor"), true);
});

test("only known missing migration columns enable legacy worksheet writes", () => {
  assert.equal(missingStaffColumns({ code: "42703", message: "column worksheet_results.worksheet_revision does not exist" }), true);
  for (const error of [
    { code: "42501", message: "denied worksheet_revision" },
    { code: "40001", message: "stale worksheet_revision" },
    { code: "42703", message: "column unrelated does not exist" },
    { code: "PGRST202", message: "missing save_analysis_worksheet" },
    { message: "network error worksheet_revision" },
  ]) assert.equal(missingStaffColumns(error), false);
});
