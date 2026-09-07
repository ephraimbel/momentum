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
// HOW THE PHOTO ESTIMATE STAYS ACCURATE AND REPEATABLE (the 2026-09-07 vision pass, modelled on
// what the best photo trackers do and on where they fail):
//   1. Weigh, then compute. The model names each food, sizes it in GRAMS from references it can
//      see (plate, fork, mug, can, hand), and derives the numbers from per-100 g values for that
//      food as prepared. A weight times a reference is repeatable; a whole-plate guess is not.
//   2. Hidden fat is added on purpose (oil, butter, dressing never show), labels and packaging
//      are read when legible, and the athlete's words always outrank the pixels.
//   3. Decoding is pinned: one named model version, a fixed seed, thinking at its floor (an
//      estimate needs no essay), and the JSON shape enforced by a schema, so the same plate asks
//      the same question of the same model. (Gemini 3 retired `temperature`; see below.)
//   4. The validator (`validate.ts`) is the contract, not the model: item counts and numbers are
//      bounded, every item's kcal is reconciled to its own macros (Atwater, alcohol included),
//      grams and kcal snap to hand-sized steps, unknown micros stay null.
//
// Logs carry counts, timings, token usage and the provider only — never the athlete's words or
// image bytes.
//
// Fueling, not dieting: the numbers exist to answer "fueled for the work?", so the note speaks
// to training readiness. Never diet, weight, or medical language.
//
// Provider: **Gemini Flash primary** (user decision 2026-07-16), with **Claude Haiku as automatic
// fallback** when GEMINI_API_KEY is unset or the Gemini call fails, and ONLY when ANTHROPIC_API_KEY
// is set (it is not, today: the fallback is dormant and the function says so in its log).
//
// Deploy:  supabase functions deploy meal-estimate
// Secrets: GEMINI_API_KEY (primary; user-set), ANTHROPIC_API_KEY (fallback, optional)
//          MEAL_MODEL (default gemini-3.8-flash, pinned), MEAL_FALLBACK_MODEL (default claude-haiku-4-5-20251001)
//          MEAL_DAILY_LIMIT (default 60), MEAL_IMAGE_DAILY_LIMIT (default 30)
//          MEAL_TEXT_TIMEOUT_MS (6000) / MEAL_IMAGE_TIMEOUT_MS (15000)
//          MEAL_SEED (7; "" omits), MEAL_TEMPERATURE (unset: Gemini 3 deprecated it), MEAL_MEDIA_RESOLUTION
//          (MEDIA_RESOLUTION_HIGH), MEAL_THINKING (low) / MEAL_IMAGE_THINKING (low)
//          MEAL_MAX_TOKENS (1800) / MEAL_IMAGE_MAX_TOKENS (3000)
// Tests:   deno test supabase/functions/meal-estimate
// Bench:   scripts/meal_bench.ts (the same photo N times; reports run-to-run spread and cost)

import Anthropic from "npm:@anthropic-ai/sdk@^0.124";
import { createClient } from "npm:@supabase/supabase-js@2";
import { type Estimate, type ImageInput, MAX_IMAGE_BYTES, parseRequest, validateEstimate } from "./validate.ts";

