const families = [
  { key: "e-coli", pattern: /^(?:e coli|ecoli)(?: \d+| mg| media geometrica)?$/ },
  { key: "fecal-coliforms", pattern: /^(?:col fec|coliformes fecales)(?: \d+| mg| media geometrica)?$/ },
  { key: "fats-and-oils", pattern: /^(?:gya|g y a|grasas y aceites)(?: \d+| ponderad[oa]| media ponderada| promedio ponderado)?$/ },
] as const;

/** Count analytes, not the replicate or summary rows for a single analyte. */
export function countPackageParameters(names: readonly (string | null | undefined)[]): number {
  const grouped = new Set<string>();
  let individual = 0;
  for (const name of names) {
    const normalized = (name ?? "").normalize("NFD").replace(/\p{M}/gu, "")
      .toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    const family = families.find(({ pattern }) => pattern.test(normalized));
    if (family) grouped.add(family.key);
    else individual += 1;
  }
  return individual + grouped.size;
}
