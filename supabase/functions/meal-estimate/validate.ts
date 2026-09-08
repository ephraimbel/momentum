// meal-estimate: request and response validation (2026-09-07).
//
// Validators and a bounded request reader, tested without providers. The model's
// answer is never trusted as application data: every item is re-checked, counts and numbers are
// bounded, unknown micros stay null (never zero), and a photo that shows no food comes back as a
// reason, never as a confident-looking meal.
//
// Estimated energy is checked against macro energy with room for fibre; estimated grams and
// kcal are rounded consistently. Supplied label values are preserved. These checks improve
// internal consistency, but cannot establish that a photographed portion was estimated correctly.

export const MAX_TEXT_CHARS = 500;
export const MAX_ITEMS = 40;
export const MAX_NUMBER = 1_000_000;
export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
export const IMAGE_MIME_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

export class BodyTooLarge extends Error {}

/** Enforce the byte ceiling for chunked requests too; Content-Length is only a hint. */
export async function readBoundedJSON(req: Request, maxBytes: number): Promise<unknown> {
  if (!req.body) throw new SyntaxError("missing_body");
  const reader = req.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let text = "";
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > maxBytes) {
        await reader.cancel();
        throw new BodyTooLarge("body_size");
      }
      text += decoder.decode(chunk.value, { stream: true });
    }
    text += decoder.decode();
    return JSON.parse(text);
  } finally {
    reader.releaseLock();
  }
}

export type ImageInput = { mime: string; base64: string };

export type RequestShape = {
  text: string;
  image: ImageInput | null;
  context: { session?: string; durationS?: number };
};

export type RequestError = "empty" | "image_type" | "image_size" | "image_encoding" | "bad_request";

/** Decoded byte length of a base64 string without decoding it. */
export function base64DecodedLength(b64: string): number {
  const trimmed = b64.replace(/\s+/g, "");
  if (trimmed.length === 0) return 0;
  const padding = trimmed.endsWith("==") ? 2 : trimmed.endsWith("=") ? 1 : 0;
  return Math.floor((trimmed.length * 3) / 4) - padding;
}

/**
 * The image type from the bytes themselves, never from the declared field: JPEG (FF D8 FF),
 * PNG (89 50 4E 47 0D 0A 1A 0A) or WEBP (RIFF....WEBP). Decodes only the first 16 bytes.
 */
export function sniffImageMime(base64: string): string | null {
  const head = base64.replace(/\s+/g, "").slice(0, 24);
  if (head.length < 16) return null;
  let bytes: Uint8Array;
  try {
    const bin = atob(head.slice(0, 16));
    bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
    && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) return "image/png";
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46
    && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return "image/webp";
  return null;
}

/**
 * Shape and bound the request. Text is optional when a photo is present; a photo must be one of
 * three types (by its bytes, not its label) and under the byte ceiling BEFORE anything is decoded
 * or forwarded.
 */
export function parseRequest(payload: unknown): { ok: true; value: RequestShape } | { ok: false; error: RequestError } {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return { ok: false, error: "bad_request" };
  const p = payload as Record<string, unknown>;
  if (p.text !== undefined && p.text !== null && typeof p.text !== "string") return { ok: false, error: "bad_request" };
  const text = (typeof p.text === "string" ? p.text : "").slice(0, MAX_TEXT_CHARS).trim();
  const rawContext = (p.context && typeof p.context === "object" ? p.context : {}) as Record<string, unknown>;
  const context: RequestShape["context"] = {};
  if (typeof rawContext.session === "string") context.session = rawContext.session.slice(0, 200);
  if (typeof rawContext.durationS === "number" && Number.isFinite(rawContext.durationS)) {
    context.durationS = Math.max(0, Math.min(86_400, rawContext.durationS));
  }

  let image: ImageInput | null = null;
  if (p.image !== null && p.image !== undefined) {
    const raw = (typeof p.image === "object" ? p.image : {}) as Record<string, unknown>;
    const declared = String(raw.mime ?? "").toLowerCase();
    const base64 = typeof raw.base64 === "string" ? raw.base64.replace(/\s+/g, "") : "";
    if (!IMAGE_MIME_TYPES.has(declared)) return { ok: false, error: "image_type" };
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64) || base64.length % 4 !== 0) return { ok: false, error: "image_encoding" };
    const bytes = base64DecodedLength(base64);
    if (bytes === 0 || bytes > MAX_IMAGE_BYTES) return { ok: false, error: "image_size" };
    const sniffed = sniffImageMime(base64);
    if (!sniffed) return { ok: false, error: "image_type" };
    image = { mime: sniffed, base64 };
  }

  if (!text && !image) return { ok: false, error: "empty" };
  return { ok: true, value: { text, image, context } };
}

// MARK: - Response

