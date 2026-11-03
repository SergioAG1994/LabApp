"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import Image from "next/image";
import { buildSubsampleLayout, subsampleValue, type SubsampleColumn, type SubsampleResults } from "@/lib/report-subsamples";
import { supabase } from "@/lib/supabase";
import "./ReportDocument.css";

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
  samplerStaffId?: string | null;
  quotation: string;
  received: string;
  due: string;
  reportNumber: string;
  issuedAt?: string | null;
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
  analyst_staff_id?: string | null;
  par_form: string | null;
  method_reference: string | null;
};

type LaboratoryStaff = {
  id: string;
  full_name: string;
  initials: string;
  position_title: string;
  active: boolean;
};

type ResponsiblePerson = {
  key: string;
  fullName: string;
  initials: string;
  positionTitle: string;
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

const FIXED_OBSERVATION = "Los efectos y resultados se relacionan únicamente con el sitio monitoreado y con las muestras ensayadas";

function numericDate(value: Date) {
  return new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "2-digit", year: "numeric" }).format(value).replaceAll("/", "-");
}

function reportDate(value: Date) {
  return new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "long", year: "numeric" })
    .formatToParts(value).filter(({ type }) => type !== "literal").map(({ value }) => value).join(" ");
}

const reportParameterCollator = new Intl.Collator("es-MX", { sensitivity: "base", numeric: true });

function reportParameterName(row: PreviewRow) {
  return row.par_form || row.label;
}

