const families = [
  { key: "fats-and-oils", label: "Grasas y aceites", pattern: /^(?:gya|g y a|grasas y aceites)(?: ([1-6]|ponderad[oa]|media ponderada|promedio ponderado))?$/ },
  { key: "fecal-coliforms", label: "Coliformes fecales", pattern: /^(?:col fec|coliformes fecales)(?: ([1-6]|mg|media geometrica))?$/ },
  { key: "e-coli", label: "E. coli", pattern: /^(?:e coli|ecoli|escherichia coli)(?: ([1-6]|mg|media geometrica))?$/ },
  { key: "total-coliforms", label: "Coliformes totales", pattern: /^(?:col tot|coliformes totales)(?: ([1-6]|mg|media geometrica))?$/ },
  { key: "enterococci", label: "Enterococos", pattern: /^(?:enterococos|enterococcos)(?: ([1-6]|mg|media geometrica))?$/ },
] as const;

type Result = { id: string; label: string; unit: string | null; result_value: string | null };
export type SubsampleResults = Record<string, string[]>;
export type SubsampleColumn = {
  key: string;
  label: string;
  unit: string | null;
  measurements: Map<number, Result>;
  legacyRowId?: string;
};

export function buildSubsampleLayout<T extends Result>(rows: readonly T[]) {
  const columns: SubsampleColumn[] = [];
  const separatedRows = new Set<string>();
  let requiresSix = false;
  const normalized = rows.map((row) => ({
    row,
    name: row.label.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(),
  }));
  const isComposite = normalized.some(({ name }) =>
    families.some(({ key, pattern }) => {
      const suffix = pattern.exec(name)?.[1];
      return suffix !== undefined && suffix !== "1" && (key !== "enterococci" || /^[2-6]$/.test(suffix));
    }));

  for (const family of families) {
    const measurements = new Map<number, Result>();
    let summary: T | undefined;
    let base: T | undefined;
    for (const { row, name } of normalized) {
      const match = family.pattern.exec(name);
      if (!match) continue;
      const suffix = match[1];
      if (!suffix) base ??= row;
      else if (/^[1-6]$/.test(suffix)) {
        const position = Number(suffix);
        if (!measurements.has(position)) measurements.set(position, row);
        if (position > 4) requiresSix = true;
      } else summary ??= row;
    }
    if (family.key === "enterococci") {
      // The catalog can label the geometric mean simply "Enterococcos".
      // Without numbered readings, leave it in the main table only.
      if (!measurements.size) continue;
      summary ??= base;
    }
    const first = [...measurements.entries()].sort(([a], [b]) => a - b)[0]?.[1];
    const reference = first || summary || base;
    if (!reference) continue;
    // A lone "(1)" in an instantaneous package is its only reported
    // measurement; don't require a four-row breakdown that doesn't exist.
    if (!isComposite && !summary && !base) continue;
    // When the worksheet has a reported summary, the individual readings
    // belong only in the simple-sample table, not next to the summary.
    if (summary) measurements.forEach((row) => separatedRows.add(row.id));
    columns.push({
      key: "subsample:" + family.key,
      label: family.label,
      unit: reference.unit,
      measurements,
      legacyRowId: (summary || base)?.id,
    });
  }

  return { columns, requiresSix, mainRows: rows.filter((row) => !separatedRows.has(row.id)) };
}

export function subsampleValue(column: SubsampleColumn, draft: SubsampleResults, index: number) {
  const worksheetRow = column.measurements.get(index + 1);
  if (worksheetRow) return worksheetRow.result_value ?? "";
  return draft[column.key]?.[index] ?? (column.legacyRowId ? draft[column.legacyRowId]?.[index] : undefined) ?? "";
}