const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
// PINNED, not the rolling alias (2026-09-07): `gemini-flash-latest` is hot-swapped with every
// release, so a Tuesday's numbers could differ from a Monday's for the same plate, and a retired
// target 404s with no warning. 3.8 Flash went GA on 2026-09-02; move it deliberately, with a bench
// run (scripts/meal_bench.ts) in hand.
const GEMINI_MODEL = Deno.env.get("MEAL_MODEL") ?? "gemini-3.8-flash";
const FALLBACK_MODEL = Deno.env.get("MEAL_FALLBACK_MODEL") ?? "claude-haiku-4-5-20251001";
// 1800 (was 1600): the 2026-08-15 quality fields (fiber/sugar/satfat/nova) add four short
// numerics per item — headroom so a six-item dinner can't truncate mid-JSON. A photo gets more:
// this generation bills its thoughts against the same budget, and a plate can carry ten items
// (the budget is a ceiling, not a spend — a short answer costs a short answer).
const MAX_TOKENS = Number(Deno.env.get("MEAL_MAX_TOKENS") ?? "1800");
const IMAGE_MAX_TOKENS = Number(Deno.env.get("MEAL_IMAGE_MAX_TOKENS") ?? "3000");
// Repeatable decoding. The same plate must get the same answer. Gemini 3 deprecated
// `temperature` / `top_p` / `top_k` (changelog 2026-07-21; the 3.8 guide says to strip them, and a
// request carrying them is refused with 400 "invalid argument"), so the request sends a fixed
// `seed` instead and leaves temperature at the model's default unless MEAL_TEMPERATURE is set
// (an empty MEAL_SEED omits the seed). Repeatability beyond that is engineered in the prompt
// ("SAME MEAL, SAME ANSWER") and the validator (snapping, reconciliation), and measured by the
// bench rather than assumed.
const TEMPERATURE = Deno.env.get("MEAL_TEMPERATURE") ?? "";
const SEED = Deno.env.get("MEAL_SEED") ?? "7";
// Gemini 3 bills an image at a fixed token count per resolution level (LOW 280, MEDIUM 560, HIGH
// 1120). HIGH is the documented default for images and what a plate with a legible label needs;
// set explicitly so a default change upstream cannot silently degrade reads. "" omits the field.
const MEDIA_RESOLUTION = Deno.env.get("MEAL_MEDIA_RESOLUTION") ?? "MEDIA_RESOLUTION_HIGH";
// A nutrition estimate needs no chain-of-thought — default thinking burned the whole output
// budget on gemini-3.5-flash and returned an empty payload. "low" is the minimum this generation
// accepts ("none" is not a valid ThinkingLevel). Photos can be dialled separately for the bench.
const THINKING = Deno.env.get("MEAL_THINKING") ?? "low";
const IMAGE_THINKING = Deno.env.get("MEAL_IMAGE_THINKING") ?? "low";

// Per-athlete DAILY estimate cap (server-side — a client limit is trivially bypassed). Generous:
// the heaviest honest day (race-day gels + drinks + meals) sits near 20 estimates; 60 only ever
// stops abuse or a leaked token. LOGGING is never limited — an over-limit meal stays pending with
// manual numbers always available. Enforced by `fuel_rate_check` (migration 20260716000001).
// Photo requests count against the same cap: a vision call costs more, not less.
const DAILY_LIMIT = Number(Deno.env.get("MEAL_DAILY_LIMIT") ?? "60");
// A vision call costs several times a text call, so a photo checks the day's counter against a
// lower ceiling (the counter itself is shared: `fuel_rate_check` increments one bucket a day).
const IMAGE_DAILY_LIMIT = Number(Deno.env.get("MEAL_IMAGE_DAILY_LIMIT") ?? "30");
// ONE deadline per request, shared by the primary and the fallback, sized inside the app's own
// window (8 s text, 20 s photo): a Gemini failure leaves whatever remains to Claude, and the
// isolate never keeps spending after the athlete's request has been abandoned.
const TEXT_TIMEOUT_MS = Number(Deno.env.get("MEAL_TEXT_TIMEOUT_MS") ?? "6000");
// 15 s (was 12): the bench saw honest 10 s answers from Gemini on a busy plate; the app allows 20.
const IMAGE_TIMEOUT_MS = Number(Deno.env.get("MEAL_IMAGE_TIMEOUT_MS") ?? "15000");
// The largest body the function will even parse: the image ceiling as base64, plus headroom.
const MAX_BODY_BYTES = Math.ceil(MAX_IMAGE_BYTES * 4 / 3) + 64 * 1024;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
// With MEAL_DEBUG=1 a 503 carries the provider's own error line (its status and its message,
// never the request) so a canary can be read without the dashboard. Off in production.
const DEBUG = Deno.env.get("MEAL_DEBUG") === "1";

type RateVerdict = "allowed" | "limited" | "unknown";

// The caller's address as the gateway saw it: the LAST forwarded hop, which the edge appends and
// the client cannot write, never the first (a client-supplied `x-forwarded-for` value would mint a
// fresh guest bucket per request). `cf-connecting-ip` wins when the gateway sets it.
function clientKey(req: Request): string {
  const cf = req.headers.get("cf-connecting-ip")?.trim();
  if (cf) return cf;
  const hops = (req.headers.get("x-forwarded-for") ?? "").split(",").map((h) => h.trim()).filter(Boolean);
  return hops.at(-1) ?? "";
}