export function ReportPreview({ entry, rows, sampledAt, onSampledAtChange, onClose, onContinue, userId, readOnly = false }: Props) {
  const laboratorySampled = !["N/A", "—"].includes(entry.samplingNumber.trim().toUpperCase());
  const { columns, mainRows, requiresSix } = useMemo(() => {
    const layout = buildSubsampleLayout(rows);
    layout.mainRows.sort((a, b) => reportParameterCollator.compare(reportParameterName(a), reportParameterName(b)));
    return layout;
  }, [rows]);
  const [sampleInformation, setSampleInformation] = useState("");
  const [sampleIdentification, setSampleIdentification] = useState("");
  const [requestedBy, setRequestedBy] = useState(entry.clientContact || "");
  const [draftSampledAt, setDraftSampledAt] = useState(sampledAt);
  const [draftSubsampleCount, setDraftSubsampleCount] = useState<4 | 6>(4);
  const subsampleCount = requiresSix ? 6 : draftSubsampleCount;
  const [subsampleResults, setSubsampleResults] = useState<SubsampleResults>({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [resultPages, setResultPages] = useState<PreviewRow[][]>(() => [mainRows]);
  const [laboratoryStaff, setLaboratoryStaff] = useState<LaboratoryStaff[]>([]);
  const [staffLoading, setStaffLoading] = useState(true);
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
        setDraftSubsampleCount(data.subsample_count === 6 ? 6 : 4);
        setSubsampleResults((data.subsample_results || {}) as SubsampleResults);
      }
      setLoading(false);
    }
    void loadDraft();
    return () => { active = false; };
  }, [entry.clientContact, entry.sampleId, sampledAt]);

  useEffect(() => {
    let active = true;
    async function loadLaboratoryStaff() {
      const { data } = await supabase.rpc("list_sample_report_staff", { p_sample_id: entry.sampleId });
      if (!active) return;
      setLaboratoryStaff((data || []) as LaboratoryStaff[]);
      setStaffLoading(false);
    }
    void loadLaboratoryStaff();
    return () => { active = false; };
  }, [entry.sampleId]);

  const samplerFullName = useMemo(() =>
    laboratoryStaff.find((person) => person.id === entry.samplerStaffId)?.full_name || entry.sampler,
  [entry.sampler, entry.samplerStaffId, laboratoryStaff]);
  const responsiblePeople = useMemo(() => {
    const people = new Map<string, ResponsiblePerson>();
    const addPerson = (reference: string, id?: string | null) => {
      // Unlinked historical text can be ambiguous; display it without guessing.
      const staffMember = id ? laboratoryStaff.find((person) => person.id === id) : undefined;
      const fullName = staffMember?.full_name || reference;
      const initials = staffMember?.initials || reference;
      const key = staffMember?.id || `legacy-${reference}`;
      if (!reference && !staffMember || people.has(key)) return;
      people.set(key, { key, fullName, initials, positionTitle: staffMember?.position_title || "Sin puesto registrado" });
    };
    if (laboratorySampled) addPerson(entry.sampler, entry.samplerStaffId);
    rows.forEach((row) => addPerson(row.analyst_name || "", row.analyst_staff_id));
    return [...people.values()];
  }, [rows, entry.sampler, entry.samplerStaffId, laboratorySampled, laboratoryStaff]);
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
    if (!page || !firstFixed || !measurement || !continuationFixed) return;
    const paginate = () => {
      const style = window.getComputedStyle(page);
      const pageHeight = 279 * 96 / 25.4;
      const innerHeight = pageHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
      const headerHeight = measurement.querySelector("thead")?.getBoundingClientRect().height || 30;
      const measuredRows = Array.from(measurement.querySelectorAll("tbody tr"));
      const firstBudget = Math.max(80, innerHeight - firstFixed.getBoundingClientRect().height - headerHeight);
      const continuationBudget = Math.max(80, innerHeight - continuationFixed.getBoundingClientRect().height - headerHeight);
      const pages: PreviewRow[][] = [[]];
      let pageIndex = 0;
      let used = 0;
      mainRows.forEach((row, index) => {
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
      setResultPages((current) => current.length === pages.length && current.every((group, index) =>
        group.length === pages[index].length && group.every((row, rowIndex) => row === pages[index][rowIndex])) ? current : pages);
    };
    const frame = window.requestAnimationFrame(paginate);
    const observer = new ResizeObserver(paginate);
    observer.observe(firstFixed);
    observer.observe(measurement);
    observer.observe(continuationFixed);
    return () => { window.cancelAnimationFrame(frame); observer.disconnect(); };
  }, [mainRows, loading, staffLoading]);

  function normalizedSubsampleResults() {
    return {
      ...subsampleResults,
      ...Object.fromEntries(columns.map((column) => [column.key,
        Array.from({ length: subsampleCount }, (_, index) => subsampleValue(column, subsampleResults, index))])),
    };
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
      subsample_count: columns.length ? subsampleCount : null,
      subsample_results: normalizedSubsampleResults(),
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
    if (columns.some((column) => Array.from({ length: subsampleCount }, (_, index) =>
      subsampleValue(column, subsampleResults, index)).some((value) => !value.trim()))) {
      setMessage("Completa todos los resultados de las muestras simples antes de continuar.");
      return;
    }
    if (!(await saveDraft(false))) return;
    onSampledAtChange(laboratorySampled ? draftSampledAt : "");
    onContinue();
  }

  function setSubsampleValue(column: SubsampleColumn, index: number, value: string) {
    setSubsampleResults((current) => ({
      ...current,
      [column.key]: Array.from({ length: subsampleCount }, (_, position) =>
        position === index ? value : subsampleValue(column, current, position)),
    }));
  }

  const sampleDetails = <table className="sheet-sample-info-table">
    <thead><tr><th>Información de la muestra</th><th>Observaciones</th></tr></thead>
    <tbody><tr>
      <td>{readOnly ? <p className="sheet-sample-description">{sampleInformation || "—"}</p> : <textarea className="sheet-sample-info-input" aria-label="Información de la muestra" value={sampleInformation} onChange={(event) => setSampleInformation(event.target.value)} placeholder="Captura la información de la muestra." />}</td>
      <td className="sheet-observation-cell">
        <p>{FIXED_OBSERVATION}.</p>
        <p><b>Norma de muestreo:</b> {laboratorySampled ? "NMX-AA-003-1980" : "No aplica"}</p>
        <label><b>Fecha de muestreo:</b> {laboratorySampled ? readOnly
          ? <span>{draftSampledAt ? numericDate(new Date(`${draftSampledAt}T12:00:00`)) : "—"}</span>
          : <input type="date" value={draftSampledAt} onChange={(event) => setDraftSampledAt(event.target.value)} />
          : <span>No aplica</span>}</label>
        <p><b>Responsable del muestreo:</b> {laboratorySampled ? samplerFullName : "El cliente"}</p>
      </td>
    </tr></tbody>
  </table>;

  if (loading || staffLoading) return <div className="report-preview-backdrop"><div className="report-preview-loading">Preparando pre-informe…</div></div>;

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
        <section className="sheet-page" ref={firstPageRef}>
          <div className="sheet-fixed" ref={firstPageFixedRef}>
          <ReportHeader />
          <div className="sheet-title">INFORME DE RESULTADOS</div>
          <div className="sheet-client-block">
            <div className="sheet-client-row sheet-client-name"><b>Cliente:</b><span>{entry.client}{entry.clientBranch ? ` · ${entry.clientBranch}` : ""}</span></div>
            <div className="sheet-client-row sheet-client-address"><b>Dirección:</b><span>{entry.clientAddress || "—"}</span></div>
            <div className="sheet-client-row"><b>RFC:</b><span>{entry.clientRfc || "—"}</span></div>
            <div className="sheet-client-row"><b>Atención:</b><span>{entry.clientContact || "—"}</span></div>
          </div>
          <div className="sheet-metadata-stack">
            <div className="sheet-metadata-box"><ReportNumber number={entry.reportNumber} /><div><b>Fecha de informe:</b> {reportDate(entry.issuedAt ? new Date(`${entry.issuedAt.slice(0, 10)}T12:00:00`) : new Date())}</div><div><b>Fecha recepción de muestra:</b> {entry.received}</div></div>
            <div className="sheet-metadata-box sheet-references"><strong>Referencias</strong><div><b>OP:</b> {entry.op}</div><div><b>No. Control Interno:</b> {entry.sampleNumber}</div><div><b>Cotización:</b> {entry.quotation && entry.quotation !== "—" ? entry.quotation : "N/A"}</div><div><b>Muestreo:</b> {entry.samplingNumber && entry.samplingNumber !== "—" ? entry.samplingNumber : "N/A"}</div></div>
          </div>
          <div className="sheet-sample-fields"><label><b>Identificación de la muestra:</b>{readOnly ? <span>{sampleIdentification || "—"}</span> : <input value={sampleIdentification} onChange={(event) => setSampleIdentification(event.target.value)} placeholder="Captura manual" />}</label><label><b>Solicita:</b>{readOnly ? <span>{requestedBy || "—"}</span> : <input value={requestedBy} onChange={(event) => setRequestedBy(event.target.value)} placeholder="Nombre de quien solicita" />}</label></div>
          </div>
          <ResultsTable laboratoryStaff={laboratoryStaff} rows={firstPageRows} />
          <ReportFooter page={1} totalPages={totalPages} />
        </section>

        {continuationPages.map((pageRows, index) => {
          const pageNumber = index + 2;
          return <section className="sheet-page sheet-results-continuation" key={`results-${pageNumber}`}>
            <ResultsContinuationHeader reportNumber={entry.reportNumber} />
            <ResultsTable laboratoryStaff={laboratoryStaff} rows={pageRows} />
            <ReportFooter page={pageNumber} totalPages={totalPages} />
          </section>;
        })}

        <section className="sheet-page sheet-information-page">
          <ReportHeader reportNumber={entry.reportNumber} />
          {sampleDetails}
          {columns.length > 0 && <table className="sheet-table sheet-subsample-table"><thead><tr><th>Muestra simple</th>{columns.map((column) => <th key={column.key}>{column.label} {column.unit || ""}</th>)}</tr></thead><tbody>
              {Array.from({ length: subsampleCount }, (_, index) => <tr key={index}><td>{entry.sampleNumber}-{index + 1}</td>{columns.map((column) => {
                const value = subsampleValue(column, subsampleResults, index);
                return <td key={column.key}>{readOnly || column.measurements.has(index + 1) ? value || "—" : <input aria-label={`${column.label}, submuestra ${index + 1}`} value={value} onChange={(event) => setSubsampleValue(column, index, event.target.value)} placeholder="Resultado" />}</td>;
              })}</tr>)}
            </tbody></table>}
          <h3 className="sheet-responsible-heading">Personal responsable</h3>
          <table className="sheet-table sheet-responsible-table"><thead><tr><th>Nombre</th><th>Cargo</th><th>Iniciales</th><th>Firma</th></tr></thead><tbody>
            {responsiblePeople.length === 0 ? <tr><td colSpan={4}>Sin personal responsable registrado.</td></tr> : responsiblePeople.map((person) => <tr key={person.key}><td>{person.fullName}</td><td>{person.positionTitle}</td><td>{person.initials}</td><td className="report-signature-cell" aria-label={`Espacio de firma para ${person.fullName}`} /></tr>)}
          </tbody></table>
          <ReportFooter page={informationPage} totalPages={totalPages} />
        </section>

        <section className="sheet-page sheet-approval-page">
          <ReportHeader reportNumber={entry.reportNumber} />
          <div className="sheet-approval">
            <b>Revisó:</b>
            <div className="sheet-signature-line" />
            <strong>
              <span>I.B.Q. José Guadalupe Rentería Tobar</span>
              <span>Gerente de operaciones.</span>
              <span>Representante autorizado ante la EMA A.C.</span>
              <span>Representante autorizado ante la CONAGUA</span>
            </strong>
            <ReportMark />
          </div>
          <div className="sheet-declarations">
            <p className="sheet-accreditation-statement">Acreditación No. <b>AG-0768-081/16</b> con vigencia a partir de 20 de octubre del 2016 otorgada bajo la norma NMX-EC-17025-IMNC-2018 (ISO/IEC 17025:2017) Ante la EMA. Requisitos generales para la competencia de laboratorio de ensayo y de calibración aprobado por la <b>CONAGUA</b> con vigencia hasta el 19 de agosto del 2026.</p>
            <h3>Declaraciones</h3>
            <p>Las actividades de ensayo en el presente informe se llevaron a cabo en las instalaciones permanentes de Gissamex, S.A. de C.V., ubicado en San Armando, No. 553, Col. San Humberto, en Santa Catarina, Nuevo León, México. CP. 66120.</p>
            <p>Las actividades de campo (muestreo, pH, CE, T° y MF, cuando apliquen) fueron realizadas en las instalaciones del cliente.</p>
            <p>Al presente informe se le anexa: Cadena de custodia, plan de muestreo y registros de campo; En caso de que la muestra sea proporcionada por el cliente, únicamente se anexará la cadena de custodia correspondiente a la muestra ensayada.</p>
            <p>Las condiciones ambientales, ubicación del punto de muestreo y croquis del punto de muestreo se encuentran disponibles en los registros de campo que se adjuntan al informe.</p>
            <p>Prohibida la reproducción parcial y/o total de este informe sin autorización previa de GISSAMEX S.A. DE C.V.</p>
          </div>
          <div className="sheet-end">Fin del informe.</div>
          <ReportFooter page={approvalPage} totalPages={totalPages} />
        </section>
      </main>
      <div className="sheet-pagination-measure" aria-hidden="true">
        <div className="sheet-fixed" ref={continuationFixedRef}><ResultsContinuationHeader reportNumber={entry.reportNumber} /></div>
        <div ref={rowMeasurementRef}><ResultsTable laboratoryStaff={laboratoryStaff} rows={mainRows} /></div>
      </div>
    </div>
  </div>;
}