export type Item = {
  name: string;
  /** A legible label is not recalculated from rounded macros. Missing on older providers. */
  nutrition_basis?: "estimated" | "label";
  qty: number;
  unit: string;
  /** The portion's weight as served (ml for a drink); the estimate's visible portion basis. */
  grams: number | null;
  kcal: number;
  carbs_g: number;
  protein_g: number;
  fat_g: number;
  /** Ethanol grams: the one energy source outside the macro three. null reads as none. */
  alcohol_g: number | null;
  sodium_mg: number;
  fluids_ml: number;
  potassium_mg: number | null;
  magnesium_mg: number | null;
  iron_mg: number | null;
  calcium_mg: number | null;
  fiber_g: number | null;
  sugar_g: number | null;
  satfat_g: number | null;
  nova: number | null;
};

export type Estimate = {
  items: Item[];
  confidence: number;
  tags: string[];
  note: string;
  /** "" when the input was food; "not_food" | "unreadable" when the model saw nothing to estimate. */
  reason: string;
};

export type ValidationFailure = "shape" | "items" | "item" | "confidence";

/** What the validator changed on the way through, for the log line (counts, never values). */
export type ValidationStats = { reconciled: number };

const REQUIRED_NUMBERS = ["kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml"] as const;
const OPTIONAL_NUMBERS = [
  "grams", "alcohol_g", "potassium_mg", "magnesium_mg", "iron_mg", "calcium_mg", "fiber_g", "sugar_g", "satfat_g",
] as const;
const REASONS = new Set(["", "not_food", "unreadable"]);
const TAGS = new Set(["carb-dense", "protein", "electrolytes", "light", "pre-session", "recovery"]);

/**
 * How far an item's kcal may sit from the energy its own macros carry before it is rewritten.
 * This is an internal plausibility check for estimated values, not a measurement of accuracy.
 * Labels bypass reconciliation; fibre widens the estimated energy range below.
 */
export const KCAL_TOLERANCE = 0.25;
/** Below this the identity is dominated by rounding, so a tiny item is left alone. */
const KCAL_RECONCILE_FLOOR = 40;

/** Energy from the macros alone, Atwater general factors with ethanol. */
export function macroEnergy(it: Pick<Item, "carbs_g" | "protein_g" | "fat_g" | "alcohol_g">): number {
  return 4 * it.carbs_g + 4 * it.protein_g + 9 * it.fat_g + 7 * (it.alcohol_g ?? 0);
}

/**
 * Rewrite an item's kcal to its macro energy when the two disagree beyond `KCAL_TOLERANCE`.
 * Returns true when it did. Pure, so the band is pinned by tests.
 */
export function reconcileEnergy(it: Item): boolean {
  if (it.nutrition_basis === "label") return false;
  const energy = macroEnergy(it);
  if (energy < KCAL_RECONCILE_FLOOR) return false;
  // Total carbohydrate can include fibre that contributes less energy. A general 4/4/9
  // calculation is a plausibility range, not ground truth (USDA also uses specific factors).
  const lowerEnergy = Math.max(0, energy - 4 * (it.fiber_g ?? 0));
  if (it.kcal >= lowerEnergy * (1 - KCAL_TOLERANCE)
    && it.kcal <= energy * (1 + KCAL_TOLERANCE)) return false;
  it.kcal = Math.round(energy);
  return true;
}

/** kcal to the nearest 5 once past the small-snack range: jitter of a few kcal is noise, not news. */
export function snapKcal(kcal: number): number {
  return kcal >= 50 ? Math.round(kcal / 5) * 5 : Math.round(kcal);
}

/** Grams to the nearest 5 up to 100 g, the nearest 10 above: the steps a hand would use. */
export function snapGrams(grams: number): number {
  return grams > 100 ? Math.round(grams / 10) * 10 : Math.round(grams / 5) * 5;
}

function boundedNumber(value: unknown, integer: boolean): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  if (value < 0 || value > MAX_NUMBER) return undefined;
  return integer ? Math.round(value) : value;
}

/** null (or absent) means unknown and stays unknown; a number is bounded; anything else fails. */
function optionalNumber(value: unknown, integer: boolean): number | null | undefined {
  if (value === null || value === undefined) return null;
  return boundedNumber(value, integer);
}

/**
 * Turn whatever the provider returned into an `Estimate` or refuse it. Refusal is total: a single
 * malformed item rejects the response, because a negative total or an overflow must never reach
 * the journal. `not_food` answers are honoured with an empty item list and a confidence of 0.
 */
