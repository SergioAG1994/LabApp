"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase";

type AnalysisPackage = { id: string; code: string; name: string };
type Parameter = { id: string; name: string; unit: string | null };
type MultiPackage = { id: string; name: string; sample_count: number };
type MultiItem = { multi_package_id: string; sample_position: number; parameter_id: string; display_order: number };
type SampleDraft = { mode: "package" | "custom"; packageId: string; parameterIds: string[] };

const today = () => new Date().toISOString().slice(0, 10);
const blankSample = (): SampleDraft => ({ mode: "package", packageId: "", parameterIds: [] });
const formatDate = (value: string) => new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(`${value}T12:00:00`));
function dueDate(received: string) {
  const date = new Date(`${received}T12:00:00`);
  let count = 0;
  while (count < 8) {
    date.setDate(date.getDate() + 1);
    if (date.getDay() !== 0 && date.getDay() !== 6) count += 1;
  }
  return date.toISOString().slice(0, 10);
}

export function MultiSampleOrderForm({ onCancel, onCreated }: { onCancel: () => void; onCreated: () => Promise<void> }) {
  const [packages, setPackages] = useState<AnalysisPackage[]>([]);
  const [parameters, setParameters] = useState<Parameter[]>([]);
  const [multiPackages, setMultiPackages] = useState<MultiPackage[]>([]);
  const [multiItems, setMultiItems] = useState<MultiItem[]>([]);
  const [client, setClient] = useState("");
  const [multiple, setMultiple] = useState(false);
  const [sampleCount, setSampleCount] = useState(1);
  const [samples, setSamples] = useState<SampleDraft[]>([blankSample()]);
  const [labSampling, setLabSampling] = useState<"" | "yes" | "no">("");
  const [samplingNumber, setSamplingNumber] = useState("");
  const [usesPreset, setUsesPreset] = useState<"" | "yes" | "no">("");
  const [selectedMultiPackage, setSelectedMultiPackage] = useState("");
  const [sampler, setSampler] = useState("");
  const [quotation, setQuotation] = useState("");
  const [receivedAt, setReceivedAt] = useState(today());
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [building, setBuilding] = useState(false);
  const [builderName, setBuilderName] = useState("");
  const [builderCount, setBuilderCount] = useState(2);
  const [builderParameters, setBuilderParameters] = useState<string[][]>([[], []]);
  const [builderSaving, setBuilderSaving] = useState(false);

  async function loadCatalogs() {
    const [packageResult, parameterResult, multiResult, itemResult] = await Promise.all([
      supabase.from("analysis_packages").select("id, code, name").eq("active", true).order("name"),
      supabase.from("parameters").select("id, name, unit").eq("active", true).order("name"),
      supabase.from("multi_packages").select("id, name, sample_count").eq("active", true).order("name"),
      supabase.from("multi_package_items").select("multi_package_id, sample_position, parameter_id, display_order").order("display_order"),
    ]);
    const packageData = (packageResult.data || []) as AnalysisPackage[];
    setPackages(packageData);
    const defaultPackage = packageData.find((item) => item.code === "NOM-001-2021-24H") || packageData[0];
    if (defaultPackage) {
      setSamples((current) => current.map((sample, index) => index === 0 && !sample.packageId
        ? { ...sample, packageId: defaultPackage.id }
        : sample));
    }
    setParameters((parameterResult.data || []) as Parameter[]);
    setMultiPackages((multiResult.data || []) as MultiPackage[]);
    setMultiItems((itemResult.data || []) as MultiItem[]);
  }

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadCatalogs(); }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  function resizeSamples(count: number) {
    const safe = Math.max(1, Math.min(20, count));
    setSampleCount(safe);
    setSamples((current) => Array.from({ length: safe }, (_, index) => current[index] || blankSample()));
  }

  function updateSample(index: number, patch: Partial<SampleDraft>) {
    setSamples((current) => current.map((sample, position) => position === index ? { ...sample, ...patch } : sample));
  }

  function toggleParameter(index: number, parameterId: string, builder = false) {
    if (builder) {
      setBuilderParameters((current) => current.map((ids, position) => position !== index ? ids : ids.includes(parameterId) ? ids.filter((id) => id !== parameterId) : [...ids, parameterId]));
      return;
    }
    const ids = samples[index].parameterIds;
    updateSample(index, { parameterIds: ids.includes(parameterId) ? ids.filter((id) => id !== parameterId) : [...ids, parameterId] });
  }

  function chooseMultiPackage(id: string) {
    setSelectedMultiPackage(id);
    const selected = multiPackages.find((item) => item.id === id);
    if (!selected) return;
    setMultiple(selected.sample_count > 1);
    resizeSamples(selected.sample_count);
    setSamples((current) => Array.from({ length: selected.sample_count }, (_, index) => ({
      ...(current[index] || blankSample()),
      mode: "custom",
      packageId: "",
      parameterIds: multiItems.filter((item) => item.multi_package_id === id && item.sample_position === index + 1).sort((a, b) => a.display_order - b.display_order).map((item) => item.parameter_id),
    })));
  }

  function changeBuilderCount(count: number) {
    const safe = Math.max(1, Math.min(20, count));
    setBuilderCount(safe);
    setBuilderParameters((current) => Array.from({ length: safe }, (_, index) => current[index] || []));
  }

  async function saveMultiPackage() {
    setMessage("");
    if (!builderName.trim() || builderParameters.some((ids) => ids.length === 0)) {
      setMessage("Captura el nombre y al menos un parámetro para cada muestra del multipaquete.");
      return;
    }
    setBuilderSaving(true);
    const { data, error } = await supabase.rpc("save_multi_package", {
      p_name: builderName.trim(),
      p_sample_parameters: builderParameters.map((parameter_ids) => ({ parameter_ids })),
    });
    setBuilderSaving(false);
    if (error) { setMessage(`No se pudo guardar el multipaquete: ${error.message}`); return; }
    await loadCatalogs();
    setBuilding(false);
    setBuilderName("");
    const id = (data as { id?: string } | null)?.id || "";
    setSelectedMultiPackage(id);
    setMultiple(builderCount > 1);
    resizeSamples(builderCount);
    setSamples((current) => Array.from({ length: builderCount }, (_, index) => ({ ...(current[index] || blankSample()), mode: "custom", packageId: "", parameterIds: builderParameters[index] })));
  }

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    if (labSampling === "") { setMessage("Indica si el muestreo fue realizado por el laboratorio."); return; }
    if (labSampling === "yes" && !samplingNumber.trim()) { setMessage("Captura el número de muestreo."); return; }
    if (multiple && usesPreset === "") { setMessage("Indica cómo se asignarán los análisis de las muestras."); return; }
    if (!multiple && !samples[0].packageId) { setMessage("Selecciona el análisis."); return; }
    if (multiple && usesPreset === "yes" && !selectedMultiPackage) { setMessage("Selecciona o crea un multipaquete."); return; }
    if (multiple && usesPreset === "no" && samples.some((sample) => sample.mode === "package" ? !sample.packageId : sample.parameterIds.length === 0)) {
      setMessage("Asigna un paquete o parámetros a cada muestra."); return;
    }

    setSaving(true);
    let clientName = client.trim();
    if (/^\d+$/.test(clientName)) {
      const lookup = await supabase.rpc("get_client_by_number", { p_client_number: Number(clientName) });
      if (lookup.error || !lookup.data) { setSaving(false); setMessage("No se encontró un cliente activo con ese número."); return; }
      clientName = (lookup.data as { name: string }).name;
    }
    const payload = samples.map((sample) => ({
      ...((!multiple || usesPreset === "no") && sample.mode === "package" ? { package_id: sample.packageId } : {}),
      ...(multiple && usesPreset === "no" && sample.mode === "custom" ? { parameter_ids: sample.parameterIds } : {}),
    }));
    const { error } = await supabase.rpc("create_sample_entry_batch_auto", {
      p_client_name: clientName,
      p_samples: payload,
      p_lab_sampling: labSampling === "yes",
      p_sampling_number: labSampling === "yes" ? samplingNumber : null,
      p_received_at: receivedAt,
      p_multi_package_id: multiple && usesPreset === "yes" ? selectedMultiPackage : null,
      p_sampled_at: null,
      p_sampler_name: labSampling === "yes" ? sampler || null : "El cliente",
      p_quotation_number: quotation || null,
      p_billing_details: null,
      p_precaptured: false,
    });
    setSaving(false);
    if (error) { setMessage(`No se pudo registrar la OP: ${error.message}`); return; }
    await onCreated();
  }

  const selectedMultiName = useMemo(() => multiPackages.find((item) => item.id === selectedMultiPackage)?.name, [multiPackages, selectedMultiPackage]);

  if (building) return <form className="order-form multi-order-form" onSubmit={(event) => { event.preventDefault(); void saveMultiPackage(); }}>
    <section className="form-card"><h2>Nuevo multipaquete de análisis</h2><p>Esta plantilla podrá reutilizarse en futuras OPs.</p><div className="form-grid"><label>Nombre del multipaquete<input required value={builderName} onChange={(event) => setBuilderName(event.target.value)} /></label><label>Cantidad de muestras<input required type="number" min="1" max="20" value={builderCount} onChange={(event) => changeBuilderCount(Number(event.target.value))} /></label></div></section>
    {builderParameters.map((ids, index) => <section className="form-card sample-config-card" key={index}><h2>Muestra {index + 1}</h2><p>Selecciona los parámetros que formarán su OA.</p><div className="parameter-picker">{parameters.map((parameter) => <label className="parameter-option" key={parameter.id}><input type="checkbox" checked={ids.includes(parameter.id)} onChange={() => toggleParameter(index, parameter.id, true)} /><span>{parameter.name}<small>{parameter.unit || "Sin unidad"}</small></span></label>)}</div></section>)}
    {message && <p className="auth-message">{message}</p>}<div className="form-actions"><button type="button" className="button secondary" onClick={() => setBuilding(false)}>Volver</button><button className="button primary" disabled={builderSaving}>{builderSaving ? "Guardando…" : "Guardar multipaquete"}</button></div>
  </form>;

  return <form className={multiple ? "order-form multi-order-form" : "order-form"} onSubmit={submit}>
    <section className="form-card">
      <h2>Datos de recepción</h2>
      <p>La OP se genera automáticamente al guardar. La fecha compromiso se calcula a ocho días hábiles desde la recepción.</p>
      <div className="form-grid">
        <label>Cliente<input required value={client} onChange={(event) => setClient(event.target.value)} /></label>
        <label>¿El laboratorio realizó el muestreo?<select required value={labSampling} onChange={(event) => { const value = event.target.value as "" | "yes" | "no"; setLabSampling(value); if (value === "no") { setSamplingNumber(""); setSampler("El cliente"); } else if (value === "yes" && sampler === "El cliente") { setSampler(""); } }}><option value="">Seleccionar…</option><option value="yes">Sí</option><option value="no">No</option></select></label>
        {labSampling === "yes" && <label>Número de muestreo<input required value={samplingNumber} onChange={(event) => setSamplingNumber(event.target.value)} /></label>}
        {labSampling === "yes" && <label>Muestreador<input value={sampler} onChange={(event) => setSampler(event.target.value)} /></label>}
        {labSampling === "no" && <label>Número de muestreo<input value="N/A" disabled /></label>}
        {labSampling === "no" && <label>Muestreador<input value="El cliente" disabled /></label>}
        <label>Cotización<input value={quotation} onChange={(event) => setQuotation(event.target.value)} /></label>
        <label>Fecha de recepción<input required type="date" value={receivedAt} onChange={(event) => setReceivedAt(event.target.value)} /></label>
        {!multiple && <label>Análisis<select required value={samples[0].packageId} onChange={(event) => updateSample(0, { mode: "package", packageId: event.target.value })}><option value="">Seleccionar…</option>{packages.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}
      </div>
    </section>
    <section className="form-card">
      <h2>Fechas automáticas</h2>
      <div className="summary-row"><div><span>Fecha compromiso</span><strong>{formatDate(dueDate(receivedAt))}</strong></div><div><span>Número de muestra</span><strong>Se asigna al guardar</strong></div><div><span>Número de informe</span><strong>Se asigna al emitir</strong></div></div>
      <label className="check-label"><input type="checkbox" checked={multiple} onChange={(event) => { const checked = event.target.checked; setMultiple(checked); resizeSamples(checked ? Math.max(2, sampleCount) : 1); setSelectedMultiPackage(""); if (!checked) setUsesPreset(""); }} />Registrar más de una muestra en esta OP</label>
    </section>
    {multiple && <>
      <section className="form-card"><h2>Cantidad de muestras</h2><label className="standalone-field">¿Cuántas muestras tendrá la OP?<input type="number" min="2" max="20" value={sampleCount} disabled={Boolean(selectedMultiPackage)} onChange={(event) => resizeSamples(Number(event.target.value))} /></label></section>
      <section className="form-card"><h2>Configuración de análisis</h2><div className="form-grid"><label>¿Requiere un paquete predeterminado de análisis?<select required value={usesPreset} onChange={(event) => { setUsesPreset(event.target.value as "" | "yes" | "no"); setSelectedMultiPackage(""); }}><option value="">Seleccionar…</option><option value="yes">Sí, usar un multipaquete</option><option value="no">No, configurar cada muestra</option></select></label>{usesPreset === "yes" && <label>Multipaquete<select required value={selectedMultiPackage} onChange={(event) => chooseMultiPackage(event.target.value)}><option value="">Seleccionar…</option>{multiPackages.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.sample_count} muestra(s)</option>)}</select></label>}</div>{usesPreset === "yes" && <button type="button" className="button secondary builder-button" onClick={() => setBuilding(true)}>＋ Dar de alta multipaquete</button>}{selectedMultiName && <p className="selection-note">Plantilla seleccionada: <strong>{selectedMultiName}</strong></p>}</section>
      {samples.map((sample, index) => <section className="form-card sample-config-card" key={index}><h2>Muestra {index + 1}</h2><p>El número de muestra se asignará automáticamente al registrar la OP.</p><div className="form-grid">{usesPreset === "no" && <label>Forma de asignar el análisis<select value={sample.mode} onChange={(event) => updateSample(index, { mode: event.target.value as "package" | "custom", packageId: "", parameterIds: [] })}><option value="package">Paquete existente</option><option value="custom">Parámetros individuales</option></select></label>}{usesPreset === "no" && sample.mode === "package" && <label>Paquete de análisis<select required value={sample.packageId} onChange={(event) => updateSample(index, { packageId: event.target.value })}><option value="">Seleccionar…</option>{packages.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}</div>{usesPreset === "no" && sample.mode === "custom" && <div className="parameter-picker">{parameters.map((parameter) => <label className="parameter-option" key={parameter.id}><input type="checkbox" checked={sample.parameterIds.includes(parameter.id)} onChange={() => toggleParameter(index, parameter.id)} /><span>{parameter.name}<small>{parameter.unit || "Sin unidad"}</small></span></label>)}</div>}{usesPreset === "yes" && <p className="selection-note">{sample.parameterIds.length} parámetros definidos por el multipaquete.</p>}</section>)}
    </>}
    {message && <p className="auth-message">{message}</p>}<div className="form-actions"><button type="button" className="button secondary" onClick={onCancel}>Cancelar</button><button className="button primary" disabled={saving}>{saving ? "Guardando…" : multiple ? "Registrar OP" : "Registrar entrada"}</button></div>
  </form>;
}
