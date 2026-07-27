// Supabase Edge Function: coach-chat (PRD §4.7)
//
// The conversational coach. Given the chat history + a `context` object (training status, today's
// plan, the next 14 days of sessions with ids, race + feasibility, plan settings, adapt-lock state,
// the last workout, and long-term memory), returns ONE short reply as STRICT JSON — optionally
// carrying ONE `card`: a typed *proposal* (ease week, move a session, change the race…) that the
// app previews with the concrete diff and the athlete confirms. The model never applies anything
// and never computes loads/paces/volumes — the deterministic plan engine owns every number; the
// card only names an intent the app re-validates and executes ("rules compute, AI narrates").
//
// TRANSPORT. Two modes on one endpoint:
//   • JSON (default): one-shot `{reply, card}` — the original contract, kept for compatibility.
//   • SSE (request header `Accept: text/event-stream`): the reply streams as it's written —
//       event: delta   data: {"text":"..."}        (repeated; the reply, incrementally)
//       event: card    data: {<card object>}       (once, after the reply completes)
//       event: done    data: {}
//       event: error   data: {"message":"..."}     (client falls back to its local responder)
//     The model still emits strict JSON; the server extracts the "reply" string value token-by-token
//     so the client only ever sees clean text.
//
// The iOS app authenticates with the Supabase user JWT and falls back to the deterministic
// CoachResponder.swift whenever this is slow/down/unconfigured — so the chat never blocks.
//
// Deploy:  supabase functions deploy coach-chat
// Secrets: supabase secrets set GEMINI_API_KEY=AIza...   (server-only; NEVER in the app/git)
//          optional: AI_MODEL=gemini-flash-latest  AI_MAX_TOKENS=800
//          optional research: AI_WEB_SEARCH=1   (Google Search grounding; off by default)
// Eval:    node scripts/coach-chat-eval.mjs   (see the harness header)
//
// Model note (2026-07-16, user call): the coach runs on Gemini Flash — dramatically cheaper than
// any frontier tier, and the right fit because the coach only NARRATES short answers while the
// deterministic engines own every number ("rules compute, AI narrates"). The JSON output stays
// prompt-instructed (plus Gemini's JSON response mode), so the call remains model-agnostic —
// override with AI_MODEL to try another Gemini tier without touching code. Gemini specifics
// (conventions proven in meal-estimate): the default is the `gemini-flash-latest` rolling alias
// (2.5-flash is sunset for new keys); roles are "user"/"model" (not "assistant"); current Flash
// models THINK by default with thought tokens billed against maxOutputTokens — we pin thinking to
// its "low" floor ("none" isn't a valid ThinkingLevel) and budget headroom for it, and thought
// parts (`thought: true`) are filtered out of the reply text. Each turn stays fractions of a cent.

import { createClient } from "npm:@supabase/supabase-js@2";

const MODEL = Deno.env.get("AI_MODEL") ?? "gemini-flash-latest";
// Reply ≈ 150 tokens + card JSON; the rest is headroom for thinking, which bills against this cap.
// Deliberately roomy: pinning thinking to its "low" floor broke instruction-following on this
// 22-rule contract (wrong/missing cards, 300-word replies), so thinking runs at the model default
// and the budget must fit thought + reply. Still fractions of a cent on Flash.
const MAX_TOKENS = Number(Deno.env.get("AI_MAX_TOKENS") ?? "2048");
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? Deno.env.get("GOOGLE_API_KEY") ?? "";
const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

