// Supabase Edge Function: meal-estimate (FUEL pillar, 2026-07-16; photos 2026-09-07)
//
// Given one meal — the athlete's own sentence, a photo of the plate, or both, plus light training
// context — returns approximate nutrition as STRICT JSON. The iOS app treats every number as an
// estimate ("≈" everywhere), lets the athlete override by hand, and logs meals fine offline with
// the estimate pending — this function is never allowed to block a log.
//
// Photos (docs/PLAN-AND-FUEL-UPGRADE.md §3.4): the app sends a downsampled, metadata-free JPEG
// inline in the request body. Nothing is stored here; the bytes go to the provider as a vision
// part and are gone when the response is written. A photo that shows no food comes back as
// `reason: "not_food"` with no items, never as a confident-looking meal. Text-only requests are
// unchanged and remain the common case (the app's local ladder answers most meals for free).
//
// Every answer is VALIDATED before it leaves (`validate.ts`): bounded item count and numbers,
// unknown micros kept as null, strings trimmed. The provider's structured-output mode is a hint;
// the validator is the contract. Logs carry counts and the provider only — never the athlete's
// words or image bytes.
//
// Fueling, not dieting: the numbers exist to answer "fueled for the work?", so the note speaks
// to training readiness. Never diet, weight, or medical language.
//
// Provider: **Gemini Flash primary** (user decision 2026-07-16), with **Claude Haiku as automatic
// fallback** when GEMINI_API_KEY is unset or the Gemini call fails. Both accept the photo.
//
// Deploy:  supabase functions deploy meal-estimate
// Secrets: GEMINI_API_KEY (primary; user-set), ANTHROPIC_API_KEY (fallback, already set)
//          MEAL_MODEL (default gemini-flash-latest), MEAL_FALLBACK_MODEL (default claude-haiku-4-5-20251001)
// Tests:   deno test supabase/functions/meal-estimate

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";
import { createClient } from "npm:@supabase/supabase-js@2";
import { type Estimate, type ImageInput, parseRequest, validateEstimate } from "./validate.ts";

const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const GEMINI_MODEL = Deno.env.get("MEAL_MODEL") ?? "gemini-flash-latest";   // rolling alias — 2.5-flash is sunset for new keys
const FALLBACK_MODEL = Deno.env.get("MEAL_FALLBACK_MODEL") ?? "claude-haiku-4-5-20251001";
// 1800 (was 1600): the 2026-08-15 quality fields (fiber/sugar/satfat/nova) add four short
// numerics per item — headroom so a six-item dinner can't truncate mid-JSON.
const MAX_TOKENS = Number(Deno.env.get("MEAL_MAX_TOKENS") ?? "1800");

// Per-athlete DAILY estimate cap (server-side — a client limit is trivially bypassed). Generous:
// the heaviest honest day (race-day gels + drinks + meals) sits near 20 estimates; 60 only ever
// stops abuse or a leaked token. LOGGING is never limited — an over-limit meal stays pending with
// manual numbers always available. Enforced by `fuel_rate_check` (migration 20260716000001).
// Photo requests count against the same cap: a vision call costs more, not less.
const DAILY_LIMIT = Number(Deno.env.get("MEAL_DAILY_LIMIT") ?? "60");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// FAIL-OPEN like the coach's limiter: if the RPC is missing or the DB blips, allow the request —
// the cap re-engages the moment the check works again. Keyed on auth.uid() (unspoofable) for
// signed-in athletes; guests fall back to the client IP.
async function withinRateLimit(req: Request): Promise<boolean> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return true;
  try {
    const auth = req.headers.get("authorization") ?? "";
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await supabase.rpc("fuel_rate_check", {
      p_limit: DAILY_LIMIT,
      p_fallback_key: ip,
    });
    if (error) return true;
    const row = Array.isArray(data) ? data[0] : data;
    return row?.allowed !== false;
  } catch (_e) {
    return true;
  }
}

