export type ResultInputKind = "auto" | "number" | "text";
export type ResultQualifier = "eq" | "lt" | "lte" | "gt" | "gte";
export type ResultValue = { result_value: string | null; result_input_kind?: ResultInputKind };

const trimResult = (value: string) => value.replace(/^[ \t\n\r\f\v]+|[ \t\n\r\f\v]+$/g, "");
const qualifiers: Record<string, ResultQualifier> = { "": "eq", "<": "lt", "<=": "lte", "≤": "lte", ">": "gt", ">=": "gte", "≥": "gte" };
const prefixes: Record<ResultQualifier, string> = { eq: "", lt: "<", lte: "<=", gt: ">", gte: ">=" };

// Keep decimals as strings: converting through Number loses laboratory precision.
// Grammar and limits match the database parser in migration 044.
export function parseNumericResult(raw: string | null) {
  const value = trimResult(raw || "");
  if (value.length > 128) return null;
  const match = /^(<=|>=|<|>|≤|≥)?[ \t\n\r\f\v]*([+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))$/.exec(value);
  if (!match || match[2].replace(/[^0-9]/g, "").length > 100) return null;
  return { qualifier: qualifiers[match[1] || ""], value: match[2] };
}

// Split incomplete edits too, so choosing '<' before typing a number works.
export function numericEditorParts(raw: string | null) {
  const value = raw || "";
  const match = /^[ \t\n\r\f\v]*(<=|>=|<|>|≤|≥)[ \t\n\r\f\v]*([\s\S]*)$/.exec(value);
  return match ? { qualifier: qualifiers[match[1]], value: match[2] } : { qualifier: "eq" as ResultQualifier, value };
}

export function numericResultValue(value: string, qualifier: ResultQualifier) {
  return `${prefixes[qualifier]}${value}`;
}

export function resultValidationError(result: ResultValue) {
  if (result.result_input_kind !== "number" || !trimResult(result.result_value || "") || parseNumericResult(result.result_value)) return null;
  return "Escribe un decimal con punto, sin comas ni exponentes (máximo 100 dígitos).";
}

export function resultWriteFields(result: ResultValue, structured: boolean) {
  // Do not normalize historical reported text when saving another worksheet field.
  return { result_value: result.result_value, ...(structured ? { result_input_kind: result.result_input_kind || "auto" } : {}) };
}