// Per-athlete DAILY cap (server-side; a client limit is trivially bypassed). Generous — far above
// real use — so it only ever stops abuse / a leaked token from running up the bill. Overridable via
// the AI_DAILY_LIMIT secret. Enforced by the `coach_rate_check` RPC (migration 20260714000001).
const DAILY_LIMIT = Number(Deno.env.get("AI_DAILY_LIMIT") ?? "60");

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// Increment the caller's daily counter and report whether they're within the cap. Runs the RPC with
// the caller's own JWT so `auth.uid()` keys signed-in athletes (unspoofable); guests fall back to the
// client IP. FAIL-OPEN: if the limiter itself errors (RPC not yet migrated, DB blip), we allow the
// request rather than break the coach — the cap re-engages the moment the check works again. The real
// abuse vector (one identity hammering) is caught whenever the RPC is live.
async function withinRateLimit(req: Request): Promise<boolean> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return true;   // unconfigured → don't block
  try {
    const auth = req.headers.get("authorization") ?? "";
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await supabase.rpc("coach_rate_check", {
      p_limit: DAILY_LIMIT,
      p_fallback_key: ip,
    });
    if (error) return true;                                // limiter broken → fail open
    const row = Array.isArray(data) ? data[0] : data;
    return row?.allowed !== false;                         // only an explicit false blocks
  } catch (_e) {
    return true;                                           // never let the limiter itself kill the coach
  }
}

// Optional web research — OFF by default so cost stays predictable. Set AI_WEB_SEARCH=1 to let the
// coach look up current facts (upcoming race dates, registration windows, qualifying times, course
// details) via Gemini's Google Search grounding. The app only ever escalates to this function for
// questions its offline coach can't answer, so a search runs only on the rare research turn.
// NOTE: grounding and JSON response mode don't combine — when search is on we rely on the
// prompt-instructed JSON + the tolerant parser below (same guarantee either way).
const WEB_SEARCH = (Deno.env.get("AI_WEB_SEARCH") ?? "") === "1";

