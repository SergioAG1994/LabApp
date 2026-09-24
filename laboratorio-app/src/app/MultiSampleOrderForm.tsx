"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase";
import { eligibleStaff, type LaboratoryStaff } from "@/lib/staff-attribution";

type AnalysisPackage = { id: string; code: string; name: string };
type Parameter = { id: string; name: string; unit: string | null };
type MultiPackage = { id: string; name: string; sample_count: number };
type MultiItem = { multi_package_id: string; sample_position: number; parameter_id: string; display_order: number };
type ClientOption = { id: string; client_number: number; name: string; branch: string | null; contact_name: string | null; address: string | null; rfc: string | null };
type SampleDraft = { mode: "package" | "custom"; packageId: string; parameterIds: string[] };
type AnalysisStrategy = "" | "same" | "different" | "multi-existing" | "multi-new";

type ParameterCategory = "metals" | "microbiological" | "physicochemical";

const metalParameterNames = new Set([
  "al", "antimonio", "as", "ba", "berilio", "ca", "cd", "cr", "cr vi", "cu", "fe", "hg", "mg", "mn", "na", "ni", "pb", "potasio", "selenio", "si", "sn", "sr", "zinc", "zn",
]);
const normalizeParameterName = (value: string) => value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
function parameterCategory(parameter: Parameter): ParameterCategory {
  const name = normalizeParameterName(parameter.name);
  if (metalParameterNames.has(name)) return "metals";
  if (name.startsWith("col fec") || name.startsWith("col tot") || name.startsWith("e. coli") || name === "hh" || name.includes("huevo")) return "microbiological";
  return "physicochemical";
}

function ParameterPicker({ parameters, selectedIds, onToggle }: { parameters: Parameter[]; selectedIds: string[]; onToggle: (parameterId: string) => void }) {
  const categories: Array<{ id: ParameterCategory; label: string }> = [
    { id: "metals", label: "Metales" },
    { id: "microbiological", label: "Microbiológicos" },
    { id: "physicochemical", label: "Fisicoquímicos" },
  ];

  return <div className="parameter-picker grouped-parameter-picker">
    {categories.map((category) => {
      const categoryParameters = parameters.filter((parameter) => parameterCategory(parameter) === category.id);
      return <details className="parameter-category" key={category.id} open>
        <summary>{category.label}</summary>
        <div className="parameter-category-grid">{categoryParameters.map((parameter) => <label className="parameter-option" key={parameter.id}><input type="checkbox" checked={selectedIds.includes(parameter.id)} onChange={() => onToggle(parameter.id)} /><span>{parameter.name}<small>{parameter.unit || "Sin unidad"}</small></span></label>)}</div>
      </details>;
    })}
  </div>;
}

