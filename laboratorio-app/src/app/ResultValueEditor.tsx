import { useId } from "react";
import { numericResultValue, numericEditorParts, resultValidationError, type ResultInputKind, type ResultQualifier, type ResultValue } from "@/lib/result-values";

type Props = {
  result: ResultValue;
  label: string;
  structured: boolean;
  disabled: boolean;
  onChange: (patch: ResultValue) => void;
};

export function ResultValueEditor({ result, label, structured, disabled, onChange }: Props) {
  const errorId = useId();
  const kind = result.result_input_kind || "auto";
  const numeric = numericEditorParts(result.result_value);
  const error = resultValidationError(result);
  return <div className="result-value-editor">
    {structured && <select aria-label={`Tipo de resultado: ${label}`} value={kind} disabled={disabled}
      onChange={(event) => onChange({ ...result, result_input_kind: event.target.value as ResultInputKind })}>
      <option value="auto">Automático</option><option value="number">Número</option><option value="text">Texto</option>
    </select>}
    <div className="result-value-inputs">
      {structured && kind === "number" && <select aria-label={`Comparación: ${label}`} value={numeric?.qualifier || "eq"} disabled={disabled}
        onChange={(event) => onChange({ ...result, result_value: numericResultValue(numeric?.value ?? result.result_value ?? "", event.target.value as ResultQualifier) })}>
        <option value="eq">=</option><option value="lt">&lt;</option><option value="lte">≤</option><option value="gt">&gt;</option><option value="gte">≥</option>
      </select>}
      <input aria-label={`Resultado: ${label}`} value={structured && kind === "number" ? numeric?.value ?? result.result_value ?? "" : result.result_value ?? ""}
        inputMode={kind === "number" ? "decimal" : "text"} disabled={disabled} aria-invalid={Boolean(error)} aria-describedby={error ? errorId : undefined}
        onChange={(event) => onChange({ ...result, result_value: structured && kind === "number" ? numericResultValue(event.target.value, numeric?.qualifier || "eq") : event.target.value })}
        placeholder={kind === "number" ? "0.05" : kind === "text" ? "No detectado" : "Resultado"}/>
    </div>
    {error && <small id={errorId} role="alert" className="result-value-error">{error}</small>}
  </div>;
}