// Text keeps the coach limiter's FAIL-OPEN stance: if the RPC is missing or the DB blips, allow the
// request and let the cap re-engage when the check works again. Keyed on auth.uid() (unspoofable)
// for signed-in athletes; guests fall back to the gateway's view of their address, in a separate
// bucket for photos. The caller decides what "unknown" means (photos fail closed).
async function rateVerdict(req: Request, hasImage: boolean): Promise<RateVerdict> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return "unknown";
  try {
    const auth = req.headers.get("authorization") ?? "";
    const key = clientKey(req);
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await supabase.rpc("fuel_rate_check", {
      p_limit: hasImage ? IMAGE_DAILY_LIMIT : DAILY_LIMIT,
      p_fallback_key: hasImage ? `photo:${key}` : key,
    });
    if (error) return "unknown";
    const row = Array.isArray(data) ? data[0] : data;
    return row?.allowed === false ? "limited" : "allowed";
  } catch (_e) {
    return "unknown";
  }
}

// The shared contract: what an item is, how numbers are derived, and the language rules. Text
// and photo requests both open with it, so a text call's cached prefix is a text call's alone
// and a photo call's is a photo call's (the photo protocol is appended, never interleaved).
const SYSTEM_CORE = `You estimate the nutrition of ONE meal for an endurance athlete's fueling readout. \
You get the athlete's own description ("chicken rice bowl", "2 gels + banana"), a photo of the \
plate, or both, plus light context about their next training session.

Break the meal into ITEMS (the athlete's words or the plate may pack several foods: "2 eggs, toast, \
coffee" is three items). For each item return: name (short, title-case, the plain canonical name of \
the food), qty (a number), unit (a natural short unit for that food: "egg", "slice", "cup", "bowl", \
"gel", "serving"), grams (the whole portion's weight in grams as served, millilitres for a drink; \
null only when it truly cannot be judged), and that item's kcal, carbohydrate grams, protein grams, \
fat grams, alcohol_g (grams of ethanol: 0 for food, about 13 per 330 ml of 5% beer, 14 per 150 ml \
glass of wine, 14 per 45 ml spirit), sodium milligrams, fluid milliliters (0 unless it's a drink), \
potassium milligrams, magnesium milligrams, iron milligrams (decimals fine), calcium milligrams — \
the endurance micros — plus the food-quality facts: fiber_g (dietary fiber grams), sugar_g (TOTAL \
sugars grams, intrinsic plus added), satfat_g (saturated fat grams), and nova (the NOVA processing \
classification as an integer: 1 unprocessed/minimally processed food, 2 processed culinary \
ingredient, 3 processed food, 4 ultra-processed food). NOVA anchors: fresh produce, plain \
meat/fish/eggs, milk, rice, oats are 1; butter, honey, oils, sugar are 2; fresh bread, cheese, \
cured meats (bacon, ham), canned goods, home-fried foods are 3; sodas, candy, packaged snacks, ice \
cream, instant noodles, hot dogs/nuggets, fast food, gels and sports drinks are 4. When torn \
between two classes, pick the HIGHER (more processed). Typical home/restaurant portions unless \
quantities are given.

WEIGH, THEN COMPUTE. Size every item in grams first, then derive its numbers from typical per-100 g \
values for that food AS PREPARED, multiplied by the grams. Reference values per 100 g (kcal / the \
lead macro): cooked white rice 130 / 28 g carbs, cooked pasta 160 / 31 g carbs, cooked oats 70 / \
12 g carbs, white bread 265 / 49 g carbs, boiled potato 87 / 20 g carbs, fries 310 / 41 g carbs, \
cheese pizza 270 / 33 g carbs, banana 89 / 23 g carbs, apple 52 / 14 g carbs, grilled chicken \
breast 165 / 31 g protein, cooked salmon 205 / 22 g protein, lean cooked beef 250 / 26 g protein, \
whole egg 155 / 13 g protein, whole milk 61 / 3 g protein, cheddar 400 / 25 g protein, avocado \
160 / 15 g fat, olive oil 884 / 100 g fat, butter 717 / 81 g fat. Typical weights: a large egg \
50 g, a bread slice 30 g, a banana 120 g, an apple 180 g, a medium potato 170 g, a cup of cooked \
rice 160 g, a cup of cooked pasta 140 g, a palm of meat 120 g, a tablespoon of oil 14 g, an \
energy gel 32 g, a can 330 ml, a mug 300 ml, a pint 570 ml. A quantity times a reference is \
repeatable; a whole-plate guess is not.

UNKNOWN IS NULL. When a micro (potassium, magnesium, iron, calcium, fiber, sugar, saturated fat, \
nova) or the grams cannot be judged for an item, return null for it. Never write 0 to mean "I \
don't know"; 0 means the food genuinely has none.

NUMBERS MUST AGREE. Per item: kcal within ~10% of 4*carbs_g + 4*protein_g + 9*fat_g + 7*alcohol_g, \
sugar_g <= carbs_g, fiber_g <= carbs_g, satfat_g <= fat_g, and every number scales with the grams. \
Reconcile before answering.

SAME MEAL, SAME ANSWER. Round grams to the nearest 5 (the nearest 10 above 100), kcal to the \
nearest 5, everything else to whole units (iron to one decimal). Use the plain canonical food \
name and the unit the athlete would say. Name a food in the singular when qty counts pieces \
("Fried Egg" with qty 2, unit "egg") and by its dish name otherwise ("Baked Beans", "Fries"). \
qty counts whole pieces (eggs, slices, sausages, gels, sushi pieces) or is 1 for one portion of a \
continuous food (beans, rice, pasta, salad, a bowl, a plate); a fraction only when the athlete \
stated one. List items from the largest kcal to the smallest. Never add a food that is neither \
visible nor stated.

PORTIONS ARE EXACT. The description is often dictated speech — honor every stated quantity, \
fraction, and size to the letter, and scale ALL numbers by it. "half a bagel" is qty 0.5 with \
half the nutrition of a whole bagel; "half of a large rice krispie treat" is qty 0.5 of the \
LARGE size (scale up for the size first, then halve); "a quarter of" is 0.25; "three quarters" \
is 0.75; "one and a half" is 1.5. Size words (mini, snack size, small, medium, large, king size, \
footlong, tall, grande, venti) scale the base food realistically. Never round a fractional \
portion up to a whole item, and never ignore a size word. When a number names a NUTRIENT, not a \
count — "40g protein shake" means a shake carrying 40 grams of protein — set that nutrient to \
the stated amount and size the rest around it.

confidence is 0-1: branded sports nutrition and labelled products rate 0.75-0.85, a plainly \
described home meal 0.6-0.7, a vague description ("some pasta", "a big dinner") 0.4-0.5.

tags: up to 3 from exactly this set: "carb-dense", "protein", "electrolytes", "light", "pre-session", \
"recovery". note: ONE short second-person line about how this serves their training (use the context; \
e.g. "Good carb bank for tomorrow's long run."). Fueling language only — never diet, weight, calorie- \
cutting, or medical advice. No em dashes.

reason is "" for a meal. Output STRICT JSON matching the schema.`;