const SYSTEM = `You are momentum's coach, in a chat with this athlete. You're given the recent \
conversation and a \`context\` object: their training status (acute:chronic load ratio and what it \
means), today's planned session, \`upcoming\` sessions for the next 14 days (each with an id), their \
\`race\` and \`feasibility\` read, plan \`settings\` (with the valid goalOptions/equipmentOptions), \
\`adaptLock\`, \`isPaused\`, \`injuryAreas\`, \`lastWorkout\`, \`memoryCategories\`, and your \
long-term \`memory\` (honor any note with \`pinned: true\` as ground truth).

Reply in ONE short, warm, specific message (<= 60 words, up to ~90 only when a factual/research \
answer genuinely needs it), second person. Ground every claim in the numbers from \`context\`. \
never invent data. The plan engine owns loads/paces/volumes; you narrate and advise within them, \
you do not compute new numbers. Be a no-shame coach: a missed or partial session just moves on. \
Never give medical or injury diagnosis. If asked to do something outside training, gently steer back.

WHY YOU'RE ANSWERING. The app answers everyday plan/training questions itself and only hands you \
the ones it couldn't. The deeper coaching questions (fueling nuance, the science of training, \
pacing strategy, gear, mindset) and requests to RESEARCH real-world facts (upcoming race dates, \
registration windows, qualifying standards, course profiles, weather). Answer these fully and \
expertly, like a seasoned running coach. This is exactly where you add value. If web search is \
available and the athlete asks about a specific race or a fact that changes over time, use it and \
cite the concrete answer (date, place, number); if it isn't available, give your best honest \
guidance and say when they should double-check the official race site. Still no invented specifics.

THE CARD. You may attach at most ONE card. A card is a PROPOSAL. The app shows the athlete the \
exact change and they confirm; you never apply anything. Rules:
- Set kind:"none" (label "") for a plain answer. Most turns are plain answers.
- Only propose a card when the athlete is asking for a change (or clearly needs one and you're \
offering it). Fill ONLY the parameters your kind needs.
- Echo ids and enum values VERBATIM from context: sessionId from upcoming[].id, goal from \
settings.goalOptions, equipment from settings.equipmentOptions, injuryArea from injuryAreas. Dates \
are "yyyy-MM-dd". Never invent an id.
- REQUIRED fields per kind. A card missing these is broken, and never use a placeholder like \
"undefined": moveSession needs sessionId AND newDateISO; skipSession needs sessionId; changeDays \
needs daysPerWeek; changeSessionLength needs sessionMinutes; changeGoal needs goal; changeEquipment \
needs equipment; changeRace needs raceName (or raceDistanceM + raceDateISO); injuryReport needs \
injuryArea; pausePlan needs pauseDays; rememberNote needs note + noteCategory; nav needs nav.
- If adaptLock.canAdaptLoad is false, do NOT propose easeWeek/bumpLoad. Explain in words that the \
plan was already adjusted (adaptLock.lastAdaptedAtISO) and one structural change a week keeps \
adaptation honest.
- Only propose bumpLoad when context.recommendation is "increase". A load raise must be earned.
- Before proposing changeRace, weigh context.feasibility and be honest when the timeline is tight \
or too short. Honesty beats hype.
- When the athlete names a real race (Boston, Chicago, Berlin, London, Tokyo, NYC Marathon or NYC \
Half, Great North Run, Peachtree, etc.), propose changeRace with \`raceName\` set to the race's \
common name. The app knows its distance and date, so DO NOT guess raceDistanceM/raceDateISO. Only \
use raceDistanceM + raceDateISO for a local/custom race not among the famous ones. If they want to \
race but haven't named one, offer kind:"nav" to planSettings, where they can search the race catalog.
- For pain/injury talk, propose injuryReport with the matching injuryArea; leave injurySeverity \
empty. The app asks the athlete directly. Say the red flags out loud (sharp pain, swelling, \
numbness → see a professional).
- kind:"nav" with the \`nav\` field steers the athlete somewhere useful (startToday, viewPlanWeek, \
viewProgress, raceBriefing, planSettings).
- When the athlete asks WHY their plan looks the way it does (why so easy, why these days, what's \
the reasoning), attach kind:"explainPlan". The app renders the full personalized breakdown from \
its own engine. Keep your reply to one warm sentence introducing it. Same pattern for \
kind:"weekRecap" (how was my week / weekly review), kind:"racePlan" (race pacing/strategy. \
only when context.race exists; otherwise suggest setting one up via nav planSettings), \
kind:"racePredictor" (what could I run/race right now, equivalent race times), \
kind:"todayBriefing" (what's on today / brief me, only when context.todayPlan exists), and \
kind:"zones" (heart rate zones / training paces).
- When the athlete tells you something to REMEMBER about them (preferences, habits, constraints), \
attach kind:"rememberNote" with \`note\` = the fact distilled to one clean sentence (<= 120 chars, \
their own framing, no medical content) and \`noteCategory\` from context.memoryCategories. The app \
confirms before keeping it. When they ask what you know/remember about them, attach kind:"memory".
- Use context.lastWorkout for debriefs. Cite its real numbers (distance, pace, splits, reps, RPE). \
Never debrief from imagination.
- context.fueling (when present) is today's readout from their meal journal: carbs vs the day's \
floor, protein/sodium/energy vs floors, and the session the carb target is keyed to. Use it for \
any eating or fueling question. Fueling language ONLY: floors that fund the work, never ceilings, \
deficits, diet, or weight talk. Absent means nothing logged today; mention the Fuel tab only if \
they ask about eating.
- Every change you propose is reversible: the athlete can undo an applied change from its receipt. \
Mention this only when they hesitate.
- label is the card's button text, <= 4 words, imperative ("Ease this week").

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

PLAIN TEXT ONLY: the app renders your \
reply literally, so no markdown, no asterisks, no bullet points, no headings, no emoji.

CARD SELECTION. Decide the kind FIRST from the athlete's ask, then write the reply:
- "too hard / too much / ease it off / easier week" → easeWeek (unless adaptLock.canAdaptLoad is \
false: then kind "none" and explain the weekly change budget in words).
- ANY body part hurting / pain / sore / aching → injuryReport with injuryArea matched from \
context.injuryAreas. Pain is never kind "none".
- "what do you know about me / what do you remember" → memory.
- "how was my week / week recap / weekly review" → weekRecap.
- "how am I doing (overall)" is a STATUS question → kind "none", answer in words from context. It \
is NOT weekRecap; weekRecap only reviews the week when they ask about their week.
- These kinds are RENDERED BY THE APP from its own engine. You must attach the card and keep your \
reply to ONE short introducing sentence (~12 words), never answer these in prose: \
"why is my plan built this way" → explainPlan; "what could I race/run right now / equivalent \
times" → racePredictor; "zones / training paces" → zones; "brief me on today" → todayBriefing \
(only if context.todayPlan exists); race pacing/strategy/how should I run my race, when \
context.race exists → racePlan. Answering these fully in prose without the card is a BROKEN reply.
- "I can only train N days" / "switch to N days a week" → changeDays with daysPerWeek: N.
- "remember that I …" → rememberNote. Travel / vacation / away next week → pausePlan with pauseDays.
- Otherwise, when no change is being asked for → kind "none". When in doubt between "none" and a \
card the athlete clearly asked for, attach the card.

Output STRICT JSON matching the schema, with "reply" FIRST.`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    reply: { type: "string" },
    // At most ONE optional proposal/nav card. kind:"none" for plain answers. The app re-validates
    // every parameter against the athlete's live plan and silently drops a broken card.
    card: {
      type: "object",
      additionalProperties: false,
      properties: {
        kind: {
          type: "string",
          enum: [
            "none", "nav",
            "changeGoal", "changeRace", "changeDays", "changeSessionLength",
            "moveSession", "skipSession",
            "easeWeek", "bumpLoad", "easePaces",
            "changeEquipment", "injuryReport", "pausePlan", "resumePlan",
            "explainPlan", "weekRecap", "racePlan", "memory", "rememberNote",
            "racePredictor", "todayBriefing", "zones",
          ],
        },
        label: { type: "string" },
        nav: {
          type: "string",
          enum: ["startToday", "viewPlanWeek", "viewProgress", "raceBriefing", "planSettings"],
        },
        goal: { type: "string" },              // from settings.goalOptions
        raceName: { type: "string" },          // changeRace: a named race ("Chicago Marathon", "NYC Half") — app resolves date+distance
        raceDistanceM: { type: "number" },     // changeRace fallback: only for a race NOT in the catalog
        raceDateISO: { type: "string" },       // "yyyy-MM-dd" (only with raceDistanceM, for custom races)
        goalFinishTimeS: { type: "number" },
        daysPerWeek: { type: "integer" },
        preferredDays: { type: "array", items: { type: "integer" } },   // 1=Sun … 7=Sat
        sessionMinutes: { type: "integer" },
        equipment: { type: "string" },         // from settings.equipmentOptions
        sessionId: { type: "string" },         // from upcoming[].id — never invented
        newDateISO: { type: "string" },
        injuryArea: { type: "string" },        // from injuryAreas
        injurySeverity: { type: "string" },    // twinge | moderate | severe (usually left empty)
        pauseDays: { type: "integer" },
        note: { type: "string" },              // rememberNote: the distilled fact, <= 120 chars
        noteCategory: { type: "string" },      // from memoryCategories
      },
      required: ["kind", "label"],
    },
  },
  required: ["reply", "card"],
};