function ResultParameterLabel({ label }: { label: string }) {
  const weightedAverage = /^(Grasas y aceites)\s+(\(promedio ponderado\))$/i.exec(label.trim());
  if (!weightedAverage) return label;

  return <span className="sheet-weighted-average-label">{weightedAverage[1]} <span>{weightedAverage[2]}</span></span>;
}

function ResultsTable({ rows, laboratoryStaff }: { rows: PreviewRow[]; laboratoryStaff: LaboratoryStaff[] }) {
  return <table className="sheet-table sheet-results-table"><thead><tr><th>Parámetro</th><th>Resultado</th><th>Unidades</th><th>Método</th><th>Analista</th><th>Fecha<br />análisis</th></tr></thead><tbody>
    {rows.map((row) => <tr key={row.id}><td><ResultParameterLabel label={reportParameterName(row)} /></td><td>{row.result_value || "—"}</td><td>{row.unit || "—"}</td><td>{row.method_reference || "—"}</td><td>{laboratoryStaff.find((person) => person.id === row.analyst_staff_id)?.initials || row.analyst_name || "—"}</td><td>{row.result_date ? numericDate(new Date(`${row.result_date}T12:00:00`)) : "—"}</td></tr>)}
  </tbody></table>;
}

function ReportMark() {
  return <Image className="sheet-mark" src="/gissamex-mark.png" width={256} height={252} alt="" unoptimized />;
}