const SYSTEM = `You estimate the nutrition of ONE meal for an endurance athlete's fueling readout. \
You get the athlete's own description ("chicken rice bowl", "2 gels + banana"), a photo of the \
plate, or both, plus light context about their next training session.

Break the meal into ITEMS (the athlete's words or the plate may pack several foods: "2 eggs, toast, \
coffee" is three items). For each item return: name (short, title-case), qty (a number), unit (a \
natural short unit for that food: "egg", "slice", "cup", "bowl", "gel", "serving"), and that item's \
kcal, carbohydrate grams, protein grams, fat grams, sodium milligrams, fluid milliliters (0 unless \
it's a drink), potassium milligrams, magnesium milligrams, iron milligrams (decimals fine), \
calcium milligrams — the endurance micros — plus the food-quality facts: fiber_g (dietary fiber \
grams), sugar_g (TOTAL sugars grams, intrinsic plus added), satfat_g (saturated fat grams), and \
nova (the NOVA processing classification as an integer: 1 unprocessed/minimally processed food, \
2 processed culinary ingredient, 3 processed food, 4 ultra-processed food). NOVA anchors: fresh \
produce, plain meat/fish/eggs, milk, rice, oats are 1; butter, honey, oils, sugar are 2; fresh \
bread, cheese, cured meats (bacon, ham), canned goods, home-fried foods are 3; sodas, candy, \
packaged snacks, ice cream, instant noodles, hot dogs/nuggets, fast food, gels and sports drinks \
are 4. When torn between two classes, pick the HIGHER (more processed). Typical home/restaurant \
portions unless quantities are given. confidence is 0-1 (branded sports nutrition rates higher; \
vague descriptions and photos lower).

UNKNOWN IS NULL. When a micro (potassium, magnesium, iron, calcium, fiber, sugar, saturated fat, \
nova) cannot be judged for an item, return null for it. Never write 0 to mean "I don't know"; \
0 means the food genuinely has none.

NUMBERS MUST AGREE. Per item: kcal within ~15% of 4*carbs_g + 4*protein_g + 9*fat_g (alcohol \
excepted), sugar_g <= carbs_g, fiber_g <= carbs_g, satfat_g <= fat_g. Reconcile before answering.

PORTIONS ARE EXACT. The description is often dictated speech — honor every stated quantity, \
fraction, and size to the letter, and scale ALL numbers by it. "half a bagel" is qty 0.5 with \
half the nutrition of a whole bagel; "half of a large rice krispie treat" is qty 0.5 of the \
LARGE size (scale up for the size first, then halve); "a quarter of" is 0.25; "three quarters" \
is 0.75; "one and a half" is 1.5. Size words (mini, snack size, small, medium, large, king size, \
footlong, tall, grande, venti) scale the base food realistically. Never round a fractional \
portion up to a whole item, and never ignore a size word. When a number names a NUTRIENT, not a \
count — "40g protein shake" means a shake carrying 40 grams of protein — set that nutrient to \
the stated amount and size the rest around it.

PHOTOS. Identify each distinct food on the plate as its own item and judge its portion from what \
is visible (plate size, utensils, packaging). The athlete's words, when given, outrank the photo: \
"two of these" or "no dressing" applies to what you see. A single photo cannot show oils, sauces \
inside, or a second helping, so keep confidence modest (0.4-0.7) and let the athlete correct. If \
the image shows no food or drink at all (a desk, a person, a blank wall), return reason \
"not_food" with an empty items list; if it is too dark, blurred or cropped to read, return reason \
"unreadable" with an empty items list. Otherwise reason is "".

tags: up to 3 from exactly this set: "carb-dense", "protein", "electrolytes", "light", "pre-session", \
"recovery". note: ONE short second-person line about how this serves their training (use the context; \
e.g. "Good carb bank for tomorrow's long run."). Fueling language only — never diet, weight, calorie- \
cutting, or medical advice. No em dashes.

Output STRICT JSON matching the schema.`;

// The item schema, shared verbatim by both providers. `additionalProperties: false` on the
// Anthropic side means properties and `required` must always be edited together; the nullable
// micros are `["integer", "null"]` so "unknown" survives structured output as null.
const ITEM_PROPERTIES = {
  name: { type: "string" },
  qty: { type: "number" },
  unit: { type: "string" },
  kcal: { type: "integer" },
  carbs_g: { type: "integer" },
  protein_g: { type: "integer" },
  fat_g: { type: "integer" },
  sodium_mg: { type: "integer" },
  fluids_ml: { type: "integer" },
  potassium_mg: { type: ["integer", "null"] },
  magnesium_mg: { type: ["integer", "null"] },
  iron_mg: { type: ["number", "null"] },
  calcium_mg: { type: ["integer", "null"] },
  fiber_g: { type: ["integer", "null"] },
  sugar_g: { type: ["integer", "null"] },
  satfat_g: { type: ["integer", "null"] },
  nova: { type: ["integer", "null"] },
};
const ITEM_REQUIRED = [
  "name", "qty", "unit", "kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml",
  "potassium_mg", "magnesium_mg", "iron_mg", "calcium_mg", "fiber_g", "sugar_g", "satfat_g", "nova",
];

const ANTHROPIC_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    items: {
      type: "array",
      items: { type: "object", additionalProperties: false, properties: ITEM_PROPERTIES, required: ITEM_REQUIRED },
    },
    confidence: { type: "number" },
    tags: { type: "array", items: { type: "string" } },
    note: { type: "string" },
    reason: { type: "string" },
  },
  required: ["items", "confidence", "tags", "note", "reason"],
};

const GEMINI_SCHEMA = {
  type: "object",
  properties: {
    items: { type: "array", items: { type: "object", properties: ITEM_PROPERTIES, required: ITEM_REQUIRED } },
    confidence: { type: "number" },
    tags: { type: "array", items: { type: "string" } },
    note: { type: "string" },
    reason: { type: "string" },
  },
  required: ["items", "confidence", "tags", "note", "reason"],
};

type ProviderInput = { userJSON: string; image: ImageInput | null };