// The card kinds, from the schema above (single source of truth) — named in the prompt so the model
// emits a valid kind without a provider-level response schema (our card shape is too rich for the
// strict schema modes; prompt-instructed JSON + the tolerant parser has proven reliable).
const CARD_KINDS = (SCHEMA.properties.card.properties.kind.enum as string[]).join(", ");

// Gemini's `responseJsonSchema` takes STANDARD JSON Schema but not `additionalProperties` —
// same dialect the proven meal-estimate call uses. Constraining the output structurally is what
// makes card selection reliable on Flash: `kind` becomes an enum the decoder enforces, instead of
// a convention the model may drift from.
// deno-lint-ignore no-explicit-any
const GEMINI_SCHEMA = JSON.parse(JSON.stringify(SCHEMA, (k: string, v: any) =>
  k === "additionalProperties" ? undefined : v));

/// Model output → object. We instruct strict JSON in the prompt (plus Gemini's JSON response mode
/// when search is off) and parse TOLERANTLY here: strip any stray ``` fence, take the outermost
/// {...}, and if that isn't valid JSON with a reply (the model sometimes just answers in prose) use
/// the whole text verbatim as the reply. This NEVER throws — the answer always lands. Escalation
/// turns are almost always plain Q&A, so the only thing a prose reply loses is a card, which those
/// turns rarely carry.
function parseModelJSON(text: string): { reply: string; card: unknown } {
  let t = text.trim();
  if (t.startsWith("```")) t = t.replace(/^```[a-z]*\s*/i, "").replace(/```\s*$/, "").trim();
  const first = t.indexOf("{"), last = t.lastIndexOf("}");
  if (first >= 0 && last > first) {
    try {
      const obj = JSON.parse(t.slice(first, last + 1));
      if (obj && typeof obj.reply === "string") {
        return { reply: obj.reply, card: obj.card ?? { kind: "none", label: "" } };
      }
    } catch (_e) { /* fall through to prose */ }
  }
  return { reply: t, card: { kind: "none", label: "" } };
}