const today = () => new Date().toISOString().slice(0, 10);
const blankSample = (): SampleDraft => ({ mode: "package", packageId: "", parameterIds: [] });
const clientDisplayName = (client: ClientOption) => `${client.name}${client.branch ? ` · ${client.branch}` : ""}`;
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
  const [clients, setClients] = useState<ClientOption[]>([]);
  const [client, setClient] = useState("");
  const [selectedClientNumber, setSelectedClientNumber] = useState<number | null>(null);
  const [multiple, setMultiple] = useState(false);
  const [sampleCount, setSampleCount] = useState(1);
  const [samples, setSamples] = useState<SampleDraft[]>([blankSample()]);
  const [saveCustomPackage, setSaveCustomPackage] = useState(false);
  const [customPackageName, setCustomPackageName] = useState("");
  const [labSampling, setLabSampling] = useState<"" | "yes" | "no">("");
  const [samplingNumber, setSamplingNumber] = useState("");
  const [analysisStrategy, setAnalysisStrategy] = useState<AnalysisStrategy>("");
  const [selectedMultiPackage, setSelectedMultiPackage] = useState("");
  const [sharedMode, setSharedMode] = useState<"package" | "custom">("package");
  const [sharedPackageId, setSharedPackageId] = useState("");
  const [sharedParameterIds, setSharedParameterIds] = useState<string[]>([]);
  const [sampler, setSampler] = useState("");
  const [samplerStaffId, setSamplerStaffId] = useState("");
  const [laboratoryStaff, setLaboratoryStaff] = useState<LaboratoryStaff[]>([]);
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
    const [packageResult, parameterResult, multiResult, itemResult, clientResult, staffResult] = await Promise.all([
      supabase.from("analysis_packages").select("id, code, name").eq("active", true).order("name"),
      supabase.from("parameters").select("id, name, unit").eq("active", true).order("name"),
      supabase.from("multi_packages").select("id, name, sample_count").eq("active", true).order("name"),
      supabase.from("multi_package_items").select("multi_package_id, sample_position, parameter_id, display_order").order("display_order"),
      supabase.from("clients").select("id, client_number, name, branch, contact_name, address, rfc").eq("active", true).order("name"),
      supabase.from("laboratory_staff").select("id, full_name, initials, active, functions").order("full_name"),
    ]);
    const packageData = (packageResult.data || []) as AnalysisPackage[];
    setPackages(packageData);
    const defaultPackage = packageData.find((item) => item.code === "NOM-001-2021-24H") || packageData[0];
    if (defaultPackage) {
      setSamples((current) => current.map((sample, index) => index === 0 && !sample.packageId
        ? { ...sample, packageId: defaultPackage.id }
        : sample));
      setSharedPackageId((current) => current || defaultPackage.id);
    }
    setParameters((parameterResult.data || []) as Parameter[]);
    setMultiPackages((multiResult.data || []) as MultiPackage[]);
    setMultiItems((itemResult.data || []) as MultiItem[]);
    setClients((clientResult.data || []) as ClientOption[]);
    setLaboratoryStaff((staffResult.data || []) as LaboratoryStaff[]);
    if (staffResult.error) setMessage(`No se pudo cargar el personal: ${staffResult.error.message}`);
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

  function toggleSharedParameter(parameterId: string) {
    setSharedParameterIds((current) => current.includes(parameterId)
      ? current.filter((id) => id !== parameterId)
      : [...current, parameterId]);
  }

  function chooseAnalysisStrategy(strategy: AnalysisStrategy) {
    setMessage("");
    setSelectedMultiPackage("");
    setAnalysisStrategy(strategy);
    if (strategy === "multi-new") {
      setBuilding(true);
      return;
    }
    if (strategy !== "multi-existing") resizeSamples(Math.max(2, sampleCount));
  }

  function chooseMultiPackage(id: string) {
    setSelectedMultiPackage(id);
    const selected = multiPackages.find((item) => item.id === id);
    if (!selected) return;
    setAnalysisStrategy("multi-existing");
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
    setAnalysisStrategy("multi-existing");
    setMultiple(builderCount > 1);
    resizeSamples(builderCount);
    setSamples((current) => Array.from({ length: builderCount }, (_, index) => ({ ...(current[index] || blankSample()), mode: "custom", packageId: "", parameterIds: builderParameters[index] })));
  }

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    if (labSampling === "") { setMessage("Indica si el muestreo fue realizado por el laboratorio."); return; }
    if (labSampling === "yes" && !samplingNumber.trim()) { setMessage("Captura el número de muestreo."); return; }
    if (multiple && analysisStrategy === "") { setMessage("Selecciona cómo se asignarán los análisis de las muestras."); return; }
    if (!multiple && (samples[0].mode === "package" ? !samples[0].packageId : samples[0].parameterIds.length === 0)) { setMessage("Selecciona el análisis o al menos un parámetro personalizado."); return; }
    if (multiple && analysisStrategy === "multi-existing" && !selectedMultiPackage) { setMessage("Selecciona un multipaquete existente."); return; }
    if (multiple && analysisStrategy === "same" && (sharedMode === "package" ? !sharedPackageId : sharedParameterIds.length === 0)) {
      setMessage("Selecciona el paquete o los parámetros que se aplicarán a todas las muestras."); return;
    }
    if (multiple && analysisStrategy === "different" && samples.some((sample) => sample.mode === "package" ? !sample.packageId : sample.parameterIds.length === 0)) {
      setMessage("Asigna un paquete o parámetros a cada muestra."); return;
    }

    const clientForOrder = clients.find((item) => item.client_number === selectedClientNumber)
      || clients.find((item) => item.client_number.toString() === client.trim() || clientDisplayName(item) === client.trim());
    if (!clientForOrder) { setMessage("Selecciona un cliente y sucursal de la lista."); return; }
    if (!multiple && samples[0].mode === "custom" && saveCustomPackage && !customPackageName.trim()) {
      setMessage("Captura un nombre para guardar la configuración como paquete reutilizable.");
      return;
    }

    setSaving(true);
    let singleSamplePayload = samples[0].mode === "package"
      ? { package_id: samples[0].packageId }
      : { parameter_ids: samples[0].parameterIds };

    if (!multiple && samples[0].mode === "custom" && saveCustomPackage) {
      const { data, error } = await supabase.rpc("save_custom_analysis_package", {
        p_name: customPackageName.trim(),
        p_parameter_ids: samples[0].parameterIds,
      });
      if (error || !data) {
        setSaving(false);
        setMessage(`No se pudo guardar el paquete personalizado: ${error?.message || "no se obtuvo el identificador"}`);
        return;
      }
      singleSamplePayload = { package_id: data as string };
      await loadCatalogs();
    }

    const payload = !multiple
      ? [singleSamplePayload]
      : analysisStrategy === "same"
        ? Array.from({ length: sampleCount }, () => sharedMode === "package"
          ? { package_id: sharedPackageId }
          : { parameter_ids: sharedParameterIds })
        : analysisStrategy === "different"
          ? samples.map((sample) => sample.mode === "package"
            ? { package_id: sample.packageId }
            : { parameter_ids: sample.parameterIds })
          : samples.map(() => ({}));
    const orderArgs = {
      p_samples: payload,
      p_lab_sampling: labSampling === "yes",
      p_sampling_number: labSampling === "yes" ? samplingNumber : null,
      p_received_at: receivedAt,
      p_multi_package_id: multiple && analysisStrategy === "multi-existing" ? selectedMultiPackage : null,
      p_sampled_at: null,
      p_sampler_name: labSampling === "yes" ? sampler || null : "El cliente",
      p_quotation_number: quotation || null,
      p_billing_details: null,
      p_precaptured: false,
    };
    let { error } = await supabase.rpc("create_sample_entry_batch_auto_with_staff", {
      ...orderArgs, p_client_id: clientForOrder.id, p_sampler_staff_id: labSampling === "yes" ? samplerStaffId || null : null,
    });
    if (error?.code === "PGRST202" && error.message.includes("create_sample_entry_batch_auto_with_staff")) {
      ({ error } = await supabase.rpc("create_sample_entry_batch_auto_for_client", {
        ...orderArgs, p_client_id: clientForOrder.id,
      }));
    }
    // SQL is deployed separately. Only a missing RPC may use the old numeric
    // client reference; validation, authorization and network errors must surface.
    if (error?.code === "PGRST202" && error.message.includes("create_sample_entry_batch_auto_for_client")) {
      ({ error } = await supabase.rpc("create_sample_entry_batch_auto", {
        ...orderArgs, p_client_name: clientForOrder.client_number.toString(),
      }));
    }
    setSaving(false);
    if (error) { setMessage(`No se pudo registrar la OP: ${error.message}`); return; }
    await onCreated();
  }

  const selectedMultiName = useMemo(() => multiPackages.find((item) => item.id === selectedMultiPackage)?.name, [multiPackages, selectedMultiPackage]);
  const selectedClient = useMemo(() => clients.find((item) => item.client_number === selectedClientNumber), [clients, selectedClientNumber]);
  function selectClientFromValue(value: string, normalizeDisplay = false) {
    const match = clients.find((item) => clientDisplayName(item) === value.trim() || item.client_number.toString() === value.trim());
    setSelectedClientNumber(match?.client_number || null);
    setClient(match && normalizeDisplay ? clientDisplayName(match) : value);
  }

  if (building) return <form className="order-form multi-order-form" onSubmit={(event) => { event.preventDefault(); void saveMultiPackage(); }}>
    <section className="form-card"><h2>Nuevo multipaquete de análisis</h2><p>Esta plantilla podrá reutilizarse en futuras OPs.</p><div className="form-grid"><label>Nombre del multipaquete<input required value={builderName} onChange={(event) => setBuilderName(event.target.value)} /></label><label>Cantidad de muestras<input required type="number" min="1" max="20" value={builderCount} onChange={(event) => changeBuilderCount(Number(event.target.value))} /></label></div></section>
    {builderParameters.map((ids, index) => <section className="form-card sample-config-card" key={index}><h2>Muestra {index + 1}</h2><p>Selecciona los parámetros que formarán su OA.</p><ParameterPicker parameters={parameters} selectedIds={ids} onToggle={(parameterId) => toggleParameter(index, parameterId, true)} /></section>)}
    {message && <p className="auth-message">{message}</p>}<div className="form-actions"><button type="button" className="button secondary" onClick={() => { setBuilding(false); setAnalysisStrategy(""); }}>Volver</button><button className="button primary" disabled={builderSaving}>{builderSaving ? "Guardando…" : "Guardar multipaquete"}</button></div>
  </form>;

  return <form className={multiple ? "order-form multi-order-form" : "order-form"} onSubmit={submit}>
    <section className="form-card">
      <h2>Datos de recepción</h2>
      <p>La OP se genera automáticamente al guardar. La fecha compromiso se calcula a ocho días hábiles desde la recepción.</p>
      <div className="form-grid">
        <label>Cliente y sucursal<input required list="existing-clients" value={client} onChange={(event) => selectClientFromValue(event.target.value)} onBlur={(event) => selectClientFromValue(event.target.value, true)} placeholder="Buscar por cliente o número" /><datalist id="existing-clients">{clients.map((item) => <option key={item.client_number} value={clientDisplayName(item)} label={`Cliente ${item.client_number}`} />)}</datalist></label>
        <label>¿El laboratorio realizó el muestreo?<select required value={labSampling} onChange={(event) => { const value = event.target.value as "" | "yes" | "no"; setLabSampling(value); if (value === "no") { setSamplingNumber(""); setSampler("El cliente"); setSamplerStaffId(""); } else if (value === "yes" && sampler === "El cliente") { setSampler(""); } }}><option value="">Seleccionar…</option><option value="yes">Sí</option><option value="no">No</option></select></label>
        {labSampling === "yes" && <label>Número de muestreo<input required value={samplingNumber} onChange={(event) => setSamplingNumber(event.target.value)} /></label>}
        {labSampling === "yes" && <label>Muestreador<select value={samplerStaffId} onChange={(event) => { setSamplerStaffId(event.target.value); setSampler(laboratoryStaff.find((person) => person.id === event.target.value)?.full_name || ""); }}><option value="">Sin asignar</option>{laboratoryStaff.filter((person) => eligibleStaff(person, "muestreador")).map((person) => <option key={person.id} value={person.id}>{person.full_name} ({person.initials})</option>)}</select></label>}
        {labSampling === "no" && <label>Número de muestreo<input value="N/A" disabled /></label>}
        {labSampling === "no" && <label>Muestreador<input value="El cliente" disabled /></label>}
        <label>Cotización<input value={quotation} onChange={(event) => setQuotation(event.target.value)} /></label>
        <label>Fecha de recepción<input required type="date" value={receivedAt} onChange={(event) => setReceivedAt(event.target.value)} /></label>
        {!multiple && <label>Análisis<select required value={samples[0].mode === "custom" ? "custom" : samples[0].packageId} onChange={(event) => {
          setSaveCustomPackage(false);
          setCustomPackageName("");
          if (event.target.value === "custom") updateSample(0, { mode: "custom", packageId: "" });
          else updateSample(0, { mode: "package", packageId: event.target.value, parameterIds: [] });
        }}><option value="">Seleccionar…</option>{packages.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}<option value="custom">Personalizar parámetros</option></select></label>}
      </div>
      {selectedClient && <div className="selected-client"><strong>Cliente {selectedClient.client_number}: {selectedClient.name}</strong><span>{[selectedClient.branch ? `Sucursal: ${selectedClient.branch}` : null, selectedClient.contact_name, selectedClient.rfc, selectedClient.address].filter(Boolean).join(" · ") || "Cliente existente seleccionado"}</span></div>}
      {!multiple && samples[0].mode === "custom" && <div className="strategy-detail"><p className="selection-note">Selecciona los parámetros que integrarán esta OA personalizada.</p><ParameterPicker parameters={parameters} selectedIds={samples[0].parameterIds} onToggle={(parameterId) => toggleParameter(0, parameterId)} /><label className="check-label"><input type="checkbox" checked={saveCustomPackage} onChange={(event) => setSaveCustomPackage(event.target.checked)} />Guardar esta configuración para futuras OPs</label>{saveCustomPackage && <label className="standalone-field">Nombre del paquete reutilizable<input required value={customPackageName} onChange={(event) => setCustomPackageName(event.target.value)} placeholder="Ej. Análisis especial de descarga" /></label>}</div>}
    </section>
    <section className="form-card">
      <h2>Fechas automáticas</h2>
      <div className="summary-row"><div><span>Fecha compromiso</span><strong>{formatDate(dueDate(receivedAt))}</strong></div><div><span>Número de muestra</span><strong>Se asigna al guardar</strong></div><div><span>Número de informe</span><strong>Se asigna al emitir</strong></div></div>
      <label className="check-label"><input type="checkbox" checked={multiple} onChange={(event) => { const checked = event.target.checked; setMultiple(checked); resizeSamples(checked ? Math.max(2, sampleCount) : 1); setSelectedMultiPackage(""); if (!checked) setAnalysisStrategy(""); }} />Registrar más de una muestra en esta OP</label>
    </section>
    {multiple && <>
      <section className="form-card"><h2>Cantidad de muestras</h2><label className="standalone-field">¿Cuántas muestras tendrá la OP?<input type="number" min="2" max="20" value={sampleCount} disabled={analysisStrategy === "multi-existing" && Boolean(selectedMultiPackage)} onChange={(event) => resizeSamples(Number(event.target.value))} /></label></section>
      <section className="form-card"><h2>Configuración de análisis</h2><p>Elige la forma en que se asignarán los análisis a las muestras de esta OP.</p><div className="analysis-strategy-grid">
        <button type="button" className={analysisStrategy === "same" ? "analysis-strategy-card selected" : "analysis-strategy-card"} onClick={() => chooseAnalysisStrategy("same")} data-tooltip="Todas las muestras llevarán los mismos parámetros."><strong>Mismo análisis</strong><span>Aplicar la misma configuración a todas las muestras</span></button>
        <button type="button" className={analysisStrategy === "different" ? "analysis-strategy-card selected" : "analysis-strategy-card"} onClick={() => chooseAnalysisStrategy("different")} data-tooltip="Cada muestra puede llevar un paquete o parámetros diferentes."><strong>Distinto por muestra</strong><span>Configurar el análisis de cada muestra por separado</span></button>
        <button type="button" className={analysisStrategy === "multi-existing" ? "analysis-strategy-card selected" : "analysis-strategy-card"} onClick={() => chooseAnalysisStrategy("multi-existing")} data-tooltip="Reutiliza una configuración previamente guardada."><strong>Multipaquete existente</strong><span>Usar una plantilla reutilizable</span></button>
        <button type="button" className={analysisStrategy === "multi-new" ? "analysis-strategy-card selected" : "analysis-strategy-card"} onClick={() => chooseAnalysisStrategy("multi-new")} data-tooltip="Crea y guarda una configuración reutilizable para futuras OPs."><strong>Nuevo multipaquete</strong><span>Crear una nueva plantilla de muestras y parámetros</span></button>
      </div>
      {analysisStrategy === "same" && <div className="strategy-detail"><div className="form-grid"><label>Forma de asignar el análisis<select value={sharedMode} onChange={(event) => { setSharedMode(event.target.value as "package" | "custom"); }}><option value="package">Paquete existente</option><option value="custom">Parámetros individuales</option></select></label>{sharedMode === "package" && <label>Paquete de análisis<select required value={sharedPackageId} onChange={(event) => setSharedPackageId(event.target.value)}><option value="">Seleccionar…</option>{packages.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}</div>{sharedMode === "custom" && <ParameterPicker parameters={parameters} selectedIds={sharedParameterIds} onToggle={toggleSharedParameter} />}<p className="selection-note">La configuración seleccionada se aplicará a las {sampleCount} muestras.</p></div>}
      {analysisStrategy === "multi-existing" && <div className="strategy-detail form-grid"><label>Multipaquete<select required value={selectedMultiPackage} onChange={(event) => chooseMultiPackage(event.target.value)}><option value="">Seleccionar…</option>{multiPackages.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.sample_count} muestra(s)</option>)}</select></label>{selectedMultiName && <p className="selection-note">Plantilla seleccionada: <strong>{selectedMultiName}</strong></p>}</div>}
      </section>
      {analysisStrategy === "different" && samples.map((sample, index) => <section className="form-card sample-config-card" key={index}><h2>Muestra {index + 1}</h2><p>El número de muestra se asignará automáticamente al registrar la OP.</p><div className="form-grid"><label>Forma de asignar el análisis<select value={sample.mode} onChange={(event) => updateSample(index, { mode: event.target.value as "package" | "custom", packageId: "", parameterIds: [] })}><option value="package">Paquete existente</option><option value="custom">Parámetros individuales</option></select></label>{sample.mode === "package" && <label>Paquete de análisis<select required value={sample.packageId} onChange={(event) => updateSample(index, { packageId: event.target.value })}><option value="">Seleccionar…</option>{packages.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}</div>{sample.mode === "custom" && <ParameterPicker parameters={parameters} selectedIds={sample.parameterIds} onToggle={(parameterId) => toggleParameter(index, parameterId)} />}</section>)}
      {analysisStrategy === "multi-existing" && selectedMultiName && <section className="form-card sample-config-card"><p className="selection-note">El multipaquete <strong>{selectedMultiName}</strong> definirá los parámetros de sus {sampleCount} muestras.</p></section>}
    </>}
    {message && <p className="auth-message">{message}</p>}<div className="form-actions"><button type="button" className="button secondary" onClick={onCancel}>Cancelar</button><button className="button primary" disabled={saving}>{saving ? "Guardando…" : multiple ? "Registrar OP" : "Registrar entrada"}</button></div>
  </form>;
}
