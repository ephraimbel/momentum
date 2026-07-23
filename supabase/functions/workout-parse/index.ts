// Supabase Edge Function: workout-parse (offline-log composer, 2026-07-22)
//
// Given the athlete's own plain-English account of a workout they already did ("did chest and tris,
// worked up to 225 on bench for 3, then 20 easy minutes on the bike"), returns the STRUCTURED
// fields of that workout as STRICT JSON — sport, duration, distance, effort, when, and exercise
// set lines. Extraction ONLY: it never invents a number the athlete didn't say or clearly imply.
// The iOS app renders the result as a receipt the athlete confirms before anything saves, clamps
// every number deterministically on-device, and its local grammar (WorkoutLogParser) fills any
// field this parse leaves empty — a log NEVER blocks on this function.
//
// Rate limit: shares the fuel_rate_check daily bucket (abuse guard only — an honest day is a
// handful of logs + meals, nowhere near the cap). Over-limit or offline, the local grammar's
// receipt stands and manual entry is always available.
//
// Provider: Gemini Flash primary, Claude Haiku fallback — the meal-estimate ladder, same secrets.
//
// Deploy:  supabase functions deploy workout-parse
// Secrets: GEMINI_API_KEY (primary), ANTHROPIC_API_KEY (fallback) — both already set

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";
import { createClient } from "npm:@supabase/supabase-js@2";

const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const GEMINI_MODEL = Deno.env.get("WORKOUT_PARSE_MODEL") ?? "gemini-flash-latest";
const FALLBACK_MODEL = Deno.env.get("WORKOUT_PARSE_FALLBACK_MODEL") ?? "claude-haiku-4-5-20251001";
const MAX_TOKENS = Number(Deno.env.get("WORKOUT_PARSE_MAX_TOKENS") ?? "1200");
const DAILY_LIMIT = Number(Deno.env.get("MEAL_DAILY_LIMIT") ?? "60");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// FAIL-OPEN like the other limiters: a DB blip must not cost the athlete a parse.
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

const SPORTS = [
  "run", "trailRun", "walk", "hike",
  "ride", "mountainBikeRide", "gravelRide", "eBikeRide",
  "strength", "crossfit", "hiit",
  "tennis", "soccer", "basketball", "golf",
  "yoga", "pilates", "swimming", "rowing", "other",
];

const SYSTEM = `You read an endurance athlete's own plain-English account of ONE workout they \
already finished and extract its structured fields. EXTRACTION ONLY: never invent a number the \
athlete did not say or clearly imply. Use empty string / 0 for anything not stated.

Fields:
- type: the sport, one of exactly: ${SPORTS.join(", ")}. The FIRST workout described is the one \
being logged (a "then a quick bike" after a lift is a footnote, not the workout). Gym/weights/named \
lifts mean "strength". Empty string only if no sport is discernible.
- indoor: true for treadmill, trainer, spin/peloton, indoor pool.
- duration_s: total duration in SECONDS ("45 min" = 2700, "about an hour and a half" = 5400). \
0 if unstated. If they list segment durations for one workout, sum them.
- distance_m: total distance in METERS ("5 miles" = 8047, "10k" = 10000, "half marathon" = 21097). \
0 if unstated. Never derive distance from duration or vice versa.
- effort: perceived effort 1-10 mapped from their words (easy/recovery 2, steady 4, moderate 5, \
hard 8, brutal/all-out 9-10). 0 if they said nothing about how it felt.
- day_offset: 0 for today, -1 for yesterday, -2 for two days ago, etc. Default 0.
- time_of_day: "morning", "afternoon", "evening", or "" if unstated ("last night" = evening).
- exercises (strength only, else empty array): one entry PER EXERCISE in the order performed. \
name short and title-case ("Bench Press"). sets and reps as stated ("worked up to 225 for 3" = \
1 top set of 3 unless more sets are described; "4x8" = 4 sets of 8; "3 sets of 10-12" = 3 sets, \
use 10). weight_kg in KILOGRAMS — convert from pounds when their units say so (context gives the \
athlete's default unit for bare numbers; 185 with default "lb" = 83.9). 0 for bodyweight. If they \
name an exercise with no numbers, include it with sets 1, reps 0, weight_kg 0.
- confidence: 0-1, how completely the text described the workout.

The context object gives default units for bare numbers: weight_unit ("lb" or "kg") and \
distance_unit ("mi" or "km"). An explicit unit in the text always wins over the default.

Output STRICT JSON matching the schema.`;

const ANTHROPIC_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    type: { type: "string" },
    indoor: { type: "boolean" },
    duration_s: { type: "number" },
    distance_m: { type: "number" },
    effort: { type: "integer" },
    day_offset: { type: "integer" },
    time_of_day: { type: "string" },
    exercises: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          name: { type: "string" },
          sets: { type: "integer" },
          reps: { type: "integer" },
          weight_kg: { type: "number" },
        },
        required: ["name", "sets", "reps", "weight_kg"],
      },
    },
    confidence: { type: "number" },
  },
  required: ["type", "indoor", "duration_s", "distance_m", "effort", "day_offset", "time_of_day",
             "exercises", "confidence"],
};

async function parseWithGemini(userJSON: string): Promise<unknown> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: SYSTEM }] },
      contents: [{ role: "user", parts: [{ text: userJSON }] }],
      generationConfig: {
        maxOutputTokens: MAX_TOKENS,
        thinkingConfig: { thinkingLevel: "low" },
        responseMimeType: "application/json",
        responseJsonSchema: {
          type: "object",
          properties: {
            type: { type: "string" },
            indoor: { type: "boolean" },
            duration_s: { type: "number" },
            distance_m: { type: "number" },
            effort: { type: "integer" },
            day_offset: { type: "integer" },
            time_of_day: { type: "string" },
            exercises: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  sets: { type: "integer" },
                  reps: { type: "integer" },
                  weight_kg: { type: "number" },
                },
                required: ["name", "sets", "reps", "weight_kg"],
              },
            },
            confidence: { type: "number" },
          },
          required: ["type", "indoor", "duration_s", "distance_m", "effort", "day_offset",
                     "time_of_day", "exercises", "confidence"],
        },
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const data = await res.json();
  const parts = data?.candidates?.[0]?.content?.parts ?? [];
  const text = parts.filter((p: { text?: string; thought?: boolean }) => p.text && !p.thought)
    .map((p: { text?: string }) => p.text).join("") || "{}";
  const start = text.indexOf("{"), end = text.lastIndexOf("}");
  const jsonText = start >= 0 && end > start ? text.slice(start, end + 1) : "{}";
  return JSON.parse(jsonText);
}

async function parseWithClaude(userJSON: string): Promise<unknown> {
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
    const payload = await req.json(); // { text, context?: { weight_unit?, distance_unit? } }
    const text = String(payload.text ?? "").slice(0, 800);
    if (!text) return json({ error: "empty" }, 400);
    if (!(await withinRateLimit(req))) {
      return json({ error: "rate_limited" }, 429);
    }
    const userJSON = JSON.stringify({ workout: text, context: payload.context ?? {} });

    if (GEMINI_KEY) {
      try {
        const out = await parseWithGemini(userJSON) as Record<string, unknown>;
        return json({ ...out, provider: "gemini" }, 200);
      } catch (_g) {
        // fall through — a transient Gemini error must never cost the athlete a parse
      }
    }
    const out = await parseWithClaude(userJSON) as Record<string, unknown>;
    return json({ ...out, provider: "claude" }, 200);
  } catch (_e) {
    // The app's local grammar receipt stands; manual entry is always available.
    return json({ error: "parse_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
