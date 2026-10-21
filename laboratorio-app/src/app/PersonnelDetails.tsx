"use client";

import { useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import { employeeNumber, type StaffRecord, type StaffDetails, type StaffAuthorization, type PersonnelParameter } from "@/lib/personnel";
import styles from "./PersonnelDetails.module.css";
import { PersonnelTraining } from "./PersonnelTraining";

function displayDate(value: string) { return value.split("-").reverse().join("/"); }
function today() { return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Mexico_City", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date()); }

function AuthorizationSection({ kind, personId, parameters, records, canManage, locked, onSaved, onBusy, onMessage, onDraft }: {
  kind: "internal" | "ema"; personId: string; parameters: PersonnelParameter[]; records: StaffAuthorization[];
  canManage: boolean; locked: boolean; onSaved: (record: StaffAuthorization) => void; onBusy: (busy: boolean) => void; onMessage: (message: string) => void; onDraft: (kind: "internal" | "ema", open: boolean) => void;
}) {
  const [editing, setEditing] = useState<StaffAuthorization | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [parameterId, setParameterId] = useState("");
  const [date, setDate] = useState("");
  const [saving, setSaving] = useState(false);
  const selectedParameter = parameters.find((p) => p.id === parameterId);
  const list = records.filter((record) => record.authorization_kind === kind);
  const currentDate = today();
  const isSignatory = list.some((record) => record.authorized_at <= currentDate);

  function closeForm() { setFormOpen(false); setEditing(null); setParameterId(""); setDate(""); onDraft(kind, false); }
  async function save(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canManage || saving || locked) return;
    setSaving(true); onBusy(true); onMessage("");
    try {
      const values = { staff_id: personId, parameter_id: parameterId, authorization_kind: kind, authorized_at: date,
        method_reference: selectedParameter?.method_reference || "" };
      const result = editing
        ? await supabase.from("staff_parameter_authorizations").update({ authorized_at: date })
          .eq("id", editing.id).eq("updated_at", editing.updated_at).select().maybeSingle()
        : await supabase.from("staff_parameter_authorizations").insert(values).select().single();
      if (result.error) {
        onMessage(result.error.code === "23505" ? "Ya existe una autorización para ese parámetro y método. Puedes editar su fecha." : `No se pudo guardar la autorización: ${result.error.message}`);
        return;
      }
      if (!result.data) { onMessage("La autorización cambió mientras la editabas. Cierra y vuelve a abrir la ficha para revisarla."); return; }
      onSaved(result.data as StaffAuthorization); closeForm(); onMessage("Autorización guardada.");
    } catch { onMessage("No se pudo conectar para guardar. Tus datos siguen en el formulario."); }
    finally { setSaving(false); onBusy(false); }
  }

  return <section className={styles.section}>
    <h3>{kind === "internal" ? "Autorizaciones internas del laboratorio" : "Autorizaciones de signatario EMA"}</h3>
    <p className={styles.help}>{kind === "internal" ? "Registra el permiso emitido por el laboratorio después de la capacitación y evaluación." : "Registra por separado los parámetros autorizados por EMA. No se deducen de los permisos internos."}</p>
    {kind === "ema" && <p className={styles.help}><strong>Signatario: {isSignatory ? "Sí" : "No"}</strong>{!isSignatory && list.length > 0 ? " · Hay autorizaciones con fecha futura." : ""}</p>}
    <div className={styles.tableWrap}><table className={styles.table}>
      <thead><tr><th>Parámetro</th><th>Método autorizado</th><th>Desde</th>{canManage && <th>Acción</th>}</tr></thead>
      <tbody>{list.length === 0 ? <tr><td className={styles.empty} colSpan={canManage ? 4 : 3}>Sin autorizaciones registradas.</td></tr> : list.map((record) => <tr key={record.id}>
        <td>{parameters.find((parameter) => parameter.id === record.parameter_id)?.name || "Parámetro no disponible"}</td>
        <td>{record.method_reference}</td><td>{displayDate(record.authorized_at)}{record.authorized_at > currentDate && <span className={styles.status}>Programada</span>}</td>
        {canManage && <td><button type="button" disabled={locked || saving} onClick={() => { setEditing(record); setParameterId(record.parameter_id); setDate(record.authorized_at); setFormOpen(true); onDraft(kind, true); }}>Editar fecha</button></td>}
      </tr>)}</tbody>
    </table></div>
    {canManage && !formOpen && <div className={styles.actions}><button type="button" disabled={locked} className="button secondary" onClick={() => { closeForm(); setFormOpen(true); onDraft(kind, true); }}>＋ Agregar autorización</button></div>}
    {canManage && formOpen && <form className={styles.authForm} onSubmit={save}>
      <div className={styles.grid}><label>Parámetro<select required value={parameterId} disabled={locked || saving || Boolean(editing)} onChange={(event) => setParameterId(event.target.value)}>
        <option value="">Selecciona un parámetro</option>{parameters.filter((parameter) => (parameter.active && Boolean(parameter.method_reference?.trim())) || parameter.id === editing?.parameter_id).map((parameter) => <option key={parameter.id} value={parameter.id}>{parameter.name}</option>)}
      </select></label><label>Fecha de autorización<input required type="date" value={date} disabled={locked || saving} onChange={(event) => setDate(event.target.value)} /></label></div>
      <p className={styles.method}>Método: {editing?.method_reference || selectedParameter?.method_reference || "Se toma del catálogo al seleccionar el parámetro."}</p>
      <div className={styles.actions}><button className="button secondary" type="button" disabled={locked || saving} onClick={closeForm}>Cancelar</button><button className="button primary" disabled={locked || saving}>{saving ? "Guardando…" : "Guardar autorización"}</button></div>
    </form>}
  </section>;
}

export function PersonnelDetails({ person, canManage, onClose, onSaved }: { person: StaffRecord; canManage: boolean; onClose: () => void; onSaved: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const drafts = useRef(new Set<string>());
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  const [activeTab, setActiveTab] = useState(0);
  const [trainingOpened, setTrainingOpened] = useState(false);
  const [details, setDetails] = useState<StaffDetails | null>(null);
  const [parameters, setParameters] = useState<PersonnelParameter[]>([]);
  const [authorizations, setAuthorizations] = useState<StaffAuthorization[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [authorizationBusy, setAuthorizationBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [name, setName] = useState("");
  const [initials, setInitials] = useState("");
  const [position, setPosition] = useState("");
  const [education, setEducation] = useState("");
  const [joinedAt, setJoinedAt] = useState("");
  const busy = saving || authorizationBusy;
  const dirty = Boolean(details && (name !== details.full_name || initials !== details.initials || position !== details.position_title || education !== (details.education || "") || joinedAt !== (details.joined_at || "")));

  useEffect(() => {
    dialog.current?.showModal();
    let cancelled = false;
    void (async () => {
      try {
        const [personResult, parameterResult, authorizationResult] = await Promise.all([
          supabase.from("laboratory_staff").select("id,internal_id,full_name,initials,position_title,functions,active,education,joined_at,updated_at").eq("id", person.id).single(),
          supabase.from("parameters").select("id,name,method_reference,active").order("name"),
          supabase.from("staff_parameter_authorizations").select("id,staff_id,parameter_id,authorization_kind,method_reference,authorized_at,updated_at").eq("staff_id", person.id).order("authorized_at"),
        ]);
        if (cancelled) return;
        if (personResult.error || parameterResult.error || authorizationResult.error) { setMessage("No se pudo cargar la ficha. Cierra e intenta nuevamente."); return; }
        const record = personResult.data as StaffDetails;
        setDetails(record); setName(record.full_name); setInitials(record.initials); setPosition(record.position_title);
        setEducation(record.education || ""); setJoinedAt(record.joined_at || "");
        setParameters(parameterResult.data as PersonnelParameter[]); setAuthorizations(authorizationResult.data as StaffAuthorization[]);
      } catch { if (!cancelled) setMessage("No se pudo conectar para cargar la ficha."); }
      finally { if (!cancelled) setLoading(false); }
    })();
    return () => { cancelled = true; };
  }, [person.id]);

  function close() {
    if (busy) return;
    if ((dirty || drafts.current.size > 0) && !window.confirm("Tienes cambios sin guardar. ¿Cerrar la ficha?")) return;
    dialog.current?.close();
    onClose();
  }
  async function saveGeneral(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!details || !canManage || busy) return;
    setSaving(true); setMessage("");
    try {
      const { data, error } = await supabase.from("laboratory_staff").update({ full_name: name.trim(), initials: initials.trim().toUpperCase(),
        position_title: position.trim(), education: education.trim() || null, joined_at: joinedAt || null, updated_at: new Date().toISOString() })
        .eq("id", person.id).eq("updated_at", details.updated_at).select().maybeSingle();
      if (error) { setMessage(error.code === "23505" ? "Otro integrante ya utiliza esas iniciales." : `No se pudo guardar: ${error.message}`); return; }
      if (!data) { setMessage("Otra persona modificó esta ficha. Tus cambios siguen aquí; cierra y vuelve a abrir para revisar los datos actuales."); return; }
      const record = data as StaffDetails;
      setDetails(record); setName(record.full_name); setInitials(record.initials); setPosition(record.position_title);
      setEducation(record.education || ""); setJoinedAt(record.joined_at || ""); setMessage("Información general guardada."); onSaved();
    } catch { setMessage("No se pudo conectar para guardar. Tus cambios siguen en pantalla."); }
    finally { setSaving(false); }
  }
  function savedAuthorization(record: StaffAuthorization) {
    setAuthorizations((current) => [...current.filter((item) => item.id !== record.id), record].sort((a, b) => a.authorized_at.localeCompare(b.authorized_at)));
  }
  function selectTab(index: number) {
    setActiveTab(index);
    if (index === 1) setTrainingOpened(true);
  }

  return <dialog ref={dialog} className={styles.dialog} aria-labelledby="personnel-detail-title" onCancel={(event) => { event.preventDefault(); close(); }}>
    <header className={styles.header}><div><p className={styles.eyebrow}>FICHA DE PERSONAL · EMPLEADO {employeeNumber(person.internal_id)}</p>
      <h2 id="personnel-detail-title">{details?.full_name || person.full_name}</h2><p>{details?.position_title || person.position_title} · {person.active ? "Activo" : "Inactivo"}</p></div>
      <button type="button" className={styles.close} disabled={busy} onClick={close} aria-label="Cerrar ficha">×</button></header>
    <div className={styles.body}>
      {message && <p className={styles.notice} role="status">{message}</p>}
      {loading ? <p>Cargando ficha…</p> : details && <>
        <div className={styles.tabs} role="tablist" aria-label="Secciones de la ficha">
          {["Información general", "Capacitación"].map((label, index) => <button key={label} type="button" role="tab"
            ref={(element) => { tabs.current[index] = element; }}
            id={`personnel-tab-${index}`} aria-controls={`personnel-panel-${index}`} aria-selected={activeTab === index}
            tabIndex={activeTab === index ? 0 : -1} onClick={() => selectTab(index)}
            onKeyDown={(event) => {
              let next: number;
              if (event.key === "ArrowRight" || event.key === "ArrowLeft") next = 1 - index;
              else if (event.key === "Home") next = 0;
              else if (event.key === "End") next = 1;
              else return;
              event.preventDefault(); selectTab(next); tabs.current[next]?.focus();
            }}>{label}</button>)}
        </div>
        <div role="tabpanel" id="personnel-panel-0" aria-labelledby="personnel-tab-0" hidden={activeTab !== 0} tabIndex={0}>
        <section className={styles.section}><h3>Información general</h3><p className={styles.help}>Completa la formación y la fecha real de ingreso al laboratorio.</p>
          <form onSubmit={saveGeneral}><div className={styles.grid}>
            <label>Número de empleado<input readOnly disabled value={employeeNumber(details.internal_id)} /></label>
            <label>Nombre completo<input required maxLength={200} disabled={!canManage || busy} value={name} onChange={(event) => setName(event.target.value)} /></label>
            <label>Iniciales<input required maxLength={6} disabled={!canManage || busy} value={initials} onChange={(event) => setInitials(event.target.value.toUpperCase())} /></label>
            <label>Puesto o cargo<input required maxLength={200} disabled={!canManage || busy} value={position} onChange={(event) => setPosition(event.target.value)} /></label>
            <label>Formación / título profesional o técnico<input maxLength={500} disabled={!canManage || busy} value={education} placeholder="Ej. Técnico laboratorista" onChange={(event) => setEducation(event.target.value)} /></label>
            <label>Fecha de ingreso al laboratorio<input type="date" disabled={!canManage || busy} value={joinedAt} onChange={(event) => setJoinedAt(event.target.value)} /></label>
          </div>{canManage && <div className={styles.actions}><button className="button primary" disabled={busy || !dirty}>{saving ? "Guardando…" : "Guardar información general"}</button></div>}</form>
        </section>
        {(["internal", "ema"] as const).map((kind) => <AuthorizationSection key={kind} kind={kind} personId={person.id} parameters={parameters} records={authorizations} canManage={canManage} locked={busy} onSaved={savedAuthorization} onBusy={setAuthorizationBusy} onMessage={setMessage} onDraft={(section, open) => { if (open) drafts.current.add(section); else drafts.current.delete(section); }} />)}
        </div>
        <div role="tabpanel" id="personnel-panel-1" aria-labelledby="personnel-tab-1" hidden={activeTab !== 1} tabIndex={0}>
          {trainingOpened && <PersonnelTraining personId={person.id} canManage={canManage} locked={busy} onBusy={setAuthorizationBusy}
            onDraft={(open) => { if (open) drafts.current.add("training"); else drafts.current.delete("training"); }} />}
        </div>
      </>}
    </div>
  </dialog>;
}
