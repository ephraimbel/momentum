// Supabase Edge Function: meal-estimate (FUEL pillar, 2026-07-16)
//
// Given one meal — the athlete's sentence and/or a plate photo, plus light training context —
// returns approximate nutrition as STRICT JSON. The iOS app treats every number as an estimate
// ("≈" everywhere), lets the athlete override by hand, and logs meals fine offline with the
// estimate pending — this function is never allowed to block a log.
//
// Fueling, not dieting: the numbers exist to answer "fueled for the work?", so the note speaks
// to training readiness. Never diet, weight, or medical language.
//
// Deploy:  supabase functions deploy meal-estimate
// Secrets: ANTHROPIC_API_KEY (shared), MEAL_MODEL (default claude-haiku-4-5-20251001 — estimation
//          is a cheap, high-volume call; haiku keeps per-meal cost negligible).

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";

const MODEL = Deno.env.get("MEAL_MODEL") ?? "claude-haiku-4-5-20251001";
const MAX_TOKENS = Number(Deno.env.get("MEAL_MAX_TOKENS") ?? "300");

const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

const SYSTEM = `You estimate the nutrition of ONE meal for an endurance athlete's fueling readout. \
You get the athlete's own description ("chicken rice bowl", "2 gels + banana"), optionally a photo \
of the plate, and light context about their next training session.

Return your best single estimate of the WHOLE described meal (not per serving): kcal, carbohydrate \
grams, protein grams, fat grams, sodium milligrams, and fluid milliliters (0 if no drink is part of \
it). Typical restaurant/home portions unless quantities are given. confidence is 0-1 (photos of \
clear plates or branded sports nutrition rate higher; vague descriptions lower).

tags: up to 3 from exactly this set: "carb-dense", "protein", "electrolytes", "light", "pre-session", \
"recovery". note: ONE short second-person line about how this serves their training (use the context; \
e.g. "Good carb bank for tomorrow's long run."). Fueling language only — never diet, weight, calorie- \
cutting, or medical advice. No em dashes.

Output STRICT JSON matching the schema.`;

const SCHEMA = {
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
    tags: { type: "array", items: { type: "string" }, maxItems: 3 },
    note: { type: "string" },
  },
  required: ["kcal", "carbs_g", "protein_g", "fat_g", "sodium_mg", "fluids_ml", "confidence", "tags", "note"],
};

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json(); // { text, photoBase64?, context?: { session?, durationS? } }
    const text = String(payload.text ?? "").slice(0, 500);
    const context = payload.context ?? {};
    if (!text && !payload.photoBase64) return json({ error: "empty" }, 400);

    const content: Anthropic.ContentBlockParam[] = [];
    if (typeof payload.photoBase64 === "string" && payload.photoBase64.length > 0) {
      content.push({
        type: "image",
        source: { type: "base64", media_type: "image/jpeg", data: payload.photoBase64 },
      });
    }
    content.push({ type: "text", text: JSON.stringify({ meal: text, context }) });

    const message = await client.messages.create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content }],
    });
    const out = message.content.find((b) => b.type === "text")?.text ?? "{}";
    return json(JSON.parse(out), 200);
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
