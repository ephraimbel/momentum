// meal-estimate: request and response validation (2026-09-07).
//
// Pure functions, no I/O, so `deno test supabase/functions/meal-estimate` pins them. The model's
// answer is never trusted as application data: every item is re-checked, counts and numbers are
// bounded, unknown micros stay null (never zero), and a photo that shows no food comes back as a
// reason, never as a confident-looking meal.

export const MAX_TEXT_CHARS = 500;
export const MAX_ITEMS = 40;
export const MAX_NUMBER = 1_000_000;
export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
export const IMAGE_MIME_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

export type ImageInput = { mime: string; base64: string };

export type RequestShape = {
  text: string;
  image: ImageInput | null;
  context: { session?: string; durationS?: number };
};

export type RequestError = "empty" | "image_type" | "image_size" | "image_encoding";

/** Decoded byte length of a base64 string without decoding it. */
export function base64DecodedLength(b64: string): number {
  const trimmed = b64.replace(/\s+/g, "");
  if (trimmed.length === 0) return 0;
  const padding = trimmed.endsWith("==") ? 2 : trimmed.endsWith("=") ? 1 : 0;
  return Math.floor((trimmed.length * 3) / 4) - padding;
}

/**
 * Shape and bound the request. Text is optional when a photo is present; a photo must be one of
 * three types and under the byte ceiling BEFORE anything is decoded or forwarded.
 */
export function parseRequest(payload: unknown): { ok: true; value: RequestShape } | { ok: false; error: RequestError } {
  const p = (payload && typeof payload === "object" ? payload : {}) as Record<string, unknown>;
  const text = String(p.text ?? "").slice(0, MAX_TEXT_CHARS).trim();
  const rawContext = (p.context && typeof p.context === "object" ? p.context : {}) as Record<string, unknown>;
  const context: RequestShape["context"] = {};
  if (typeof rawContext.session === "string") context.session = rawContext.session.slice(0, 200);
  if (typeof rawContext.durationS === "number" && Number.isFinite(rawContext.durationS)) {
    context.durationS = Math.max(0, Math.min(86_400, rawContext.durationS));
  }

  let image: ImageInput | null = null;
  if (p.image != null) {
    const raw = (typeof p.image === "object" ? p.image : {}) as Record<string, unknown>;
    const mime = String(raw.mime ?? "").toLowerCase();
    const base64 = typeof raw.base64 === "string" ? raw.base64.replace(/\s+/g, "") : "";
    if (!IMAGE_MIME_TYPES.has(mime)) return { ok: false, error: "image_type" };
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) return { ok: false, error: "image_encoding" };
    const bytes = base64DecodedLength(base64);
    if (bytes === 0 || bytes > MAX_IMAGE_BYTES) return { ok: false, error: "image_size" };
    image = { mime, base64 };
  }

  if (!text && !image) return { ok: false, error: "empty" };
  return { ok: true, value: { text, image, context } };
}

// MARK: - Response

export type Item = {
  name: string;
  qty: number;
  unit: string;
  kcal: number;
  carbs_g: number;
  protein_g: number;
  fat_g: number;
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

const REQUIRED_NUMBERS = ["kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml"] as const;
const OPTIONAL_NUMBERS = ["potassium_mg", "magnesium_mg", "iron_mg", "calcium_mg", "fiber_g", "sugar_g", "satfat_g"] as const;
const REASONS = new Set(["", "not_food", "unreadable"]);
const TAGS = new Set(["carb-dense", "protein", "electrolytes", "light", "pre-session", "recovery"]);

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
export function validateEstimate(raw: unknown): { ok: true; value: Estimate } | { ok: false; error: ValidationFailure } {
  if (!raw || typeof raw !== "object") return { ok: false, error: "shape" };
  const r = raw as Record<string, unknown>;
  const reasonRaw = typeof r.reason === "string" ? r.reason.trim().toLowerCase() : "";
  const reason = REASONS.has(reasonRaw) ? reasonRaw : "";
  const itemsRaw = Array.isArray(r.items) ? r.items : [];

  if (reason) {
    return {
      ok: true,
      value: { items: [], confidence: 0, tags: [], note: typeof r.note === "string" ? r.note.slice(0, 240) : "", reason },
    };
  }
  if (itemsRaw.length === 0 || itemsRaw.length > MAX_ITEMS) return { ok: false, error: "items" };

  const items: Item[] = [];
  for (const entry of itemsRaw) {
    if (!entry || typeof entry !== "object") return { ok: false, error: "item" };
    const e = entry as Record<string, unknown>;
    const name = typeof e.name === "string" ? e.name.trim().slice(0, 80) : "";
    const unit = typeof e.unit === "string" ? e.unit.trim().slice(0, 24) : "";
    const qty = typeof e.qty === "number" && Number.isFinite(e.qty) ? e.qty : NaN;
    if (!name || !unit || !(qty >= 0.001 && qty <= 10_000)) return { ok: false, error: "item" };
    const item: Partial<Item> = { name, unit, qty };
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
    items.push(item as Item);
  }

  const confidence = typeof r.confidence === "number" && Number.isFinite(r.confidence) ? r.confidence : NaN;
  if (!(confidence >= 0 && confidence <= 1)) return { ok: false, error: "confidence" };
  const tags = Array.isArray(r.tags)
    ? r.tags.filter((t): t is string => typeof t === "string" && TAGS.has(t)).slice(0, 3)
    : [];
  const note = typeof r.note === "string" ? r.note.slice(0, 240) : "";
  return { ok: true, value: { items, confidence, tags, note, reason: "" } };
}
