import { eligibleStaff, type LaboratoryStaff } from "@/lib/staff-attribution";

type Props = {
  staff: LaboratoryStaff[];
  assignment: "analista" | "revisor";
  staffId: string | null | undefined;
  legacy: string | null;
  disabled: boolean;
  onChange: (id: string | null, initials: string | null) => void;
};

export function StaffAssignment({ staff, assignment, staffId, legacy, disabled, onChange }: Props) {
  const current = staff.find((person) => person.id === staffId);
  return <select style={{ width: "100%", minWidth: 0 }} title={current?.full_name || legacy || "Seleccionar personal"} aria-label={assignment === "analista" ? "Analista" : "Libera"} value={staffId || (legacy ? "legacy" : "")} disabled={disabled} onChange={(event) => {
    const person = staff.find((item) => item.id === event.target.value);
    onChange(person?.id || null, person?.initials || null);
  }}>
    <option value="">Seleccionar…</option>
    {!staffId && legacy && <option value="legacy" disabled>{legacy} (registro anterior)</option>}
    {staffId && !current && <option value={staffId} disabled>{legacy || "Personal registrado"}</option>}
    {staff.filter((person) => person.id === staffId || eligibleStaff(person, assignment)).map((person) => <option key={person.id} value={person.id} disabled={!eligibleStaff(person, assignment)}>{person.full_name} ({person.initials}){!person.active ? " · inactivo" : !eligibleStaff(person, assignment) ? " · asignación anterior" : ""}</option>)}
  </select>;
}
