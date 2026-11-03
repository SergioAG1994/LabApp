"use client";

import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { countPackageParameters } from "@/lib/package-parameter-count";
import { supabase } from "@/lib/supabase";
import styles from "./EntryTemplateTabs.module.css";

type Kind = "standard" | "custom" | "multi";
type Template = { id: string; name: string; active: boolean; kind: Kind; sampleCount: number; parameterCount?: number };
type Parameter = { name: string; unit: string | null };
type ParameterRow = { parameter_id: string; sample_position?: number; parameters: Parameter | Parameter[] | null };
const entryTabs = [
  { value: "entries", label: "Registro de entradas" },
  { value: "cancelled", label: "OPs eliminados" },
  { value: "templates", label: "Administrar plantillas" },
] as const;
export type EntryTab = (typeof entryTabs)[number]["value"];
const templateKinds = [
  { value: "standard", label: "Paquetes predeterminados" },
  { value: "custom", label: "Personalizados" },
  { value: "multi", label: "Multipaquetes" },
] as const;

export function EntryTemplateTabs({ enabled, readOnly, tab, onTabChange, children }: {
  enabled: boolean;
  readOnly: boolean;
  tab: EntryTab;
  onTabChange: (tab: EntryTab) => void;
  children: ReactNode;
}) {
  const id = useId();
  const buttons = useRef<Array<HTMLButtonElement | null>>([]);
  if (!enabled) return <>{children}</>;

  return <>
    <div className={styles.tabs} role="tablist" aria-label="Entrada de muestras">
      {entryTabs.map(({ value, label }, index) => <button
        key={value}
        ref={(button) => { buttons.current[index] = button; }}
        id={`${id}-tab-${index}`}
        type="button"
        role="tab"
        aria-selected={tab === value}
        aria-controls={`${id}-panel-${index}`}
        tabIndex={tab === value ? 0 : -1}
        className={`sample-list-tab${tab === value ? " active" : ""}`}
        onClick={() => onTabChange(value)}
        onKeyDown={(event) => {
          const count = entryTabs.length;
          const next = event.key === "Home" ? 0 : event.key === "End" ? count - 1
            : event.key === "ArrowLeft" ? (index + count - 1) % count
            : event.key === "ArrowRight" ? (index + 1) % count : null;
          if (next === null) return;
          event.preventDefault();
          onTabChange(entryTabs[next].value);
          buttons.current[next]?.focus();
        }}
      >{label}</button>)}
    </div>
    {entryTabs.map(({ value }, index) => <div key={value} id={`${id}-panel-${index}`}
      role="tabpanel" aria-labelledby={`${id}-tab-${index}`} hidden={tab !== value} tabIndex={0}>
      {tab === value && (value === "templates" ? <TemplateDirectory readOnly={readOnly} /> : children)}
    </div>)}
  </>;
}