export function validateEstimate(
  raw: unknown,
  options: { hasImage?: boolean } = {},
): { ok: true; value: Estimate; stats: ValidationStats } | { ok: false; error: ValidationFailure } {
  if (!raw || typeof raw !== "object") return { ok: false, error: "shape" };
  const r = raw as Record<string, unknown>;
  const reasonRaw = typeof r.reason === "string" ? r.reason.trim().toLowerCase() : "";
  // A reason only means something for a photo: text is never "not food" (a nonsense sentence is
  // simply declined). An unfamiliar non-empty reason on a photo reads as "unreadable".
  const reason = !options.hasImage ? "" : REASONS.has(reasonRaw) ? reasonRaw : reasonRaw ? "unreadable" : "";
  const itemsRaw = Array.isArray(r.items) ? r.items : [];
  const stats: ValidationStats = { reconciled: 0 };

  if (reason) {
    return {
      ok: true,
      value: { items: [], confidence: 0, tags: [], note: typeof r.note === "string" ? r.note.slice(0, 240) : "", reason },
      stats,
    };
  }
  if (itemsRaw.length === 0 || itemsRaw.length > MAX_ITEMS) return { ok: false, error: "items" };

  const items: Item[] = [];
  for (const entry of itemsRaw) {
    if (!entry || typeof entry !== "object") return { ok: false, error: "item" };
    const e = entry as Record<string, unknown>;
    const name = typeof e.name === "string" ? e.name.trim().replace(/\s+/g, " ").slice(0, 80) : "";
    const unit = typeof e.unit === "string" ? e.unit.trim().replace(/\s+/g, " ").slice(0, 24) : "";
    const qty = typeof e.qty === "number" && Number.isFinite(e.qty) ? e.qty : NaN;
    if (!name || !unit || !(qty >= 0.001 && qty <= 10_000)) return { ok: false, error: "item" };
    if (e.nutrition_basis !== undefined && e.nutrition_basis !== "estimated" && e.nutrition_basis !== "label") {
      return { ok: false, error: "item" };
    }
    const item: Partial<Item> = { name, unit, qty, nutrition_basis: e.nutrition_basis === "label" ? "label" : "estimated" };
    for (const key of REQUIRED_NUMBERS) {
      const v = boundedNumber(e[key], true);
      if (v === undefined) return { ok: false, error: "item" };
      item[key] = v;
    }
    for (const key of OPTIONAL_NUMBERS) {
      const v = optionalNumber(e[key], key !== "iron_mg");
      if (v === undefined) return { ok: false, error: "item" };
      item[key] = v;
    }
    const nova = optionalNumber(e.nova, true);
    if (nova === undefined) return { ok: false, error: "item" };
    item.nova = nova === null ? null : Math.min(4, Math.max(1, nova));
    const it = item as Item;
    // The parts cannot exceed the whole: sugars and fibre live inside the carbohydrate, saturated
    // fat inside the fat. Clamp rather than refuse; the model rounds.
    if (it.sugar_g !== null && it.sugar_g > it.carbs_g) it.sugar_g = it.carbs_g;
    if (it.fiber_g !== null && it.fiber_g > it.carbs_g) it.fiber_g = it.carbs_g;
    if (it.satfat_g !== null && it.satfat_g > it.fat_g) it.satfat_g = it.fat_g;
    // A weight of nothing is unknown, not a weightless food.
    if (it.grams !== null && it.grams === 0) it.grams = null;
    // Unit mistakes (mg supplied as g, or per-100g numbers applied to a tiny portion) can
    // otherwise pass the broad overflow bound and poison a whole day's totals. These are
    // physical consistency checks, not dietary limits. Do not infer grams from drink ml.
    if (it.grams !== null && it.fluids_ml === 0) {
      const allowance = Math.max(3, it.grams * 0.1);
      if (it.carbs_g + it.protein_g + it.fat_g + (it.alcohol_g ?? 0) > it.grams + allowance) {
        return { ok: false, error: "item" };
      }
      const mineralsMg = it.sodium_mg + (it.potassium_mg ?? 0) + (it.magnesium_mg ?? 0)
        + (it.iron_mg ?? 0) + (it.calcium_mg ?? 0);
      if (mineralsMg > (it.grams + allowance) * 1000) return { ok: false, error: "item" };
    }
    // Energy is a function of the macros. A kcal that disagrees with its own carbs, protein, fat
    // and alcohol is rewritten from them; the macros are what the readiness engine reads.
    if (reconcileEnergy(it)) stats.reconciled += 1;
    if (it.nutrition_basis !== "label") {
      it.kcal = snapKcal(it.kcal);
      if (it.grams !== null) it.grams = Math.max(1, snapGrams(it.grams));
    }
    items.push(it);
  }

  // A plate has no reading order, so a photo's items are listed largest first (kcal, then name):
  // the same plate then yields the same list, and the row title leads with what matters. Text
  // keeps the athlete's own order ("2 eggs, toast, coffee" is how they said it).
  if (options.hasImage) items.sort((a, b) => b.kcal - a.kcal || a.name.localeCompare(b.name));

  const confidence = typeof r.confidence === "number" && Number.isFinite(r.confidence) ? r.confidence : NaN;
  if (!(confidence >= 0 && confidence <= 1)) return { ok: false, error: "confidence" };
  const tags = Array.isArray(r.tags)
    ? r.tags.filter((t): t is string => typeof t === "string" && TAGS.has(t)).slice(0, 3)
    : [];
  const note = typeof r.note === "string" ? r.note.slice(0, 240) : "";
  return { ok: true, value: { items, confidence: Math.round(confidence * 100) / 100, tags, note, reason: "" }, stats };
}