/// Extract the (possibly incomplete) "reply" string value from a growing JSON buffer, un-escaping
/// as we go. Returns null until `"reply":"` has arrived. `done` flips at the closing quote.
function replySlice(buf: string): { text: string; done: boolean } | null {
  const key = buf.indexOf('"reply"');
  if (key < 0) return null;
  const colon = buf.indexOf(":", key + 7);
  if (colon < 0) return null;
  const open = buf.indexOf('"', colon + 1);
  if (open < 0) return null;
  let out = "", i = open + 1;
  while (i < buf.length) {
    const ch = buf[i];
    if (ch === "\\") {
      if (i + 1 >= buf.length) break;                       // incomplete escape — wait for more
      const n = buf[i + 1];
      if (n === "n") out += "\n";
      else if (n === "t") out += "\t";
      else if (n === "u") {
        if (i + 5 >= buf.length) break;
        out += String.fromCharCode(parseInt(buf.slice(i + 2, i + 6), 16));
        i += 4;
      } else out += n;                                       // \" \\ \/ …
      i += 2;
      continue;
    }
    if (ch === '"') return { text: out, done: true };
    out += ch;
    i++;
  }
  return { text: out, done: false };
}

/// The Gemini request body. Roles map user→"user", assistant→"model"; the system prompt (with the
/// output contract + the athlete's context) rides in systemInstruction. Thinking is pinned to its
/// "low" floor — narration needs no chain of thought (the engines compute), and thought tokens
/// bill against maxOutputTokens ("none" is not a valid ThinkingLevel on this generation).
function requestBody(payload: { messages?: { role: string; text: string }[]; context?: unknown }) {
  const history = (payload.messages ?? []).map((m) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: [{ text: m.text }],
  }));
  // Gemini expects the FIRST content to be a user turn. A real chat thread usually opens with the
  // coach's welcome (a model message) and can carry proactive seeds, so drop any leading model turns.
  while (history.length && history[0].role !== "user") history.shift();
  const system = SYSTEM +
    "\n\nOUTPUT: reply with ONLY a JSON object (no code fences, no text around it), \"reply\" first:\n" +
    "{\"reply\": \"<your message>\", \"card\": {\"kind\": \"none\", \"label\": \"\"}}\n" +
    "card.kind must be exactly one of: " + CARD_KINDS + ". Include ONLY the extra fields that kind needs.\n\n" +
    "CONTEXT:\n" + JSON.stringify(payload.context ?? {});
  return {
    systemInstruction: { parts: [{ text: system }] },
    contents: history.length ? history : [{ role: "user", parts: [{ text: "Hello" }] }],
    generationConfig: {
      maxOutputTokens: MAX_TOKENS,
      // Deterministic card selection: Gemini's default temperature (1.0) made the SAME ask flip
      // between kind "none" and the right card across runs. The prompt supplies all the warmth the
      // short reply needs; the contract needs repeatability. (No thinkingConfig: the default level
      // is required for this contract — see the MAX_TOKENS note.)
      temperature: 0,
      // Structured output pins the shape (kind enum + required card) — but it can't combine with
      // search grounding, so research mode falls back to prompt-instructed JSON + tolerant parsing.
      ...(WEB_SEARCH ? {} : {
        responseMimeType: "application/json",
        responseJsonSchema: GEMINI_SCHEMA,
      }),
    },
    ...(WEB_SEARCH ? { tools: [{ google_search: {} }] } : {}),
  };
}