async function estimateWithGemini({ userJSON, image }: ProviderInput): Promise<unknown> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`;
  const parts: Record<string, unknown>[] = [{ text: userJSON }];
  if (image) parts.push({ inline_data: { mime_type: image.mime, data: image.base64 } });
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: SYSTEM }] },
      contents: [{ role: "user", parts }],
      generationConfig: {
        maxOutputTokens: MAX_TOKENS,
        // A nutrition estimate needs no chain-of-thought — default thinking burned the whole
        // output budget on gemini-3.5-flash and returned an empty payload. "low" is the minimum
        // this generation accepts ("none" is not a valid ThinkingLevel).
        thinkingConfig: { thinkingLevel: "low" },
        // 3-era structured outputs: `responseJsonSchema` takes STANDARD JSON Schema (the old
        // OpenAPI-dialect `responseSchema` is 2.5-only). JSON mode alone let 3.5-flash drop keys.
        responseMimeType: "application/json",
        responseJsonSchema: GEMINI_SCHEMA,
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}`);
  const data = await res.json();
  // Newer Flash models think: part 0 can be a thought — the JSON rides in the non-thought text parts.
  const outParts = data?.candidates?.[0]?.content?.parts ?? [];
  const text = outParts.filter((p: { text?: string; thought?: boolean }) => p.text && !p.thought)
    .map((p: { text?: string }) => p.text).join("") || "{}";
  // Prose-tolerant: take the outermost {...} block, whatever the model wrapped it in.
  const start = text.indexOf("{"), end = text.lastIndexOf("}");
  const jsonText = start >= 0 && end > start ? text.slice(start, end + 1) : "{}";
  const parsed = JSON.parse(jsonText) as Record<string, unknown>;
  parsed.model = data?.modelVersion ?? GEMINI_MODEL;
  return parsed;
}

async function estimateWithClaude({ userJSON, image }: ProviderInput): Promise<unknown> {
  const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
  const content: Anthropic.MessageParam["content"] = image
    ? [
      { type: "image", source: { type: "base64", media_type: image.mime as "image/jpeg" | "image/png" | "image/webp", data: image.base64 } },
      { type: "text", text: userJSON },
    ]
    : userJSON;
  const message = await client.messages.create({
    model: FALLBACK_MODEL,
    max_tokens: MAX_TOKENS,
    system: SYSTEM,
    output_config: { format: { type: "json_schema", schema: ANTHROPIC_SCHEMA } },
    messages: [{ role: "user", content }],
  });
  const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
  return JSON.parse(text);
}

// Structured, athlete-free logging: counts, provider, timing, outcome. Never text, never bytes.
function log(event: Record<string, unknown>) {
  console.info(JSON.stringify({ fn: "meal-estimate", ...event }));
}

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  const startedAt = Date.now();
  let hasImage = false;
  try {
    const parsed = parseRequest(await req.json());
    if (!parsed.ok) {
      log({ outcome: "bad_request", error: parsed.error });
      return json({ error: parsed.error }, 400);
    }
    const { text, image, context } = parsed.value;
    hasImage = image !== null;
    if (!(await withinRateLimit(req))) {
      log({ outcome: "rate_limited", hasImage });
      return json({ error: "rate_limited" }, 429);
    }
    const userJSON = JSON.stringify({
      meal: text || (image ? "(see photo)" : ""),
      hasPhoto: hasImage,
      context,
    });

    let raw: unknown;
    let provider: "gemini" | "claude";
    if (GEMINI_KEY) {
      try {
        raw = await estimateWithGemini({ userJSON, image });
        provider = "gemini";
      } catch (e) {
        // fall through to Claude — a transient Gemini error must never cost the athlete an estimate
        log({ outcome: "gemini_failed", hasImage, error: e instanceof Error ? e.message.slice(0, 80) : "unknown" });
        raw = await estimateWithClaude({ userJSON, image });
        provider = "claude";
      }
    } else {
      raw = await estimateWithClaude({ userJSON, image });
      provider = "claude";
    }

    const validated = validateEstimate(raw);
    if (!validated.ok) {
      log({ outcome: "invalid_response", provider, hasImage, error: validated.error, ms: Date.now() - startedAt });
      return json({ error: "estimate_unavailable" }, 503);
    }
    const estimate: Estimate = validated.value;
    const model = (raw as Record<string, unknown>)?.model;
    log({
      outcome: estimate.reason ? estimate.reason : "ok", provider, hasImage,
      items: estimate.items.length, ms: Date.now() - startedAt,
    });
    // `provider` and `model` ride along for observability (the app's decoder ignores unknown fields).
    return json({ ...estimate, provider, model: typeof model === "string" ? model : undefined }, 200);
  } catch (e) {
    // The app keeps the meal as "pending" with a manual-entry affordance — never block a log.
    log({ outcome: "unavailable", hasImage, error: e instanceof Error ? e.message.slice(0, 80) : "unknown", ms: Date.now() - startedAt });
    return json({ error: "estimate_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
