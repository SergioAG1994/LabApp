export type LaboratoryStaff = {
  id: string;
  full_name: string;
  initials: string;
  active: boolean;
  functions: string[];
};

export function eligibleStaff(person: LaboratoryStaff, assignment: "analista" | "revisor" | "muestreador") {
  return person.active && (person.functions.includes(assignment) || (assignment === "revisor" && person.functions.includes("responsable_autorizacion")));
}

// Legacy text is evidence, not an identity. Never guess who it represents.
export function staffDisplayName(staff: LaboratoryStaff[], id: string | null | undefined, legacy: string | null | undefined) {
  return (id ? staff.find((person) => person.id === id)?.full_name : null) || legacy || "—";
}

export function missingStaffColumns(error: { code?: string; message: string } | null) {
  return error?.code === "42703" && /(?:analyst_staff_id|released_by_staff_id|sampler_staff_id|worksheet_revision|worksheet_sampled_at)/.test(error.message);
}

export function missingStructuredResultColumns(error: { code?: string; message: string } | null) {
  return error?.code === "42703" && /\b(?:result_input_kind|result_type|result_numeric|result_qualifier|result_text)\b/.test(error.message);
}

// Migration 044 can lag the application without disabling 043's atomic save,
// staff identities, and stale-edit protection. Only missing known columns retry.
export async function loadWorksheetColumns<T extends { error: { code?: string; message: string } | null }>(
  load: (capabilities: { staff: boolean; structured: boolean }) => PromiseLike<T>,
) {
  let result = await load({ staff: true, structured: true });
  let structuredResults = !missingStructuredResultColumns(result.error);
  if (!structuredResults) result = await load({ staff: true, structured: false });
  const legacyWorksheet = missingStaffColumns(result.error);
  if (legacyWorksheet) {
    structuredResults = false;
    result = await load({ staff: false, structured: false });
  }
  return { result, legacyWorksheet, structuredResults };
}