/// All REPLY text parts of a (possibly partial) GenerateContentResponse chunk, concatenated.
/// Thought parts (`thought: true` — the current Flash generation streams them first) are filtered
/// out, or they'd pollute the incremental reply extraction with chain-of-thought text.
// deno-lint-ignore no-explicit-any
function chunkText(chunk: any): string {
  const parts = chunk?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return "";
  // deno-lint-ignore no-explicit-any
  return parts.filter((p: any) => typeof p?.text === "string" && !p.thought)
    // deno-lint-ignore no-explicit-any
    .map((p: any) => p.text).join("");
}

function geminiURL(mode: "generateContent" | "streamGenerateContent"): string {
  const stream = mode === "streamGenerateContent" ? "?alt=sse" : "";
  return `${GEMINI_BASE}/${MODEL}:${mode}${stream}`;
}

const GEMINI_HEADERS = {
  "content-type": "application/json",
  "x-goog-api-key": GEMINI_API_KEY,   // header, not query param — keeps the key out of URLs/logs
};

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  const wantsStream = (req.headers.get("accept") ?? "").includes("text/event-stream");
  let payload: { messages?: { role: string; text: string }[]; context?: unknown };
  try {
    payload = await req.json();
  } catch (_e) {
    return json({ error: "bad_request" }, 400);
  }

  // Daily cap, checked BEFORE any Gemini call so an over-limit request costs nothing. 429 →
  // the app falls back to its offline coach (non-200 is already its fallback trigger), so the
  // athlete still gets an answer — just the free deterministic one for the rest of the day.
  if (!(await withinRateLimit(req))) {
    return json({ error: "rate_limited" }, 429);
  }

  // One-shot JSON (the original contract) — also the fallback for older clients.
  if (!wantsStream) {
    try {
      const res = await fetch(geminiURL("generateContent"), {
        method: "POST",
        headers: GEMINI_HEADERS,
        body: JSON.stringify(requestBody(payload)),
      });
      if (!res.ok) throw new Error(`gemini_${res.status}`);
      const text = chunkText(await res.json());
      return json(parseModelJSON(text || "{}"), 200);
    } catch (_e) {
      // The client renders its deterministic CoachResponder on any non-200 — never block.
      return json({ error: "coach_unavailable" }, 503);
    }
  }

  // SSE — stream the reply as it's written, then the card. Gemini's alt=sse emits `data: {...}`
  // chunks (one JSON GenerateContentResponse per line); we re-emit the app's own event contract.
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      const send = (event: string, data: unknown) =>
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      let buf = "";
      let emitted = 0;
      try {
        const res = await fetch(geminiURL("streamGenerateContent"), {
          method: "POST",
          headers: GEMINI_HEADERS,
          body: JSON.stringify(requestBody(payload)),
        });
        if (!res.ok || !res.body) throw new Error(`gemini_${res.status}`);
        const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
        let sse = "";
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          sse += value;
          // Complete lines only — each `data:` line is one self-contained JSON chunk.
          let nl: number;
          while ((nl = sse.indexOf("\n")) >= 0) {
            const line = sse.slice(0, nl).trim();
            sse = sse.slice(nl + 1);
            if (!line.startsWith("data:")) continue;
            const raw = line.slice(5).trim();
            if (!raw || raw === "[DONE]") continue;
            try {
              buf += chunkText(JSON.parse(raw));
            } catch (_e) { /* partial/keepalive line — skip */ }
            const slice = replySlice(buf);
            if (slice && slice.text.length > emitted) {
              send("delta", { text: slice.text.slice(emitted) });
              emitted = slice.text.length;
            }
          }
        }
        const parsed = parseModelJSON(buf || "{}");
        // Anything the incremental extractor missed (e.g. a trailing escape) goes out now.
        if (typeof parsed.reply === "string" && parsed.reply.length > emitted) {
          send("delta", { text: parsed.reply.slice(emitted) });
        }
        send("card", parsed.card ?? { kind: "none", label: "" });
        send("done", {});
      } catch (e) {
        send("error", { message: e instanceof Error ? e.message : "coach_unavailable" });
      } finally {
        controller.close();
      }
    },
  });
  return new Response(body, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    },
  });
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
