// Supabase Edge Function: meal-estimate (FUEL pillar, 2026-07-16)
//
// Given one meal — the athlete's own sentence, plus light training context — returns approximate
// nutrition as STRICT JSON. The iOS app treats every number as an estimate ("≈" everywhere), lets
// the athlete override by hand, and logs meals fine offline with the estimate pending — this
// function is never allowed to block a log. Text-only by design (Amy-style; photo capture was
// removed from the app 2026-07-16 — plate photos estimate too loosely).
//
// Fueling, not dieting: the numbers exist to answer "fueled for the work?", so the note speaks
// to training readiness. Never diet, weight, or medical language.
//
// Provider: **Gemini 2.5 Flash primary** (user decision 2026-07-16 — the Amy stack; ~2–3× cheaper
// and fast on short structured outputs), with **Claude Haiku as automatic fallback** when
// GEMINI_API_KEY is unset or the Gemini call fails — so estimation never breaks across the switch.
//
// Deploy:  supabase functions deploy meal-estimate
// Secrets: GEMINI_API_KEY (primary; user-set), ANTHROPIC_API_KEY (fallback, already set)
//          MEAL_MODEL (default gemini-2.5-flash), MEAL_FALLBACK_MODEL (default claude-haiku-4-5-20251001)

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";
import { createClient } from "npm:@supabase/supabase-js@2";

const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const GEMINI_MODEL = Deno.env.get("MEAL_MODEL") ?? "gemini-flash-latest";   // rolling alias — 2.5-flash is sunset for new keys
const FALLBACK_MODEL = Deno.env.get("MEAL_FALLBACK_MODEL") ?? "claude-haiku-4-5-20251001";
const MAX_TOKENS = Number(Deno.env.get("MEAL_MAX_TOKENS") ?? "1600");

// Per-athlete DAILY estimate cap (server-side — a client limit is trivially bypassed). Generous:
// the heaviest honest day (race-day gels + drinks + meals) sits near 20 estimates; 60 only ever
// stops abuse or a leaked token. LOGGING is never limited — an over-limit meal stays pending with
// manual numbers always available. Enforced by `fuel_rate_check` (migration 20260716000001).
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
}   // itemized output + low-thinking overhead

const SYSTEM = `You estimate the nutrition of ONE meal for an endurance athlete's fueling readout. \
You get the athlete's own description ("chicken rice bowl", "2 gels + banana") and light context \
about their next training session.

Break the meal into ITEMS (the athlete's words may pack several foods: "2 eggs, toast, coffee" is \
three items). For each item return: name (short, title-case), qty (a number), unit (a natural short \
unit for that food: "egg", "slice", "cup", "bowl", "gel", "serving"), and that item's kcal, \
carbohydrate grams, protein grams, fat grams, sodium milligrams, fluid milliliters (0 unless \
it's a drink), potassium milligrams, magnesium milligrams, iron milligrams (decimals fine), and \
calcium milligrams — the endurance micros. Typical home/restaurant portions unless quantities are given. confidence is 0-1 \
(branded sports nutrition rates higher; vague descriptions lower).

tags: up to 3 from exactly this set: "carb-dense", "protein", "electrolytes", "light", "pre-session", \
"recovery". note: ONE short second-person line about how this serves their training (use the context; \
e.g. "Good carb bank for tomorrow's long run."). Fueling language only — never diet, weight, calorie- \
cutting, or medical advice. No em dashes.

Output STRICT JSON matching the schema.`;

// Anthropic keeps strict structured outputs (its validator rejects maxItems — the prompt caps
// the tags list). Gemini runs JSON-mode + prompt contract; see estimateWithGemini.
const ANTHROPIC_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          name: { type: "string" },
          qty: { type: "number" },
          unit: { type: "string" },
          kcal: { type: "integer" },
          carbs_g: { type: "integer" },
          protein_g: { type: "integer" },
          fat_g: { type: "integer" },
          sodium_mg: { type: "integer" },
          fluids_ml: { type: "integer" },
          potassium_mg: { type: "integer" },
          magnesium_mg: { type: "integer" },
          iron_mg: { type: "number" },
          calcium_mg: { type: "integer" },
        },
        required: ["name", "qty", "unit", "kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml",
                   "potassium_mg", "magnesium_mg", "iron_mg", "calcium_mg"],
      },
    },
    confidence: { type: "number" },
    tags: { type: "array", items: { type: "string" } },
    note: { type: "string" },
  },
  required: ["items", "confidence", "tags", "note"],
};

