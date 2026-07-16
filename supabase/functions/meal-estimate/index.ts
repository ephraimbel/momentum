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

const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const GEMINI_MODEL = Deno.env.get("MEAL_MODEL") ?? "gemini-2.5-flash";
const FALLBACK_MODEL = Deno.env.get("MEAL_FALLBACK_MODEL") ?? "claude-haiku-4-5-20251001";
const MAX_TOKENS = Number(Deno.env.get("MEAL_MAX_TOKENS") ?? "300");

const SYSTEM = `You estimate the nutrition of ONE meal for an endurance athlete's fueling readout. \
You get the athlete's own description ("chicken rice bowl", "2 gels + banana") and light context \
about their next training session.

Return your best single estimate of the WHOLE described meal (not per serving): kcal, carbohydrate \
grams, protein grams, fat grams, sodium milligrams, and fluid milliliters (0 if no drink is part of \
it). Typical restaurant/home portions unless quantities are given. confidence is 0-1 (branded sports \
nutrition rates higher; vague descriptions lower).

tags: up to 3 from exactly this set: "carb-dense", "protein", "electrolytes", "light", "pre-session", \
"recovery". note: ONE short second-person line about how this serves their training (use the context; \
e.g. "Good carb bank for tomorrow's long run."). Fueling language only — never diet, weight, calorie- \
cutting, or medical advice. No em dashes.

Output STRICT JSON matching the schema.`;

// One logical schema, two dialects (Gemini's OpenAPI subset vs Anthropic's JSON Schema — and
// Anthropic's structured-outputs validator rejects maxItems, so the prompt caps the tags list).
const GEMINI_SCHEMA = {
  type: "OBJECT",
  properties: {
    kcal: { type: "INTEGER" },
    carbs_g: { type: "INTEGER" },
    protein_g: { type: "INTEGER" },
    fat_g: { type: "INTEGER" },
    sodium_mg: { type: "INTEGER" },
    fluids_ml: { type: "INTEGER" },
    confidence: { type: "NUMBER" },
    tags: { type: "ARRAY", items: { type: "STRING" } },
    note: { type: "STRING" },
  },
  required: ["kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml", "confidence", "tags", "note"],
};
const ANTHROPIC_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    kcal: { type: "integer" },
    carbs_g: { type: "integer" },
    protein_g: { type: "integer" },
    fat_g: { type: "integer" },
    sodium_mg: { type: "integer" },
    fluids_ml: { type: "integer" },
    confidence: { type: "number" },
    tags: { type: "array", items: { type: "string" } },
    note: { type: "string" },
  },
  required: ["kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml", "confidence", "tags", "note"],
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
        responseMimeType: "application/json",
        responseSchema: GEMINI_SCHEMA,
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const data = await res.json();
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";
  return JSON.parse(text);
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
    const userJSON = JSON.stringify({ meal: text, context: payload.context ?? {} });

    if (GEMINI_KEY) {
      try {
        return json(await estimateWithGemini(userJSON), 200);
      } catch (_g) {
        // fall through to Claude — a transient Gemini error must never cost the athlete an estimate
      }
    }
    return json(await estimateWithClaude(userJSON), 200);
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
