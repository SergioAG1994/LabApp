export type StaffFunction = "analista" | "muestreador" | "revisor" | "responsable_autorizacion";
export type StaffRecord = {
  id: string; internal_id: number; full_name: string; initials: string;
  position_title: string; functions: StaffFunction[]; active: boolean;
};
export type StaffDetails = StaffRecord & { education: string | null; joined_at: string | null; updated_at: string };
export type StaffAuthorization = {
  id: string; staff_id: string; parameter_id: string;
  authorization_kind: "internal" | "ema"; method_reference: string;
  authorized_at: string; updated_at: string;
};
export type PersonnelParameter = { id: string; name: string; method_reference: string | null; active: boolean };
export function employeeNumber(value: number) { return String(value).padStart(4, "0"); }