async function estimateWithGemini(userJSON: string): Promise<unknown> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: SYSTEM }] },
      contents: [{ role: "user", parts: [{ text: userJSON }] }],
      generationConfig: {
        maxOutputTokens: MAX_TOKENS,
        // A nutrition estimate needs no chain-of-thought — default thinking burned the whole
        // output budget on gemini-3.5-flash and returned an empty payload. "low" is the minimum
        // this generation accepts ("none" is not a valid ThinkingLevel).
        thinkingConfig: { thinkingLevel: "low" },
        // 3-era structured outputs: `responseJsonSchema` takes STANDARD JSON Schema (the old
        // OpenAPI-dialect `responseSchema` is 2.5-only). JSON mode alone let 3.5-flash drop keys.
        responseMimeType: "application/json",
        responseJsonSchema: {
          type: "object",
          properties: {
            items: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  qty: { type: "number" },
                  unit: { type: "string" },
                  kcal: { type: "integer" },
                  carbs_g: { type: "integer" },
                  protein_g: { type: "integer" },
                  fat_g: { type: "integer" },
                  sodium_mg: { type: "integer" },
                  fluids_ml: { type: "integer" },
                  potassium_mg: { type: "integer" },
                  magnesium_mg: { type: "integer" },
                  iron_mg: { type: "number" },
                  calcium_mg: { type: "integer" },
                },
                required: ["name", "qty", "unit", "kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml",
                           "potassium_mg", "magnesium_mg", "iron_mg", "calcium_mg"],
              },
            },
            confidence: { type: "number" },
            tags: { type: "array", items: { type: "string" } },
            note: { type: "string" },
          },
          required: ["items", "confidence", "tags", "note"],
        },
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const data = await res.json();
  // Newer Flash models think: part 0 can be a thought — the JSON rides in the non-thought text parts.
  const parts = data?.candidates?.[0]?.content?.parts ?? [];
  const text = parts.filter((p: { text?: string; thought?: boolean }) => p.text && !p.thought)
    .map((p: { text?: string }) => p.text).join("") || "{}";
  // Prose-tolerant: take the outermost {...} block, whatever the model wrapped it in.
  const start = text.indexOf("{"), end = text.lastIndexOf("}");
  const jsonText = start >= 0 && end > start ? text.slice(start, end + 1) : "{}";
  const parsed = JSON.parse(jsonText) as Record<string, unknown>;
  parsed.model = data?.modelVersion ?? GEMINI_MODEL;
  return parsed;
}

async function estimateWithClaude(userJSON: string): Promise<unknown> {
  const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
  const message = await client.messages.create({
    model: FALLBACK_MODEL,
    max_tokens: MAX_TOKENS,
    system: SYSTEM,
    output_config: { format: { type: "json_schema", schema: ANTHROPIC_SCHEMA } },
    messages: [{ role: "user", content: userJSON }],
  });
  const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
  return JSON.parse(text);
}

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json(); // { text, context?: { session?, durationS? } }
    const text = String(payload.text ?? "").slice(0, 500);
    if (!text) return json({ error: "empty" }, 400);
    if (!(await withinRateLimit(req))) {
      return json({ error: "rate_limited" }, 429);
    }
    const userJSON = JSON.stringify({ meal: text, context: payload.context ?? {} });

    // `provider` rides along for observability (the app's decoder ignores unknown fields).
    if (GEMINI_KEY) {
      try {
        const out = await estimateWithGemini(userJSON) as Record<string, unknown>;
        return json({ ...out, provider: "gemini" }, 200);
      } catch (_g) {
        // fall through to Claude — a transient Gemini error must never cost the athlete an estimate
      }
    }
    const out = await estimateWithClaude(userJSON) as Record<string, unknown>;
    return json({ ...out, provider: "claude" }, 200);
  } catch (_e) {
    // The app keeps the meal as "pending" with a manual-entry affordance — never block a log.
    return json({ error: "estimate_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
