"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase";

type StaffFunction = "analista" | "muestreador" | "revisor" | "responsable_autorizacion";
type StaffRecord = {
  id: string;
  internal_id: number;
  full_name: string;
  initials: string;
  position_title: string;
  functions: StaffFunction[];
  active: boolean;
};

const functionOptions: Array<{ value: StaffFunction; label: string }> = [
  { value: "analista", label: "Analista" },
  { value: "muestreador", label: "Muestreador" },
  { value: "revisor", label: "Revisor" },
  { value: "responsable_autorizacion", label: "Responsable de autorización" },
];

export function PersonnelDirectory({ canManage, mode, userId }: { canManage: boolean; mode: "list" | "create"; userId: string }) {
  const [staff, setStaff] = useState<StaffRecord[]>([]);
  const [fullName, setFullName] = useState("");
  const [initials, setInitials] = useState("");
  const [positionTitle, setPositionTitle] = useState("");
  const [functions, setFunctions] = useState<StaffFunction[]>([]);
  const [active, setActive] = useState(true);
  const [saving, setSaving] = useState(false);
  const [changingId, setChangingId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [query, setQuery] = useState("");

  async function loadStaff() {
    const { data, error } = await supabase.from("laboratory_staff")
      .select("id, internal_id, full_name, initials, position_title, functions, active")
      .order("active", { ascending: false }).order("full_name");
    if (error) {
      setMessage(`No se pudo cargar el personal: ${error.message}`);
      return;
    }
    setStaff((data || []) as StaffRecord[]);
  }

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadStaff(); }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  const visibleStaff = useMemo(() => {
    const search = query.trim().toLocaleLowerCase("es-MX");
    if (!search) return staff;
    return staff.filter((person) => `${person.internal_id} ${person.full_name} ${person.initials} ${person.position_title} ${person.functions.join(" ")}`.toLocaleLowerCase("es-MX").includes(search));
  }, [query, staff]);

  function toggleFunction(value: StaffFunction) {
    setFunctions((current) => current.includes(value) ? current.filter((item) => item !== value) : [...current, value]);
  }

  async function createStaff(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    if (functions.length === 0) {
      setMessage("Selecciona al menos una función para el integrante.");
      return;
    }
    setSaving(true);
    const { error } = await supabase.from("laboratory_staff").insert({
      full_name: fullName.trim(),
      initials: initials.trim().toUpperCase(),
      position_title: positionTitle.trim(),
      functions,
      active,
      created_by: userId,
    });
    setSaving(false);
    if (error) {
      setMessage(error.code === "23505" ? "Ya existe un integrante con esas iniciales." : `No se pudo guardar el integrante: ${error.message}`);
      return;
    }
    setFullName(""); setInitials(""); setPositionTitle(""); setFunctions([]); setActive(true);
    setMessage("Integrante guardado correctamente.");
    await loadStaff();
  }

  async function toggleActive(person: StaffRecord) {
    const action = person.active ? "desactivar" : "reactivar";
    if (!window.confirm(`¿Seguro que deseas ${action} a ${person.full_name}?`)) return;
    setChangingId(person.id);
    setMessage("");
    const { error } = await supabase.from("laboratory_staff").update({ active: !person.active, updated_at: new Date().toISOString() }).eq("id", person.id);
    setChangingId(null);
    if (error) {
      setMessage(`No se pudo ${action} al integrante: ${error.message}`);
      return;
    }
    setMessage(`${person.full_name} quedó ${person.active ? "inactivo" : "activo"}.`);
    await loadStaff();
  }

  return <div className="personnel-directory">
    {canManage && mode === "create" && <form className="form-card personnel-create-form" onSubmit={createStaff}>
      <h2>Alta de personal</h2>
      <p>Registra al personal que podrá aparecer como responsable en las órdenes e informes.</p>
      <div className="form-grid">
        <label>Nombre completo<input required value={fullName} onChange={(event) => setFullName(event.target.value)} /></label>
        <label>Iniciales<input required maxLength={6} value={initials} onChange={(event) => setInitials(event.target.value.toUpperCase())} /></label>
        <label className="personnel-position-field">Puesto o cargo<input required value={positionTitle} onChange={(event) => setPositionTitle(event.target.value)} /></label>
      </div>
      <fieldset className="personnel-functions"><legend>Funciones</legend>{functionOptions.map((option) => <label key={option.value}><input type="checkbox" checked={functions.includes(option.value)} onChange={() => toggleFunction(option.value)} />{option.label}</label>)}</fieldset>
      <label className="personnel-active-check"><input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} />Registrar como activo</label>
      <div className="form-actions"><button className="button primary" disabled={saving}>{saving ? "Guardando…" : "Guardar integrante"}</button></div>
    </form>}
    {message && <p className="auth-message">{message}</p>}
    {mode === "list" && <section className="table-card">
      <div className="table-toolbar"><div><h2>Personal del laboratorio</h2><p>{staff.filter((person) => person.active).length} activos · {staff.length} registrados</p></div><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Buscar personal" aria-label="Buscar personal" /></div>
      <div className="table-wrap"><table className="personnel-table"><thead><tr><th>ID</th><th>Nombre completo</th><th>Iniciales</th><th>Puesto o cargo</th><th>Funciones</th><th>Estado</th>{canManage && <th>Acción</th>}</tr></thead>
        <tbody>{visibleStaff.length === 0 ? <tr><td colSpan={canManage ? 7 : 6}>No hay personal registrado.</td></tr> : visibleStaff.map((person) => <tr key={person.id}><td><strong>{String(person.internal_id).padStart(4, "0")}</strong></td><td>{person.full_name}</td><td><strong>{person.initials}</strong></td><td>{person.position_title}</td><td><div className="personnel-function-tags">{person.functions.map((item) => <span key={item}>{functionOptions.find((option) => option.value === item)?.label || item}</span>)}</div></td><td><span className={person.active ? "status status-green" : "status status-gray"}>{person.active ? "Activo" : "Inactivo"}</span></td>{canManage && <td><button type="button" className={person.active ? "personnel-status-button deactivate" : "personnel-status-button"} disabled={changingId === person.id} onClick={() => void toggleActive(person)}>{changingId === person.id ? "…" : person.active ? "Desactivar" : "Reactivar"}</button></td>}</tr>)}</tbody>
      </table></div>
    </section>}
  </div>;
}