// Appended for photo requests only. The order is the method: inventory, size, hidden fat,
// labels, words, confidence — the steps the best photo trackers take and the places they slip.
const PHOTO_PROTOCOL = `

PHOTO PROTOCOL. A photo is present. Work in this order.
1. INVENTORY. Name every distinct food and drink actually visible, one item each. Count discrete \
pieces (eggs, slices, nuggets, sushi pieces, gels). A mixed dish (curry, stew, salad, grain bowl, \
sandwich, burger) is ONE item named as the dish and sized as a whole. Sauces, dressings, cheese, \
butter and spreads are their own items when they are more than a garnish.
2. SIZE. Judge each portion's grams from what is in frame. A dinner plate is about 27 cm across, \
a side plate 20 cm, a cereal bowl 15 cm, a fork 19 cm long, a tablespoon 15 ml, a mug 300 ml, a \
can 330 ml, a pint glass 570 ml, a wine pour 150 ml, a palm-sized piece of meat 120 g. Food piled \
high or in a deep bowl weighs more than its footprint suggests; a plate that fills the frame is \
not necessarily large. Restaurant portions run 1.5 to 2 times home portions.
3. HIDDEN FAT. Cooking oil, butter and dressing rarely show. Add 5 to 10 g of fat for a pan-fried \
or sauteed item, 10 to 20 g for a deep-fried one, 5 to 10 g for a dressed salad, and fold it into \
that item's fat_g and kcal.
4. LABELS. If a package, menu or nutrition label is legible, name the product and use its values \
over any guess. Branded sports nutrition (gels, chews, drinks) has known label values; use them.
5. WORDS. The athlete's words outrank the photo. Quantities ("two of these"), portions ("half"), \
corrections ("no dressing", "it was brown rice") and unseen items ("plus a coffee") apply exactly \
as stated.
6. CONFIDENCE for a photo: 0.75-0.85 with a legible label or branded package; 0.55-0.7 for a \
clear plate of separate whole foods; 0.4-0.55 for mixed, sauced or stacked dishes; 0.3-0.4 when \
part of the meal is out of frame or hidden.
If the image shows no food or drink at all (a desk, a person, a blank wall), return reason \
"not_food" with an empty items list; if it is too dark, blurred or cropped to read, return reason \
"unreadable" with an empty items list. Otherwise reason is "".`;

