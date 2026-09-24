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
