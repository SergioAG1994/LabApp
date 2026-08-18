"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

type ParameterRecord = {
  id: string;
  name: string;
  par_form: string | null;
  unit: string | null;
  method_reference: string | null;
};

export function ParameterDirectory({ canCreate }: { canCreate: boolean }) {
  const [parameters, setParameters] = useState<ParameterRecord[]>([]);
  const [shortName, setShortName] = useState("");
  const [formalName, setFormalName] = useState("");
  const [unit, setUnit] = useState("");
  const [method, setMethod] = useState("");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [editing, setEditing] = useState<ParameterRecord | null>(null);
  const [editShortName, setEditShortName] = useState("");
  const [editFormalName, setEditFormalName] = useState("");
  const [editUnit, setEditUnit] = useState("");
  const [editMethod, setEditMethod] = useState("");
  const [editSaving, setEditSaving] = useState(false);

  async function loadParameters() {
    const { data, error } = await supabase
      .from("parameters")
      .select("id, name, par_form, unit, method_reference")
      .eq("active", true)
      .order("name");
    if (error) {
      setMessage(`No se pudieron cargar los parámetros: ${error.message}`);
      return;
    }
    setParameters((data || []) as ParameterRecord[]);
  }

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadParameters(); }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  async function createParameter(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    setSaving(true);
    const { error } = await supabase.from("parameters").insert({
      name: shortName.trim(),
      par_form: formalName.trim(),
      unit: unit.trim(),
      method_reference: method.trim(),
    });
    setSaving(false);
    if (error) {
      setMessage(error.code === "23505" ? "Ya existe un parámetro con ese nombre corto." : `No se pudo guardar el parámetro: ${error.message}`);
      return;
    }
    setShortName("");
    setFormalName("");
    setUnit("");
    setMethod("");
    setMessage("Parámetro guardado correctamente.");
    await loadParameters();
  }

  function startEditing(parameter: ParameterRecord) {
    setEditing(parameter);
    setEditShortName(parameter.name);
    setEditFormalName(parameter.par_form || "");
    setEditUnit(parameter.unit || "");
    setEditMethod(parameter.method_reference || "");
    setMessage("");
  }

  function cancelEditing() {
    setEditing(null);
    setEditShortName("");
    setEditFormalName("");
    setEditUnit("");
    setEditMethod("");
  }

  async function updateParameter(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editing) return;
    setMessage("");
    setEditSaving(true);
    const { error } = await supabase
      .from("parameters")
      .update({
        name: editShortName.trim(),
        par_form: editFormalName.trim(),
        unit: editUnit.trim(),
        method_reference: editMethod.trim(),
      })
      .eq("id", editing.id);
    setEditSaving(false);
    if (error) {
      setMessage(error.code === "23505" ? "Ya existe un parámetro con ese nombre corto." : `No se pudo modificar el parámetro: ${error.message}`);
      return;
    }
    cancelEditing();
    setMessage("Parámetro modificado correctamente.");
    await loadParameters();
  }

  return <div className="parameter-directory">
    {canCreate && <form className="form-card parameter-create-form" onSubmit={createParameter}>
      <h2>Alta de parámetro</h2>
      <p>El parámetro quedará disponible para paquetes, multipaquetes y nuevas OAs.</p>
      <div className="form-grid">
        <label>Nombre corto<input required value={shortName} onChange={(event) => setShortName(event.target.value)} /></label>
        <label>Nombre formal<input required value={formalName} onChange={(event) => setFormalName(event.target.value)} /></label>
        <label>Unidades<input required value={unit} onChange={(event) => setUnit(event.target.value)} /></label>
        <label>Método<input required value={method} onChange={(event) => setMethod(event.target.value)} /></label>
      </div>
      <div className="form-actions"><button className="button primary" disabled={saving}>{saving ? "Guardando…" : "Guardar parámetro"}</button></div>
    </form>}
    {message && <p className="auth-message">{message}</p>}
    <section className="table-card">
      <div className="table-toolbar"><div><h2>Parámetros registrados</h2><p>{parameters.length} parámetros activos</p></div></div>
      <div className="table-wrap"><table className="parameter-table">
        <thead><tr><th>Nombre corto</th><th>Nombre formal</th><th>Unidades</th><th>Método</th>{canCreate && <th>Acciones</th>}</tr></thead>
        <tbody>{parameters.map((parameter) => <tr key={parameter.id}><td><strong>{parameter.name}</strong></td><td>{parameter.par_form || "—"}</td><td>{parameter.unit || "—"}</td><td>{parameter.method_reference || "—"}</td>{canCreate && <td><button type="button" className="parameter-edit-button" onClick={() => startEditing(parameter)}>Modificar</button></td>}</tr>)}</tbody>
      </table></div>
    </section>
    {editing && <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !editSaving) cancelEditing(); }}>
      <form className="modal parameter-edit-modal" onSubmit={updateParameter}>
        <button type="button" className="close" aria-label="Cerrar" disabled={editSaving} onClick={cancelEditing}>×</button>
        <h2>Modificar parámetro</h2>
        <p className="client-name">Actualiza la información de {editing.name}.</p>
        <div className="parameter-edit-grid">
          <label>Nombre corto<input required value={editShortName} onChange={(event) => setEditShortName(event.target.value)} /></label>
          <label>Nombre formal<input required value={editFormalName} onChange={(event) => setEditFormalName(event.target.value)} /></label>
          <label>Unidades<input required value={editUnit} onChange={(event) => setEditUnit(event.target.value)} /></label>
          <label>Método<input required value={editMethod} onChange={(event) => setEditMethod(event.target.value)} /></label>
        </div>
        <div className="form-actions"><button type="button" className="button secondary" disabled={editSaving} onClick={cancelEditing}>Cancelar</button><button className="button primary" disabled={editSaving}>{editSaving ? "Guardando…" : "Guardar cambios"}</button></div>
      </form>
    </div>}
  </div>;
}