function systemFor(hasImage: boolean): string {
  return hasImage ? SYSTEM_CORE + PHOTO_PROTOCOL : SYSTEM_CORE;
}

// The item schema, shared verbatim by both providers. `additionalProperties: false` on the
// Anthropic side means properties and `required` must always be edited together; the nullable
// fields are `anyOf` with null so "unknown" survives structured output as null.
const ITEM_PROPERTIES = {
  name: { type: "string" },
  qty: { type: "number" },
  unit: { type: "string" },
  grams: { anyOf: [{ type: "integer" }, { type: "null" }] },
  kcal: { type: "integer" },
  carbs_g: { type: "integer" },
  protein_g: { type: "integer" },
  fat_g: { type: "integer" },
  alcohol_g: { anyOf: [{ type: "integer" }, { type: "null" }] },
  sodium_mg: { type: "integer" },
  fluids_ml: { type: "integer" },
  // `anyOf` with null is the one nullable form both providers document; a `type` array is not
  // a form Anthropic's schema validator is documented to accept.
  potassium_mg: { anyOf: [{ type: "integer" }, { type: "null" }] },
  magnesium_mg: { anyOf: [{ type: "integer" }, { type: "null" }] },
  iron_mg: { anyOf: [{ type: "number" }, { type: "null" }] },
  calcium_mg: { anyOf: [{ type: "integer" }, { type: "null" }] },
  fiber_g: { anyOf: [{ type: "integer" }, { type: "null" }] },
  sugar_g: { anyOf: [{ type: "integer" }, { type: "null" }] },
  satfat_g: { anyOf: [{ type: "integer" }, { type: "null" }] },
  nova: { anyOf: [{ type: "integer" }, { type: "null" }] },
};
const ITEM_REQUIRED = [
  "name", "qty", "unit", "grams", "kcal", "carbs_g", "protein_g", "fat_g", "alcohol_g", "sodium_mg", "fluids_ml",
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

// No `maxItems` here: the docs list it as supported, but gemini-3.8-flash refuses the request with
// a bare 400 "invalid argument" when it is present (bisected live, 2026-09-07). The validator bounds
// the item and tag counts instead. `anyOf` nulls, `seed`, `mediaResolution` and `thinkingLevel`
// were all verified against the same model in the same session.
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

type ProviderInput = { userJSON: string; image: ImageInput | null; signal: AbortSignal };
/** Token counts the provider reported, for the log line and the cost ledger. */
type Usage = { in?: number; out?: number; thought?: number };
type ProviderAnswer = { raw: Record<string, unknown>; model: string; usage: Usage };

/** A provider answered in a way that retrying elsewhere cannot fix: the caller maps it, no fallback. */
class TerminalAnswer extends Error {
  constructor(readonly outcome: "truncated" | "blocked") { super(outcome); }
}

/**
 * The provider refused the request (a non-2xx). The message is the provider's own status and
 * error line, which names the bad field when a schema or parameter is wrong; it never contains
 * the athlete's words or bytes, so it is safe to log.
 */
class ProviderHTTP extends Error {
  constructor(provider: string, status: number, detail: string) {
    super(`${provider} ${status}: ${detail.slice(0, 200)}`);
    this.name = "ProviderHTTP";
  }
}

/** Prose-tolerant: take the outermost {...} block, whatever the model wrapped it in. */
function parseJSONObject(text: string): Record<string, unknown> {
  const start = text.indexOf("{"), end = text.lastIndexOf("}");
  const jsonText = start >= 0 && end > start ? text.slice(start, end + 1) : "{}";
  return JSON.parse(jsonText) as Record<string, unknown>;
}

async function estimateWithGemini({ userJSON, image, signal }: ProviderInput): Promise<ProviderAnswer> {
  // The key rides a header, never the URL: a fetch error echoes the URL into logs.
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
  const hasImage = image !== null;
  const parts: Record<string, unknown>[] = [{ text: userJSON }];
  if (image) parts.push({ inline_data: { mime_type: image.mime, data: image.base64 } });
  const res = await fetch(url, {
    method: "POST",
    signal,
    headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: systemFor(hasImage) }] },
      contents: [{ role: "user", parts }],
      generationConfig: {
        maxOutputTokens: hasImage ? IMAGE_MAX_TOKENS : MAX_TOKENS,
        ...(TEMPERATURE !== "" ? { temperature: Number(TEMPERATURE) } : {}),
        ...(SEED !== "" ? { seed: Number(SEED) } : {}),
        ...(hasImage && MEDIA_RESOLUTION ? { mediaResolution: MEDIA_RESOLUTION } : {}),
        thinkingConfig: { thinkingLevel: hasImage ? IMAGE_THINKING : THINKING },
        // 3-era structured outputs: `responseJsonSchema` takes STANDARD JSON Schema (the old
        // OpenAPI-dialect `responseSchema` is 2.5-only). JSON mode alone let 3.5-flash drop keys.
        responseMimeType: "application/json",
        responseJsonSchema: GEMINI_SCHEMA,
      },
    }),
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new ProviderHTTP("gemini", res.status, String(body?.error?.message ?? ""));
  }
  const data = await res.json();
  // A blocked prompt or candidate is a terminal answer: the photo is not something to estimate.
  // A truncated one is terminal too: the same request would truncate on Claude as well.
  if (data?.promptFeedback?.blockReason) throw new TerminalAnswer("blocked");
  const finish = String(data?.candidates?.[0]?.finishReason ?? "");
  if (["SAFETY", "PROHIBITED_CONTENT", "IMAGE_SAFETY", "SPII", "BLOCKLIST"].includes(finish)) throw new TerminalAnswer("blocked");
  if (finish === "MAX_TOKENS") throw new TerminalAnswer("truncated");
  // Newer Flash models think: part 0 can be a thought — the JSON rides in the non-thought text parts.
  const outParts = data?.candidates?.[0]?.content?.parts ?? [];
  const text = outParts.filter((p: { text?: string; thought?: boolean }) => p.text && !p.thought)
    .map((p: { text?: string }) => p.text).join("") || "{}";
  const u = data?.usageMetadata ?? {};
  return {
    raw: parseJSONObject(text),
    model: typeof data?.modelVersion === "string" ? data.modelVersion : GEMINI_MODEL,
    usage: { in: u.promptTokenCount, out: u.candidatesTokenCount, thought: u.thoughtsTokenCount },
  };
}

