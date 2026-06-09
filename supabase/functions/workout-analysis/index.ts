// Supabase Edge Function: workout-analysis (PRD §8.8)
//
// Given one completed workout + its plan target, returns a short, warm, specific, plan-aware
// note as STRICT JSON. The iOS app authenticates with the Supabase user JWT and falls back to a
// deterministic template (WorkoutReadTemplates.swift) whenever this is slow/down/unconfigured —
// so the post-workout moment never blocks.
//
// Deploy:  supabase functions deploy workout-analysis
// Secrets: supabase secrets set ANTHROPIC_API_KEY=... AI_MODEL=claude-opus-4-8 AI_MAX_TOKENS=400
//
// Model note: AI_MODEL defaults to claude-opus-4-8. Opus 4.8 REMOVES `temperature`/`top_p`/`top_k`
// (sending them 400s), so we do not set them — output shape is constrained via structured outputs.

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";

const MODEL = Deno.env.get("AI_MODEL") ?? "claude-opus-4-8";
const MAX_TOKENS = Number(Deno.env.get("AI_MAX_TOKENS") ?? "400");

const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

const SYSTEM = `You are momentum's coach, and you keep a long-term memory of this athlete. \
You're given one completed workout, its plan target, and an \`athlete\` object holding what you've \
learned so far (\`facts\` — derived numbers; \`notes\` — your evolving beliefs; \`recentNarratives\` \
— your last couple of notes, so don't repeat yourself).

Write a short, warm, specific note in the second person. Reference concrete data — for cardio: \
splits, pace/speed, cadence, HR zones, elevation; for strength: top sets, estimated 1RM change, \
weekly volume per muscle — and make it feel like you remember this person by drawing on \
\`athlete.facts\`/\`notes\` (a real pattern, not a platitude). Honor any note with \`pinned: true\` \
as ground truth over your own inference. Never give medical or injury diagnosis. Never shame a \
missed target.

Also return \`memoryUpdates\`: 0–3 ops that revise your memory from THIS workout only. \`op\` is \
"add", "revise" (with the note \`id\`), or "retire" (with the \`id\`). Add/revise only when this \
session is genuine evidence; cite an \`evidenceKey\` (a fact key or workout id). Use ONLY numbers \
from \`athlete.facts\` — never invent them. Each note text is <= 140 chars, second person, no shame, \
no medical language.

Write like a person, not a chatbot: never use em dashes or en dashes (— –); use periods and commas \
instead. (Hyphens in compound words like "3-day" are fine.)

Output STRICT JSON matching the schema; the narrative must be <= 55 words.`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    narrative: { type: "string" },
    insights: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: { label: { type: "string" }, value: { type: "string" }, note: { type: "string" } },
        required: ["label", "value", "note"],
      },
    },
    planAdjustment: {
      type: "object",
      additionalProperties: false,
      properties: { changed: { type: "boolean" }, summary: { type: "string" } },
      required: ["changed", "summary"],
    },
    memoryUpdates: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          op: { type: "string", enum: ["add", "revise", "retire"] },
          id: { type: "string" },
          category: { type: "string", enum: ["habit", "preference", "response", "motivation", "risk", "identity"] },
          text: { type: "string" },
          confidence: { type: "string", enum: ["emerging", "growing", "confident"] },
          evidenceKeys: { type: "array", items: { type: "string" } },
        },
        required: ["op"],
      },
    },
  },
  required: ["narrative", "insights", "planAdjustment", "memoryUpdates"],
};

Deno.serve(async (req) => {
  // The app sends the Supabase user JWT; Supabase verifies it before invoking when the function
  // is deployed with --no-verify-jwt omitted. We additionally require the header to be present.
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json(); // discipline-tagged body, see §8.8
    const message = await client.messages.create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content: JSON.stringify(payload) }],
    });
    const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
    // Strict-JSON guaranteed by structured outputs; parse and return.
    return json(JSON.parse(text), 200);
  } catch (_e) {
    // The client renders its deterministic template on any non-200 — never block the moment.
    return json({ error: "analysis_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
