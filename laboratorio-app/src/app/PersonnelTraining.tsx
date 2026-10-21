"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { StaffTrainingRecord } from "@/lib/personnel";
import styles from "./PersonnelDetails.module.css";

type Props = {
  personId: string;
  canManage: boolean;
  locked: boolean;
  onBusy: (busy: boolean) => void;
  onDraft: (open: boolean) => void;
};

export function PersonnelTraining({ personId, canManage, locked, onBusy, onDraft }: Props) {
  const [records, setRecords] = useState<StaffTrainingRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [message, setMessage] = useState("");
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<StaffTrainingRecord | null>(null);
  const [name, setName] = useState("");
  const [instructor, setInstructor] = useState("");
  const [kind, setKind] = useState<"internal" | "external">("internal");
  const [date, setDate] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const { data, error } = await supabase.from("staff_training_records")
          .select("id,staff_id,training_name,instructor,training_kind,received_at,updated_at")
          .eq("staff_id", personId).order("received_at", { ascending: false }).order("id");
        if (cancelled) return;
        if (error) { setLoadError(true); return; }
        setRecords(data as StaffTrainingRecord[]);
        setLoadError(false);
      } catch { if (!cancelled) setLoadError(true); }
      finally { if (!cancelled) setLoading(false); }
    })();
    return () => { cancelled = true; };
  }, [personId, attempt]);

  function openForm(record: StaffTrainingRecord | null = null) {
    setEditing(record);
    setName(record?.training_name || "");
    setInstructor(record?.instructor || "");
    setKind(record?.training_kind || "internal");
    setDate(record?.received_at || "");
    setMessage("");
    setFormOpen(true);
    onDraft(true);
  }

  function closeForm() { setFormOpen(false); setEditing(null); onDraft(false); }

  async function save(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canManage || locked || saving) return;
    if (!name.trim() || !instructor.trim()) { setMessage("Completa el nombre y quién impartió la capacitación."); return; }
    setSaving(true); onBusy(true); setMessage("");
    try {
      const values = { training_name: name.trim(), instructor: instructor.trim(), training_kind: kind, received_at: date };
      const { data, error } = editing
        ? await supabase.from("staff_training_records").update(values)
          .eq("id", editing.id).eq("staff_id", personId).eq("updated_at", editing.updated_at).select().maybeSingle()
        : await supabase.from("staff_training_records").insert({ ...values, staff_id: personId }).select().single();
      if (error) { setMessage(`No se pudo guardar la capacitación: ${error.message}`); return; }
      if (!data) { setMessage("Esta capacitación cambió mientras la editabas. Cierra y vuelve a abrir la ficha para revisar la versión actual."); return; }
      const record = data as StaffTrainingRecord;
      setRecords((current) => [...current.filter((item) => item.id !== record.id), record]
        .sort((a, b) => b.received_at.localeCompare(a.received_at) || a.id.localeCompare(b.id)));
      closeForm();
      setMessage("Capacitación guardada.");
    } catch { setMessage("No se pudo conectar para guardar. Tus datos siguen en el formulario."); }
    finally { setSaving(false); onBusy(false); }
  }

  return <section className={styles.section} aria-labelledby="personnel-training-heading">
    <h3 id="personnel-training-heading">Historial de capacitación</h3>
    <p className={styles.help}>Registra las capacitaciones recibidas por esta persona, de la más reciente a la más antigua. Registrar una capacitación no otorga una autorización para analizar o firmar resultados.</p>
    {message && <p className={styles.notice} role="status">{message}</p>}
    {loading ? <p role="status">Cargando capacitaciones…</p> : loadError ? <div role="alert">
      <p>No se pudieron cargar las capacitaciones.</p>
      <button className="button secondary" type="button" onClick={() => { setLoading(true); setAttempt((value) => value + 1); }}>Reintentar</button>
    </div> : <>
      <div className={styles.tableWrap}><table className={styles.table}>
        <caption className={styles.srOnly}>Capacitaciones recibidas</caption>
        <thead><tr><th scope="col">Capacitación</th><th scope="col">Quién la impartió</th><th scope="col">Tipo</th><th scope="col">Fecha recibida</th>{canManage && <th scope="col">Acción</th>}</tr></thead>
        <tbody>{records.length === 0 ? <tr><td className={styles.empty} colSpan={canManage ? 5 : 4}>Sin capacitaciones registradas.</td></tr> : records.map((record) => <tr key={record.id}>
          <td>{record.training_name}</td><td>{record.instructor}</td><td>{record.training_kind === "internal" ? "Interna" : "Externa"}</td><td>{record.received_at.split("-").reverse().join("/")}</td>
          {canManage && <td><button type="button" disabled={locked || formOpen} aria-label={`Editar capacitación: ${record.training_name}`} onClick={() => openForm(record)}>Editar</button></td>}
        </tr>)}</tbody>
      </table></div>
      {canManage && !formOpen && <div className={styles.actions}><button className="button secondary" type="button" disabled={locked} onClick={() => openForm()}>＋ Agregar capacitación</button></div>}
      {canManage && formOpen && <form className={styles.authForm} onSubmit={save}>
        <h4>{editing ? "Editar capacitación" : "Nueva capacitación"}</h4>
        <div className={styles.grid}>
          <label>Nombre de la capacitación<input autoFocus required maxLength={300} value={name} disabled={locked} onChange={(event) => setName(event.target.value)} /></label>
          <label>Quién impartió la capacitación<input required maxLength={300} value={instructor} disabled={locked} placeholder="Nombre de la persona o institución" onChange={(event) => setInstructor(event.target.value)} /></label>
          <label>Tipo de capacitación<select value={kind} disabled={locked} onChange={(event) => setKind(event.target.value as "internal" | "external")}><option value="internal">Interna</option><option value="external">Externa</option></select></label>
          <label>Fecha en que se recibió<input required type="date" value={date} disabled={locked} onChange={(event) => setDate(event.target.value)} /></label>
        </div>
        <div className={styles.actions}><button className="button secondary" type="button" disabled={locked} onClick={closeForm}>Cancelar</button><button className="button primary" disabled={locked}>{saving ? "Guardando…" : "Guardar capacitación"}</button></div>
      </form>}
    </>}
  </section>;
}