async function estimateWithClaude({ userJSON, image, signal }: ProviderInput): Promise<ProviderAnswer> {
  const hasImage = image !== null;
  const client = new Anthropic({
    apiKey: ANTHROPIC_KEY,
    timeout: hasImage ? IMAGE_TIMEOUT_MS : TEXT_TIMEOUT_MS,
    maxRetries: 0,
  });
  const content: Anthropic.MessageParam["content"] = image
    ? [
      { type: "image", source: { type: "base64", media_type: image.mime as "image/jpeg" | "image/png" | "image/webp", data: image.base64 } },
      { type: "text", text: userJSON },
    ]
    : userJSON;
  const message = await client.messages.create({
    model: FALLBACK_MODEL,
    max_tokens: hasImage ? IMAGE_MAX_TOKENS : MAX_TOKENS,
    ...(TEMPERATURE !== "" ? { temperature: Number(TEMPERATURE) } : {}),
    system: systemFor(hasImage),
    output_config: { format: { type: "json_schema", schema: ANTHROPIC_SCHEMA } },
    messages: [{ role: "user", content }],
  }, { signal });
  if (message.stop_reason === "max_tokens") throw new TerminalAnswer("truncated");
  const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
  return {
    raw: parseJSONObject(text),
    model: message.model,
    usage: { in: message.usage?.input_tokens, out: message.usage?.output_tokens },
  };
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
  let provider: "gemini" | "claude" | "none" = "none";
  try {
    // Refuse an oversized body before parsing it: the image ceiling as base64, plus headroom.
    const declaredLength = Number(req.headers.get("content-length") ?? "0");
    if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
      log({ outcome: "bad_request", error: "body_size" });
      return json({ error: "image_size" }, 413);
    }
    let payload: unknown;
    try {
      payload = await req.json();
    } catch (_parse) {
      log({ outcome: "bad_request", error: "json" });
      return json({ error: "bad_request" }, 400);
    }
    const parsed = parseRequest(payload);
    if (!parsed.ok) {
      log({ outcome: "bad_request", error: parsed.error });
      return json({ error: parsed.error }, 400);
    }
    const { text, image, context } = parsed.value;
    hasImage = image !== null;
    // A photo is the expensive call: an unanswered rate check refuses it (503, so the app counts
    // an attempt and asks again later instead of latching the day), while text keeps failing open.
    const verdict = await rateVerdict(req, hasImage);
    if (verdict === "limited") {
      log({ outcome: "rate_limited", hasImage });
      return json({ error: "rate_limited" }, 429);
    }
    if (verdict === "unknown" && hasImage && SUPABASE_URL) {
      log({ outcome: "rate_unknown", hasImage });
      return json({ error: "estimate_unavailable" }, 503);
    }
    const userJSON = JSON.stringify({
      meal: text || (image ? "(see photo)" : ""),
      hasPhoto: hasImage,
      context,
    });
    // One deadline for the whole request: the fallback gets what the primary left, never a
    // fresh window of its own.
    const signal = AbortSignal.any([req.signal, AbortSignal.timeout(hasImage ? IMAGE_TIMEOUT_MS : TEXT_TIMEOUT_MS)]);

    let answer: ProviderAnswer;
    try {
      if (GEMINI_KEY) {
        try {
          answer = await estimateWithGemini({ userJSON, image, signal });
          provider = "gemini";
        } catch (e) {
          if (e instanceof TerminalAnswer) throw e;
          // Transport or provider failure only: fall through to Claude, when there is a Claude to
          // fall through to. A terminal answer never re-runs elsewhere; the same request would
          // fail the same way and cost twice.
          log({ outcome: "gemini_failed", hasImage, error: e instanceof Error ? e.name : "unknown",
                detail: e instanceof ProviderHTTP ? e.message : undefined, fallback: Boolean(ANTHROPIC_KEY) });
          if (!ANTHROPIC_KEY) throw e;
          answer = await estimateWithClaude({ userJSON, image, signal });
          provider = "claude";
        }
      } else if (ANTHROPIC_KEY) {
        answer = await estimateWithClaude({ userJSON, image, signal });
        provider = "claude";
      } else {
        throw new Error("no_provider");
      }
    } catch (e) {
      if (e instanceof TerminalAnswer) {
        if (e.outcome === "blocked" && hasImage) {
          log({ outcome: "blocked", provider, hasImage, ms: Date.now() - startedAt });
          return json({ items: [], confidence: 0, tags: [], note: "", reason: "unreadable", provider }, 200);
        }
        log({ outcome: e.outcome, provider, hasImage, ms: Date.now() - startedAt });
        return json({ error: "estimate_unavailable" }, 503);
      }
      throw e;
    }

    const validated = validateEstimate(answer.raw, { hasImage });
    if (!validated.ok) {
      log({ outcome: "invalid_response", provider, model: answer.model, hasImage, error: validated.error, usage: answer.usage, ms: Date.now() - startedAt });
      return json({ error: "estimate_unavailable" }, 503);
    }
    const estimate: Estimate = validated.value;
    log({
      outcome: estimate.reason ? estimate.reason : "ok", provider, model: answer.model, hasImage,
      items: estimate.items.length, reconciled: validated.stats.reconciled, confidence: estimate.confidence,
      thinking: hasImage ? IMAGE_THINKING : THINKING, temperature: TEMPERATURE || "default", seed: SEED || "none",
      usage: answer.usage,
      ms: Date.now() - startedAt,
    });
    // `provider`, `model` and `usage` ride along for observability and the bench (the app's
    // decoder ignores unknown fields).
    return json({ ...estimate, provider, model: answer.model, usage: answer.usage }, 200);
  } catch (e) {
    // The app keeps the meal as "pending" with a manual-entry affordance — never block a log.
    // Only the error's NAME is logged: provider messages can echo request text or model output.
    const name = e instanceof Error ? (e.message === "no_provider" ? "no_provider" : e.name) : "unknown";
    const detail = e instanceof ProviderHTTP ? e.message : DEBUG && e instanceof Error ? `${e.name}: ${e.message.slice(0, 200)}` : undefined;
    log({ outcome: "unavailable", provider, hasImage, error: name, detail, ms: Date.now() - startedAt });
    return json(DEBUG ? { error: "estimate_unavailable", detail: detail ?? name } : { error: "estimate_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
