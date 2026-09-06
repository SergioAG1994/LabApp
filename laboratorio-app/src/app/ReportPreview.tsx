"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";

type PreviewEntry = {
  id: string;
  op: string;
  client: string;
  clientBranch?: string | null;
  clientAddress?: string | null;
  clientRfc?: string | null;
  clientPhone?: string | null;
  clientContact?: string | null;
  samplingNumber: string;
  sampler: string;
  quotation: string;
  received: string;
  due: string;
  reportNumber: string;
  analysis: string;
  sampleNumber: string;
  sampleId: string;
};

type PreviewRow = {
  id: string;
  label: string;
  unit: string | null;
  uncertainty: string | null;
  result_value: string | null;
  analyst_reference: string | null;
  result_date: string | null;
  analyst_name: string | null;
  par_form: string | null;
  method_reference: string | null;
};

type Props = {
  entry: PreviewEntry;
  rows: PreviewRow[];
  sampledAt: string;
  onSampledAtChange: (value: string) => void;
  onClose: () => void;
  onContinue: () => void;
  userId: string;
  readOnly?: boolean;
};

type SubsampleResults = Record<string, string[]>;

const FIXED_OBSERVATION = "Los efectos y resultados se relacionan únicamente con el sitio monitoreado y con las muestras ensayadas";

function normalize(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function eligibleSubsampleParameter(label: string) {
  const value = normalize(label);
  return (value.includes("grasa") && value.includes("aceite")) ||
    value.includes("coliformes fecales") || value.includes("coliformes totales") ||
    value.includes("e coli") || value.includes("escherichia coli");
}

function numericDate(value: Date) {
  return new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "2-digit", year: "numeric" }).format(value);
}

