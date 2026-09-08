// Nutrition evaluation: repeatability and accuracy are separate, and missing is never zero.
export const nutrientKeys = [
  "kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml", "potassium_mg",
  "magnesium_mg", "iron_mg", "calcium_mg", "fiber_g", "sugar_g", "satfat_g",
] as const;
export type Nutrient = typeof nutrientKeys[number];
export type Answer = {
  status: number;
  reason?: string;
  items?: Record<string, unknown>[];
};
export type Reference = {
  // Weighed ingredients plus cited composition data, or the actual product label. Never an AI answer.
  source: string;
  nutrients?: Partial<Record<Nutrient, number>>;
  reason?: "not_food" | "unreadable";
};
export type Truth = Record<string, Reference>;

export function parseTruth(raw: unknown): Truth {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("truth must be an object keyed by photo filename without extension");
  const result: Truth = {};
  for (const [name, entry] of Object.entries(raw)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Error(`invalid reference: ${name}`);
    const r = entry as Record<string, unknown>;
    if (typeof r.source !== "string" || !r.source.trim()) throw new Error(`reference needs a source: ${name}`);
    if (r.reason !== undefined && r.reason !== "not_food" && r.reason !== "unreadable") throw new Error(`invalid reference reason: ${name}`);
    const nutrients: Partial<Record<Nutrient, number>> = {};
    if (r.nutrients !== undefined) {
      if (!r.nutrients || typeof r.nutrients !== "object" || Array.isArray(r.nutrients)) throw new Error(`invalid nutrients: ${name}`);
      for (const [key, value] of Object.entries(r.nutrients)) {
        if (!nutrientKeys.includes(key as Nutrient) || typeof value !== "number" || !Number.isFinite(value) || value < 0) {
          throw new Error(`invalid reference nutrient ${name}.${key}`);
        }
        nutrients[key as Nutrient] = value;
      }
    }
    if (r.reason ? Object.keys(nutrients).length > 0 : Object.keys(nutrients).length === 0) throw new Error(`reference must have nutrients OR a rejection reason: ${name}`);
    result[name] = { source: r.source, ...(r.reason ? { reason: r.reason } : { nutrients }) } as Reference;
  }
  return result;
}

export function total(items: Record<string, unknown>[], key: Nutrient): number | null {
  if (!items.length) return null;
  let sum = 0;
  for (const item of items) {
    const value = item[key];
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return null;
    sum += value;
  }
  return Number.isFinite(sum) ? sum : null;
}
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

export function summarize(answers: Answer[], reference?: Reference) {
  const successful = answers.filter(a => a.status === 200 && !a.reason && Array.isArray(a.items) && a.items.length > 0);
  const nutrients = Object.fromEntries(nutrientKeys.map(key => {
    const values = successful.map(a => total(a.items!, key)).filter((v): v is number => v !== null);
    const average = values.length ? mean(values) : null;
    const spread = values.length >= 2 ? Math.sqrt(values.reduce((s, x) => s + (x - average!) ** 2, 0) / (values.length - 1)) : null;
    const expected = reference?.nutrients?.[key];
    const mae = expected !== undefined && values.length ? mean(values.map(v => Math.abs(v - expected))) : null;
    return [key, {
      observations: values.length,
      missing: successful.length - values.length,
      mean: average,
      min: values.length ? Math.min(...values) : null,
      max: values.length ? Math.max(...values) : null,
      // Even an all-zero output needs two observations to establish repeatability.
      cvPct: spread === null ? null : average === 0 ? 0 : spread / average! * 100,
      reference: expected ?? null,
      meanAbsoluteError: mae,
      meanAbsolutePercentError: mae !== null && expected! > 0 ? mae / expected! * 100 : null,
    }];
  })) as Record<Nutrient, { observations: number; missing: number; mean: number | null; min: number | null; max: number | null; cvPct: number | null; reference: number | null; meanAbsoluteError: number | null; meanAbsolutePercentError: number | null }>;
  return {
    attempts: answers.length,
    successful: successful.length,
    failedOrRejected: answers.length - successful.length,
    expectedRejectionMatches: reference?.reason ? answers.filter(a => a.status === 200 && a.reason === reference.reason && a.items?.length === 0).length : null,
    referenceSource: reference?.source ?? null,
    nutrients,
  };
}