function ReportNumber({ number }: { number: string }) {
  return <div className="sheet-header-number"><b>Número de informe:</b> <strong>{number || "BORRADOR"}</strong></div>;
}

function ResultsContinuationHeader({ reportNumber }: { reportNumber: string }) {
  return <><ReportHeader reportNumber={reportNumber} />
    <h3 className="sheet-results-continuation-title">Resultados de análisis — continuación</h3></>;
}

function ReportHeader({ reportNumber }: { reportNumber?: string }) {
  return <header className="sheet-document-header">
    <div className="sheet-accreditation"><b>Acreditación EMA No: AG-0768-081/16</b><br /><b>Aprobación CONAGUA No: CNA-GCA-2870</b></div>
    <div className="sheet-contact">
      <svg className="sheet-contact-curve" viewBox="0 0 320 116" preserveAspectRatio="none" aria-hidden="true">
        <path d="M0 0H320V98C226 138 84 111 0 0Z" fill="currentColor" />
      </svg>
      <div className="sheet-contact-lines">
        <span><i aria-hidden="true">☎</i>2235.5347 · 2235.5310</span>
        <span><i aria-hidden="true">✉</i>info@gissamx.com</span>
        <span><i aria-hidden="true">◎</i>www.gissamx.com</span>
      </div>
    </div>
    <div className="sheet-brand"><ReportMark /><strong>GISSAMEX S.A. DE C.V.</strong><span>Manejo Integral del Agua</span></div>
    {reportNumber !== undefined && <ReportNumber number={reportNumber} />}
  </header>;
}

function ReportFooter({ page, totalPages }: { page: number; totalPages: number }) {
  return <footer className="sheet-document-footer">
    <svg className="sheet-footer-curve" viewBox="0 0 270 74" preserveAspectRatio="none" aria-hidden="true">
      <path d="M0 5Q58 -3 111 8Q52 26 0 66Z" fill="#9dcc78" />
      <path d="M2 74Q70 24 132 13Q220 30 270 74Z" fill="#459f54" />
    </svg>
    <span className="sheet-footer-address">
      <svg width="13" height="15" viewBox="0 0 13 15" aria-hidden="true"><path fill="currentColor" d="M6.5 0a6 6 0 0 0-6 6c0 3.5 6 9 6 9s6-5.5 6-9a6 6 0 0 0-6-6Zm0 3.5A2.5 2.5 0 1 1 6.5 8.5a2.5 2.5 0 0 1 0-5Z"/></svg>
      San Armando No. 553 Col. San Humberto. CP 66120. Santa Catarina, N.L. México
    </span>
    <div className="sheet-footer-page"><span>Página {page} de {totalPages}</span><span>F1INF-02</span></div>
  </footer>;
}