export function ReportPreview({ entry, rows, sampledAt, onSampledAtChange, onClose, onContinue, userId, readOnly = false }: Props) {
  const laboratorySampled = !["N/A", "—"].includes(entry.samplingNumber.trim().toUpperCase());
  const eligibleRows = useMemo(() => rows.filter((row) => eligibleSubsampleParameter(row.label)), [rows]);
  const [sampleInformation, setSampleInformation] = useState("");
  const [sampleIdentification, setSampleIdentification] = useState("");
  const [requestedBy, setRequestedBy] = useState(entry.clientContact || "");
  const [draftSampledAt, setDraftSampledAt] = useState(sampledAt);
  const [subsampleCount, setSubsampleCount] = useState<4 | 6>(4);
  const [subsampleResults, setSubsampleResults] = useState<SubsampleResults>({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [resultPages, setResultPages] = useState<PreviewRow[][]>(() => [rows]);
  const firstPageRef = useRef<HTMLElement>(null);
  const firstPageFixedRef = useRef<HTMLDivElement>(null);
  const rowMeasurementRef = useRef<HTMLDivElement>(null);
  const continuationFixedRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let active = true;
    async function loadDraft() {
      const { data, error } = await supabase.from("report_drafts")
        .select("sample_information, sample_identification, requested_by, sampled_at, subsample_count, subsample_results")
        .eq("sample_id", entry.sampleId).maybeSingle();
      if (!active) return;
      if (error) setMessage(`No se pudo recuperar el borrador: ${error.message}`);
      if (data) {
        setSampleInformation(data.sample_information || "");
        setSampleIdentification(data.sample_identification || "");
        setRequestedBy(data.requested_by || entry.clientContact || "");
        setDraftSampledAt(data.sampled_at || sampledAt);
        setSubsampleCount(data.subsample_count === 6 ? 6 : 4);
        setSubsampleResults((data.subsample_results || {}) as SubsampleResults);
      }
      setLoading(false);
    }
    void loadDraft();
    return () => { active = false; };
  }, [entry.clientContact, entry.sampleId, sampledAt]);

  const analysts = useMemo(() => [...new Set(rows.map((row) => row.analyst_name?.trim()).filter(Boolean) as string[])], [rows]);
  const firstPageRows = resultPages[0] || [];
  const continuationPages = resultPages.slice(1);
  const totalPages = 3 + continuationPages.length;
  const informationPage = 2 + continuationPages.length;
  const approvalPage = informationPage + 1;

  useLayoutEffect(() => {
    const page = firstPageRef.current;
    const firstFixed = firstPageFixedRef.current;
    const measurement = rowMeasurementRef.current;
    const continuationFixed = continuationFixedRef.current;
    if (!page || !firstFixed || !measurement || !continuationFixed || rows.length === 0) return;
    const paginate = () => {
      const style = window.getComputedStyle(page);
      const pageHeight = 279 * 96 / 25.4;
      const innerHeight = pageHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom) - 28;
      const headerHeight = measurement.querySelector("thead")?.getBoundingClientRect().height || 30;
      const measuredRows = Array.from(measurement.querySelectorAll("tbody tr"));
      const firstBudget = Math.max(80, innerHeight - firstFixed.getBoundingClientRect().height - headerHeight);
      const continuationBudget = Math.max(80, innerHeight - continuationFixed.getBoundingClientRect().height - headerHeight);
      const pages: PreviewRow[][] = [[]];
      let pageIndex = 0;
      let used = 0;
      rows.forEach((row, index) => {
        const rowHeight = measuredRows[index]?.getBoundingClientRect().height || 24;
        const budget = pageIndex === 0 ? firstBudget : continuationBudget;
        if (pages[pageIndex].length > 0 && used + rowHeight > budget) {
          pages.push([]);
          pageIndex += 1;
          used = 0;
        }
        pages[pageIndex].push(row);
        used += rowHeight;
      });
      setResultPages((current) => current.length === pages.length && current.every((group, index) => group.map((row) => row.id).join("|") === pages[index].map((row) => row.id).join("|")) ? current : pages);
    };
    const frame = window.requestAnimationFrame(paginate);
    const observer = new ResizeObserver(paginate);
    observer.observe(firstFixed);
    observer.observe(measurement);
    return () => { window.cancelAnimationFrame(frame); observer.disconnect(); };
  }, [rows]);

  function normalizedSubsampleResults() {
    return Object.fromEntries(eligibleRows.map((row) => [row.id, Array.from({ length: subsampleCount }, (_, index) => subsampleResults[row.id]?.[index] || "")])) as SubsampleResults;
  }

  async function saveDraft(showConfirmation = true) {
    setSaving(true);
    setMessage("");
    const { error } = await supabase.from("report_drafts").upsert({
      order_id: entry.id,
      sample_id: entry.sampleId,
      sample_information: sampleInformation.trim(),
      sample_identification: sampleIdentification.trim(),
      requested_by: requestedBy.trim(),
      sampled_at: laboratorySampled ? draftSampledAt || null : null,
      subsample_count: eligibleRows.length ? subsampleCount : null,
      subsample_results: eligibleRows.length ? normalizedSubsampleResults() : {},
      updated_by: userId,
      updated_at: new Date().toISOString(),
    }, { onConflict: "sample_id" });
    setSaving(false);
    if (error) {
      setMessage(`No se pudo guardar el borrador: ${error.message}`);
      return false;
    }
    if (showConfirmation) setMessage("Borrador guardado.");
    return true;
  }

  async function continueToConfirmation() {
    if (!sampleInformation.trim()) {
      setMessage("Captura la información de la muestra antes de continuar.");
      return;
    }
    if (!sampleIdentification.trim()) {
      setMessage("Captura la identificación de la muestra antes de continuar.");
      return;
    }
    if (!requestedBy.trim()) {
      setMessage("Captura quién solicita el análisis antes de continuar.");
      return;
    }
    if (laboratorySampled && !draftSampledAt) {
      setMessage("Captura la fecha de muestreo antes de continuar.");
      return;
    }
    if (eligibleRows.some((row) => Array.from({ length: subsampleCount }, (_, index) => subsampleResults[row.id]?.[index] || "").some((value) => !value.trim()))) {
      setMessage("Completa todos los resultados de las muestras simples antes de continuar.");
      return;
    }
    if (!(await saveDraft(false))) return;
    onSampledAtChange(laboratorySampled ? draftSampledAt : "");
    onContinue();
  }

  function setSubsampleValue(rowId: string, index: number, value: string) {
    setSubsampleResults((current) => ({
      ...current,
      [rowId]: Array.from({ length: subsampleCount }, (_, position) => position === index ? value : current[rowId]?.[position] || ""),
    }));
  }

  const packSampleDetailsAfterResults = continuationPages.length > 0 && continuationPages[continuationPages.length - 1].length <= 12;
  const sampleDetails = <table className="report-sample-info-table">
    <thead><tr><th>Información de la muestra</th><th>Observaciones</th></tr></thead>
    <tbody><tr>
      <td><textarea className="report-sample-info-input" aria-label="Información de la muestra" value={sampleInformation} onChange={(event) => setSampleInformation(event.target.value)} placeholder="Capture la descripción, condiciones de recepción y demás información registrada en la bitácora física." disabled={readOnly} /></td>
      <td className="report-observation-cell">
        <p>{FIXED_OBSERVATION}.</p>
        <p><b>Norma de muestreo:</b> {laboratorySampled ? "NMX-AA-003-1980" : "No aplica"}</p>
        <label><b>Fecha de muestreo:</b> {laboratorySampled ? <input type="date" value={draftSampledAt} onChange={(event) => setDraftSampledAt(event.target.value)} disabled={readOnly} /> : <span>No aplica</span>}</label>
        <p><b>Responsable del muestreo:</b> {laboratorySampled ? entry.sampler : "El cliente"}</p>
      </td>
    </tr></tbody>
  </table>;

  if (loading) return <div className="report-preview-backdrop"><div className="report-preview-loading">Preparando pre-informe…</div></div>;

  return <div className="report-preview-backdrop">
    <div className="report-preview-shell">
      <header className="report-preview-toolbar">
        <div><strong>Pre-informe</strong><span>Vista previa editable · todavía no es el PDF final</span></div>
        <div className="report-preview-actions">
          {!readOnly && <button className="button secondary" disabled={saving} onClick={() => void saveDraft()}>{saving ? "Guardando…" : "Guardar borrador"}</button>}
          {!readOnly && <button className="button primary" disabled={saving} onClick={() => void continueToConfirmation()}>Continuar a emisión</button>}
          <button className="report-preview-close" aria-label="Cerrar pre-informe" onClick={onClose}>×</button>
        </div>
      </header>
      {readOnly && <div className="report-preview-message" role="status">Informe emitido · vista de solo lectura.</div>}
      {message && <div className="report-preview-message" role="status">{message}</div>}
      <main className="report-preview-canvas">
        <section className="report-page report-first-page" ref={firstPageRef}>
          <div ref={firstPageFixedRef}>
          <ReportHeader page={1} totalPages={totalPages} reportNumber={entry.reportNumber} />
          <div className="report-title">INFORME DE RESULTADOS</div>
          <div className="report-client-block">
            <div className="report-client-row report-client-name"><b>Cliente:</b><span>{entry.client}{entry.clientBranch ? ` · ${entry.clientBranch}` : ""}</span></div>
            <div className="report-client-row report-client-address"><b>Dirección:</b><span>{entry.clientAddress || "—"}</span></div>
            <div className="report-client-row"><b>Contacto:</b><span>{entry.clientContact || "—"}</span></div>
            <div className="report-client-row"><b>Tel.:</b><span>{entry.clientPhone || "—"}</span></div>
            <div className="report-client-row"><b>RFC:</b><span>{entry.clientRfc || "—"}</span></div>
          </div>
          <div className="report-metadata-stack">
            <div className="report-metadata-box"><div><b>Número de informe:</b><span>BORRADOR</span></div><div><b>Fecha de informe:</b><span>{numericDate(new Date())}</span></div><div><b>Fecha recepción de muestra:</b><span>{entry.received}</span></div></div>
            <div className="report-metadata-box report-references"><strong>Referencias</strong><div><b>OP:</b><span>{entry.op}</span></div><div><b>No. muestra:</b><span>{entry.sampleNumber}</span></div><div><b>Cotización:</b><span>{entry.quotation && entry.quotation !== "—" ? entry.quotation : "N/A"}</span></div><div><b>Muestreo:</b><span>{entry.samplingNumber && entry.samplingNumber !== "—" ? entry.samplingNumber : "N/A"}</span></div></div>
          </div>
          <div className="report-sample-fields"><label><b>Identificación de la muestra:</b><input value={sampleIdentification} onChange={(event) => setSampleIdentification(event.target.value)} placeholder="Captura manual" disabled={readOnly} /></label><label><b>Solicita:</b><input value={requestedBy} onChange={(event) => setRequestedBy(event.target.value)} placeholder="Nombre de quien solicita" disabled={readOnly} /></label></div>
          <h3>Resultados de análisis</h3>
          </div>
          <ResultsTable rows={firstPageRows} />
          <ReportFooter page={1} totalPages={totalPages} />
        </section>

        {continuationPages.map((pageRows, index) => {
          const pageNumber = index + 2;
          return <section className="report-page report-results-continuation" key={`results-${pageNumber}`}>
            <ReportHeader page={pageNumber} totalPages={totalPages} reportNumber={entry.reportNumber} />
            <div className="report-title">INFORME DE RESULTADOS</div>
            <h3>Resultados de análisis — continuación</h3>
            <ResultsTable rows={pageRows} />
            {packSampleDetailsAfterResults && index === continuationPages.length - 1 && sampleDetails}
            <ReportFooter page={pageNumber} totalPages={totalPages} />
          </section>;
        })}

        <section className="report-page">
          <ReportHeader page={informationPage} totalPages={totalPages} reportNumber={entry.reportNumber} />
          {!packSampleDetailsAfterResults && sampleDetails}
          {eligibleRows.length > 0 && <><div className="subsample-heading"><h3>Resultados de muestras simples</h3><label>Cantidad de submuestras <select value={subsampleCount} onChange={(event) => setSubsampleCount(Number(event.target.value) as 4 | 6)} disabled={readOnly}><option value={4}>4</option><option value={6}>6</option></select></label></div>
            <table className="report-table subsample-table"><thead><tr><th>No. de muestra</th>{eligibleRows.map((row) => <th key={row.id}>{row.par_form || row.label}<small>{row.unit || ""}</small></th>)}</tr></thead><tbody>
              {Array.from({ length: subsampleCount }, (_, index) => <tr key={index}><td>{entry.sampleNumber}-{index + 1}</td>{eligibleRows.map((row) => <td key={row.id}><input aria-label={`${row.label}, submuestra ${index + 1}`} value={subsampleResults[row.id]?.[index] || ""} onChange={(event) => setSubsampleValue(row.id, index, event.target.value)} placeholder="Resultado" disabled={readOnly} /></td>)}</tr>)}
            </tbody></table></>}
          <h3>Personal responsable</h3>
          <table className="report-table responsible-table"><thead><tr><th>Responsable</th><th>Participación</th><th>Referencia</th></tr></thead><tbody>
            {analysts.map((analyst) => <tr key={analyst}><td>{analyst}</td><td>Analista</td><td>{analyst}</td></tr>)}
            {laboratorySampled && <tr><td>{entry.sampler}</td><td>Muestreador</td><td>{entry.sampler}</td></tr>}
          </tbody></table>
          <ReportFooter page={informationPage} totalPages={totalPages} />
        </section>

        <section className="report-page">
          <ReportHeader page={approvalPage} totalPages={totalPages} reportNumber={entry.reportNumber} />
          <div className="report-approval"><p>Los resultados contenidos en este informe fueron revisados y autorizados conforme al sistema de gestión del laboratorio.</p><div className="report-signature-line"/><strong>Responsable de revisión y autorización</strong><span>Pendiente de configurar nombre, cargo y firma</span></div>
          <div className="report-declarations"><h3>Declaraciones</h3><p>Los resultados corresponden exclusivamente a la muestra identificada en este informe.</p><p>La reproducción parcial de este documento requiere autorización escrita del laboratorio.</p><p>Este pre-informe permite comprobar el contenido y capturar la información faltante. No constituye todavía el informe final.</p></div>
          <div className="report-end">FIN DEL INFORME</div>
          <ReportFooter page={approvalPage} totalPages={totalPages} />
        </section>
      </main>
      <div className="report-pagination-measure" aria-hidden="true">
        <div ref={continuationFixedRef}><ReportHeader page={2} totalPages={totalPages} reportNumber={entry.reportNumber} /><div className="report-title">INFORME DE RESULTADOS</div><h3>Resultados de análisis — continuación</h3></div>
        <div ref={rowMeasurementRef}><ResultsTable rows={rows} /></div>
      </div>
    </div>
  </div>;
}