function TemplateDirectory({ readOnly }: { readOnly: boolean }) {
  const [templates, setTemplates] = useState<Template[] | null>(null);
  const [kind, setKind] = useState<Kind>("standard");
  const [filter, setFilter] = useState<"all" | "active" | "inactive">("all");
  const [selectedId, setSelectedId] = useState("");
  const [loadingError, setLoadingError] = useState("");
  const [reload, setReload] = useState(0);
  const [saving, setSaving] = useState(false);
  const [feedback, setFeedback] = useState<{ text: string; error: boolean } | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const [packages, multi] = await Promise.all([
        supabase.from("analysis_packages").select("id, code, name, active, package_parameters(parameters(name))").order("name"),
        supabase.from("multi_packages").select("id, name, active, sample_count").order("name"),
      ]);
      if (cancelled) return;
      const error = packages.error || multi.error;
      if (error) { setLoadingError(error.message); return; }
      setTemplates([
        ...(packages.data || []).map(({ id, name, active, code, package_parameters }): Template => ({
          id, name, active, kind: code.startsWith("PERSONALIZADO-") ? "custom" : "standard", sampleCount: 1,
          parameterCount: countPackageParameters(package_parameters.map(({ parameters }) =>
            (Array.isArray(parameters) ? parameters[0] : parameters)?.name)),
        })),
        ...(multi.data || []).map(({ sample_count, ...row }) => ({ ...row, kind: "multi" as const, sampleCount: sample_count })),
      ]);
    }
    void load();
    return () => { cancelled = true; };
  }, [reload]);

  const visible = (templates || []).filter((template) => template.kind === kind
    && (filter === "all" || template.active === (filter === "active")));
  const selected = visible.find((template) => template.id === selectedId);

  async function changeStatus(template: Template) {
    if (readOnly || saving || template.kind === "standard") return;
    const active = !template.active;
    if (!active && !window.confirm(`¿Desactivar «${template.name}»? No aparecerá en altas nuevas. Las órdenes existentes no cambiarán.`)) return;
    setSaving(true);
    setFeedback(null);
    try {
      const { error } = await supabase.rpc("set_analysis_template_active", {
        p_kind: template.kind, p_template_id: template.id, p_active: active,
      });
      if (error) throw error;
      setTemplates((current) => current?.map((item) => item.id === template.id && item.kind === template.kind
        ? { ...item, active } : item) ?? null);
      setFeedback({ text: `«${template.name}» quedó ${active ? "activa" : "inactiva"}.`, error: false });
    } catch (error) {
      const detail = error && typeof error === "object" && "message" in error ? String(error.message) : "";
      setFeedback({ text: `No se pudo cambiar el estado de la plantilla.${detail ? ` ${detail}` : ""}`, error: true });
    } finally {
      setSaving(false);
    }
  }

  return <section className={`table-card ${styles.directory}`}>
    <div className={styles.heading}>
      <h2>Administrar plantillas</h2>
      <p>Las plantillas inactivas no aparecen en altas nuevas. Las órdenes anteriores se conservan.</p>
    </div>
    <div className={styles.controls}>
      <div className={styles.kinds} role="group" aria-label="Tipo de plantilla">
        {templateKinds.map(({ value, label }) => <button key={value} type="button" className="button secondary"
          aria-pressed={kind === value} onClick={() => { setKind(value); setSelectedId(""); }}>
          {label}
        </button>)}
      </div>
      <label className={styles.filter}>Estado
        <select value={filter} onChange={(event) => setFilter(event.target.value as typeof filter)}>
          <option value="all">Todas</option><option value="active">Activas</option><option value="inactive">Inactivas</option>
        </select>
      </label>
    </div>
    {feedback && <p className={feedback.error ? "auth-message" : styles.feedback} role={feedback.error ? "alert" : "status"}>{feedback.text}</p>}
    {loadingError ? <div role="alert"><p>No se pudieron cargar las plantillas: {loadingError}</p>
      <button className="button secondary" type="button" onClick={() => { setLoadingError(""); setReload((value) => value + 1); }}>Reintentar</button>
    </div> : !templates ? <p role="status">Cargando plantillas…</p> : <div className={styles.layout}>
      <ul className={styles.list} aria-label="Plantillas">
        {visible.map((template) => <li key={template.id}><button type="button" className={styles.item}
          aria-pressed={selected?.id === template.id} onClick={() => { setSelectedId(template.id); setFeedback(null); }}>
          <span><strong>{template.name}</strong>
            {template.parameterCount !== undefined && <small>{template.parameterCount} {template.parameterCount === 1 ? "parámetro" : "parámetros"}</small>}
            {template.kind === "multi" && <small>{template.sampleCount} {template.sampleCount === 1 ? "muestra" : "muestras"}</small>}
          </span>
          <span className={template.active ? styles.active : styles.inactive}>{template.active ? "Activa" : "Inactiva"}</span>
        </button></li>)}
        {!visible.length && <li className={styles.empty}>No hay plantillas con este filtro.</li>}
      </ul>
      <section className={styles.detail} aria-label="Detalle de plantilla">
        {selected ? <>
          <div className={styles.detailHeader}><h3>{selected.name}</h3>
            {!readOnly && selected.kind !== "standard" && <button className={`button ${selected.active ? "secondary" : "primary"}`} type="button"
              disabled={saving} onClick={() => void changeStatus(selected)}>
              {saving ? "Guardando…" : selected.active ? "Desactivar" : "Activar"}
            </button>}
          </div>
          {selected.kind === "standard" && <p className={styles.empty}>Paquete predeterminado · solo consulta</p>}
          <TemplateParameters key={`${selected.kind}:${selected.id}`} template={selected} />
        </> : <p className={styles.empty}>Selecciona una plantilla para ver sus parámetros.</p>}
      </section>
    </div>}
  </section>;
}

function TemplateParameters({ template: { id, kind, sampleCount } }: { template: Template }) {
  const [rows, setRows] = useState<ParameterRow[] | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let cancelled = false;
    async function load() {
      const result = kind !== "multi"
        ? await supabase.from("package_parameters").select("parameter_id, parameters(name, unit)").eq("package_id", id).order("display_order")
        : await supabase.from("multi_package_items").select("sample_position, parameter_id, parameters(name, unit)").eq("multi_package_id", id).order("display_order");
      if (cancelled) return;
      if (result.error) { setError(result.error.message); return; }
      setRows(result.data);
    }
    void load();
    return () => { cancelled = true; };
  }, [id, kind]);

  if (error) return <p className="auth-message" role="alert">No se pudieron cargar los parámetros: {error}</p>;
  if (!rows) return <p role="status">Cargando parámetros…</p>;
  return Array.from({ length: sampleCount }, (_, index) => {
    const parameters = rows.filter((row) => (row.sample_position ?? 1) === index + 1);
    return <div className={styles.parameterGroup} key={index}>
      <h4>{kind === "multi" ? `Muestra ${index + 1}` : "Parámetros"}</h4>
      {parameters.length ? <ul>{parameters.map((row) => {
        const parameter = Array.isArray(row.parameters) ? row.parameters[0] : row.parameters;
        return <li key={row.parameter_id}><span>{parameter?.name || "Parámetro no disponible"}</span>
          {parameter?.unit && <small>{parameter.unit}</small>}</li>;
      })}</ul> : <p>No hay parámetros registrados.</p>}
    </div>;
  });
}
