// Supabase Edge Function: workout-analysis (PRD §8.8)
//
// Given one completed workout + its plan target, returns a short, warm, specific, plan-aware
// note as STRICT JSON. The iOS app authenticates with the Supabase user JWT and falls back to a
// deterministic template (WorkoutReadTemplates.swift) whenever this is slow/down/unconfigured —
// so the post-workout moment never blocks.
//
// Deploy:  supabase functions deploy workout-analysis
// Secrets: supabase secrets set GEMINI_API_KEY=AIza...   (shared with coach-chat / meal-estimate)
//          optional: AI_MODEL=gemini-flash-latest  AI_MAX_TOKENS=800
//
// Model note (2026-07-16, user call): Gemini Flash via the `gemini-flash-latest` rolling alias
// (2.5-flash is sunset for new keys). Current Flash THINKS by default with thought tokens billed
// against maxOutputTokens — thinking is pinned to its "low" floor and the cap carries headroom, and
// thought parts (`thought: true`) are filtered out of the reply. Structured output rides
// `responseJsonSchema` (standard JSON Schema dialect — JSON mode alone lets Flash drop keys).

const MODEL = Deno.env.get("AI_MODEL") ?? "gemini-flash-latest";
// Narrative + insights + memoryUpdates JSON ≈ 250 tokens; the rest is thinking headroom (billed
// against this cap — too tight and the payload comes back empty).
const MAX_TOKENS = Number(Deno.env.get("AI_MAX_TOKENS") ?? "800");
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? Deno.env.get("GOOGLE_API_KEY") ?? "";

const SYSTEM = `You are momentum's coach, and you keep a long-term memory of this athlete. \
You're given one completed workout, its plan target, and an \`athlete\` object holding what you've \
learned so far: \`facts\` for derived numbers, \`notes\` for your evolving beliefs, and \
\`recentNarratives\` for your last couple of notes, so you don't repeat yourself.

Write a short, warm, specific note in the second person. Reference concrete data. For cardio that means \
splits, pace, cadence, HR zones, elevation. For strength it means top sets, estimated 1RM change, \
weekly volume per muscle. Make it feel like you remember this person by drawing on \
\`athlete.facts\`/\`notes\` (a real pattern, not a platitude). Honor any note with \`pinned: true\` \
as ground truth over your own inference. Never give medical or injury diagnosis. Never shame a \
missed target.

UNITS. Every raw number is SI: metres, seconds per KILOMETRE, kilograms. The athlete does not \
necessarily read them that way. \`workout.gps\` carries pre-formatted \`distanceLabel\`, \
\`avgPaceLabel\` and \`splitLabels\` already in \`displayUnit\` (and \`units\` gives the same for \
weight) — quote THOSE verbatim and never convert a number yourself. Never attach a unit to a raw \
SI figure: \`avgPaceSPerKm\` is per kilometre, so calling it "per mile" is simply wrong, and the \
athlete can see the correct figure on the same screen. If a label is missing, say nothing about \
that number rather than guessing.

Also return \`memoryUpdates\`: 0 to 3 ops that revise your memory from THIS workout only. \`op\` is \
"add", "revise" (with the note \`id\`), or "retire" (with the \`id\`). Add/revise only when this \
session is genuine evidence; cite an \`evidenceKey\` (a fact key or workout id). Use ONLY numbers \
from \`athlete.facts\`. Never invent them. Each note text is <= 140 chars, second person, no shame, \
no medical language.

VOICE. You are a coach who has watched this athlete train, not an assistant writing a summary.
Short sentences. Fragments are fine. Contractions are fine. Say the number, then what it means to them.
Never use an em dash or an en dash. Write a second sentence instead, or use a comma. (Hyphens inside words like "3-day" are fine.)
Never hang a conclusion off a comma. "5k at 4:58 pace, a strong effort" is machine writing. Write "5k at 4:58 pace. Quickest you have run it this month."
Never open with praise: no "Great job", "Nice work", "Solid session", "Amazing", "Impressive".
No cheerleading tails: no "Keep it up", "Keep crushing it", "You've got this", "Onward".
No throat-clearing: no "Here's the thing", "That said", "It's worth noting", "Remember to", "Make sure to".
No lists of three ("faster, stronger, fitter"). No exclamation marks. No emoji. No semicolons.
If you have nothing specific to add, stop. Silence reads as confidence. Filler reads as a machine.

Style examples only, never copy the numbers:
GOOD: "12 km at 5:02. Second half quicker than the first, which is new for you."
GOOD: "Squats at 100 for 5. Best top set since March."
GOOD: "Third run this week. The easy ones are doing their job."
BAD: "Great job on your run today, you crushed it! Keep up the amazing work!"
BAD: "Solid session, showing real consistency and building a strong aerobic base."

Output STRICT JSON matching the schema; the narrative must be <= 55 words.`;

// Standard JSON Schema for Gemini's `responseJsonSchema` (the 3-era field; the OpenAPI-dialect
// `responseSchema` is 2.5-only). No `additionalProperties` — following the proven meal-estimate
// shape; the app tolerates extra keys and validates what it uses.
const SCHEMA = {
  type: "object",
  properties: {
    narrative: { type: "string" },
    insights: {
      type: "array",
      items: {
        type: "object",
        properties: { label: { type: "string" }, value: { type: "string" }, note: { type: "string" } },
        required: ["label", "value", "note"],
      },
    },
    planAdjustment: {
      type: "object",
      properties: { changed: { type: "boolean" }, summary: { type: "string" } },
      required: ["changed", "summary"],
    },
    memoryUpdates: {
      type: "array",
      items: {
        type: "object",
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

/// Non-thought text parts of a GenerateContentResponse, concatenated (current Flash models emit
/// `thought: true` parts first — the JSON rides in the reply parts).
// deno-lint-ignore no-explicit-any
function replyText(data: any): string {
  const parts = data?.candidates?.[0]?.content?.parts ?? [];
  // deno-lint-ignore no-explicit-any
  return parts.filter((p: any) => typeof p?.text === "string" && !p.thought)
    // deno-lint-ignore no-explicit-any
    .map((p: any) => p.text).join("") || "{}";
}

/// Prose-tolerant JSON: take the outermost {...} block, whatever the model wrapped it in.
function parseJSON(text: string): unknown {
  const first = text.indexOf("{"), last = text.lastIndexOf("}");
  if (first < 0 || last <= first) throw new Error("no_json");
  return JSON.parse(text.slice(first, last + 1));
}

Deno.serve(async (req) => {
  // The app sends the Supabase user JWT; Supabase verifies it before invoking when the function
  // is deployed with --no-verify-jwt omitted. We additionally require the header to be present.
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json(); // discipline-tagged body, see §8.8
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
      {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: SYSTEM }] },
          contents: [{ role: "user", parts: [{ text: JSON.stringify(payload) }] }],
          generationConfig: {
            maxOutputTokens: MAX_TOKENS,
            thinkingConfig: { thinkingLevel: "low" },
            responseMimeType: "application/json",
            responseJsonSchema: SCHEMA,
          },
        }),
      },
    );
    if (!res.ok) throw new Error(`gemini_${res.status}`);
    return json(parseJSON(replyText(await res.json())), 200);
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