function ResultsTable({ rows }: { rows: PreviewRow[] }) {
  return <table className="report-table report-results-table"><thead><tr><th>Parámetro</th><th className="report-result-heading">Resultado</th><th>Unidades</th><th>Método</th><th>Analista</th><th>Fecha de análisis</th></tr></thead><tbody>
    {rows.map((row) => <tr key={row.id}><td>{row.par_form || row.label}</td><td>{row.result_value || "—"}</td><td>{row.unit || "—"}</td><td>{row.method_reference || "—"}</td><td>{row.analyst_name || "—"}</td><td>{row.result_date ? numericDate(new Date(`${row.result_date}T12:00:00`)) : "—"}</td></tr>)}
  </tbody></table>;
}

function ReportHeader({ page, totalPages, reportNumber }: { page: number; totalPages: number; reportNumber: string }) {
  return <header className="report-document-header"><div className="report-brand"><strong>GISSAMEX</strong><span>Laboratorio de análisis</span></div><div><b>F1INF-02</b>{page > 1 && <strong className="report-header-number">Número de informe: {reportNumber || "BORRADOR"}</strong>}<span>Página {page} de {totalPages}</span></div></header>;
}

function ReportFooter({ page, totalPages }: { page: number; totalPages: number }) {
  return <footer className="report-document-footer"><span>Informe en preparación · BORRADOR</span><span>{page} / {totalPages}</span></footer>;
}
