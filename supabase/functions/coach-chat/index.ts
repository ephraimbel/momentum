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
// Secrets: supabase secrets set ANTHROPIC_API_KEY=sk-ant-...   (server-only; NEVER in the app/git)
//          optional: AI_MODEL=claude-opus-4-8  AI_MAX_TOKENS=500
//          optional research: AI_WEB_SEARCH=1  AI_WEB_SEARCH_MAX_USES=3   (off by default)
// Eval:    node scripts/coach-chat-eval.mjs   (see the harness header)
//
// Model note: AI_MODEL defaults to claude-opus-4-8. Opus 4.8 REMOVES `temperature`/`top_p`/`top_k`
// (sending them 400s), so we don't set them — output shape is constrained via structured outputs.

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";

const MODEL = Deno.env.get("AI_MODEL") ?? "claude-opus-4-8";
const MAX_TOKENS = Number(Deno.env.get("AI_MAX_TOKENS") ?? "500");

const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

// Optional web research — OFF by default so cost stays predictable. Set AI_WEB_SEARCH=1 to let the
// coach look up current facts (upcoming race dates, registration windows, qualifying times, course
// details) via Anthropic's server-side web search, capped at AI_WEB_SEARCH_MAX_USES lookups/reply.
// The app only ever escalates to this function for questions its offline coach can't answer, so a
// search runs only on the rare research turn — never on the everyday plan/training questions.
const WEB_SEARCH = (Deno.env.get("AI_WEB_SEARCH") ?? "") === "1";
const WEB_SEARCH_MAX_USES = Number(Deno.env.get("AI_WEB_SEARCH_MAX_USES") ?? "3");
const TOOLS = WEB_SEARCH
  ? [{ type: "web_search_20250305" as const, name: "web_search" as const, max_uses: WEB_SEARCH_MAX_USES }]
  : undefined;

const SYSTEM = `You are momentum's coach, in a chat with this athlete. You're given the recent \
conversation and a \`context\` object: their training status (acute:chronic load ratio and what it \
means), today's planned session, \`upcoming\` sessions for the next 14 days (each with an id), their \
\`race\` and \`feasibility\` read, plan \`settings\` (with the valid goalOptions/equipmentOptions), \
\`adaptLock\`, \`isPaused\`, \`injuryAreas\`, \`lastWorkout\`, \`memoryCategories\`, and your \
long-term \`memory\` (honor any note with \`pinned: true\` as ground truth).

Reply in ONE short, warm, specific message (<= 60 words, up to ~90 only when a factual/research \
answer genuinely needs it), second person. Ground every claim in the numbers from \`context\` — \
never invent data. The plan engine owns loads/paces/volumes; you narrate and advise within them, \
you do not compute new numbers. Be a no-shame coach: a missed or partial session just moves on. \
Never give medical or injury diagnosis. If asked to do something outside training, gently steer back.

WHY YOU'RE ANSWERING. The app answers everyday plan/training questions itself and only hands you \
the ones it couldn't — the deeper coaching questions (fueling nuance, the science of training, \
pacing strategy, gear, mindset) and requests to RESEARCH real-world facts (upcoming race dates, \
registration windows, qualifying standards, course profiles, weather). Answer these fully and \
expertly, like a seasoned running coach — this is exactly where you add value. If web search is \
available and the athlete asks about a specific race or a fact that changes over time, use it and \
cite the concrete answer (date, place, number); if it isn't available, give your best honest \
guidance and say when they should double-check the official race site. Still no invented specifics.

THE CARD. You may attach at most ONE card. A card is a PROPOSAL — the app shows the athlete the \
exact change and they confirm; you never apply anything. Rules:
- Set kind:"none" (label "") for a plain answer. Most turns are plain answers.
- Only propose a card when the athlete is asking for a change (or clearly needs one and you're \
offering it). Fill ONLY the parameters your kind needs.
- Echo ids and enum values VERBATIM from context: sessionId from upcoming[].id, goal from \
settings.goalOptions, equipment from settings.equipmentOptions, injuryArea from injuryAreas. Dates \
are "yyyy-MM-dd". Never invent an id.
- REQUIRED fields per kind — a card missing these is broken, and never use a placeholder like \
"undefined": moveSession needs sessionId AND newDateISO; skipSession needs sessionId; changeDays \
needs daysPerWeek; changeSessionLength needs sessionMinutes; changeGoal needs goal; changeEquipment \
needs equipment; changeRace needs raceName (or raceDistanceM + raceDateISO); injuryReport needs \
injuryArea; pausePlan needs pauseDays; rememberNote needs note + noteCategory; nav needs nav.
- If adaptLock.canAdaptLoad is false, do NOT propose easeWeek/bumpLoad — explain in words that the \
plan was already adjusted (adaptLock.lastAdaptedAtISO) and one structural change a week keeps \
adaptation honest.
- Only propose bumpLoad when context.recommendation is "increase" — a load raise must be earned.
- Before proposing changeRace, weigh context.feasibility and be honest when the timeline is tight \
or too short. Honesty beats hype.
- When the athlete names a real race (Boston, Chicago, Berlin, London, Tokyo, NYC Marathon or NYC \
Half, Great North Run, Peachtree, etc.), propose changeRace with \`raceName\` set to the race's \
common name — the app knows its distance and date, so DO NOT guess raceDistanceM/raceDateISO. Only \
use raceDistanceM + raceDateISO for a local/custom race not among the famous ones. If they want to \
race but haven't named one, offer kind:"nav" to planSettings, where they can search the race catalog.
- For pain/injury talk, propose injuryReport with the matching injuryArea; leave injurySeverity \
empty — the app asks the athlete directly. Say the red flags out loud (sharp pain, swelling, \
numbness → see a professional).
- kind:"nav" with the \`nav\` field steers the athlete somewhere useful (startToday, viewPlanWeek, \
viewProgress, raceBriefing, planSettings).
- When the athlete asks WHY their plan looks the way it does (why so easy, why these days, what's \
the reasoning), attach kind:"explainPlan" — the app renders the full personalized breakdown from \
its own engine. Keep your reply to one warm sentence introducing it. Same pattern for \
kind:"weekRecap" (how was my week / weekly review), kind:"racePlan" (race pacing/strategy — \
only when context.race exists; otherwise suggest setting one up via nav planSettings), \
kind:"racePredictor" (what could I run/race right now — equivalent race times), \
kind:"todayBriefing" (what's on today / brief me — only when context.todayPlan exists), and \
kind:"zones" (heart rate zones / training paces).
- When the athlete tells you something to REMEMBER about them (preferences, habits, constraints), \
attach kind:"rememberNote" with \`note\` = the fact distilled to one clean sentence (<= 120 chars, \
their own framing, no medical content) and \`noteCategory\` from context.memoryCategories. The app \
confirms before keeping it. When they ask what you know/remember about them, attach kind:"memory".
- Use context.lastWorkout for debriefs — cite its real numbers (distance, pace, splits, reps, RPE). \
Never debrief from imagination.
- context.fueling (when present) is today's readout from their meal journal: carbs vs the day's \
floor, protein/sodium/energy vs floors, and the session the carb target is keyed to. Use it for \
any eating or fueling question. Fueling language ONLY: floors that fund the work, never ceilings, \
deficits, diet, or weight talk. Absent means nothing logged today; mention the Fuel tab only if \
they ask about eating.
- Every change you propose is reversible: the athlete can undo an applied change from its receipt. \
Mention this only when they hesitate.
- label is the card's button text, <= 4 words, imperative ("Ease this week").

Write like a person, not a chatbot: never use em dashes or en dashes (— –) — use periods and \
commas. (Hyphens in compound words like "3-day" are fine.) PLAIN TEXT ONLY: the app renders your \
reply literally, so no markdown, no asterisks, no bullet points, no headings, no emoji.

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
// emits a valid kind without the API-level json_schema (which rejects this card shape as too complex).
const CARD_KINDS = (SCHEMA.properties.card.properties.kind.enum as string[]).join(", ");

/// Model output → object. Structured outputs are OFF (our card schema exceeds the API's json_schema
/// complexity limit — "Schema is too complex"), so we instruct strict JSON in the prompt and parse
/// TOLERANTLY here: strip any stray ``` fence, take the outermost {...}, and if that isn't valid JSON
/// with a reply (the model sometimes just answers in prose) use the whole text verbatim as the reply.
/// This NEVER throws — the answer always lands. Escalation turns are almost always plain Q&A, so the
/// only thing a prose reply loses is a card, which those turns rarely carry.
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

function requestParams(payload: { messages?: { role: string; text: string }[]; context?: unknown }) {
  const history = (payload.messages ?? []).map((m) => ({
    role: m.role === "assistant" ? "assistant" as const : "user" as const,
    content: m.text,
  }));
  // The Anthropic API requires the FIRST message to be a user turn. A real chat thread usually opens
  // with the coach's welcome (an assistant message) and can carry proactive assistant seeds, so drop
  // any leading assistant turns — otherwise every call 400s and the app silently falls back offline.
  while (history.length && history[0].role !== "user") history.shift();
  return {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    system: SYSTEM +
      "\n\nOUTPUT: reply with ONLY a JSON object (no code fences, no text around it), \"reply\" first:\n" +
      "{\"reply\": \"<your message>\", \"card\": {\"kind\": \"none\", \"label\": \"\"}}\n" +
      "card.kind must be exactly one of: " + CARD_KINDS + ". Include ONLY the extra fields that kind needs.\n\n" +
      "CONTEXT:\n" + JSON.stringify(payload.context ?? {}),
    // Server-side web search, only when enabled (see TOOLS). The model decides whether a turn needs
    // it; most don't. Results feed the reply, which the model still returns as the JSON above.
    ...(TOOLS ? { tools: TOOLS } : {}),
    messages: history.length ? history : [{ role: "user" as const, content: "Hello" }],
  };
}

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

  // One-shot JSON (the original contract) — also the fallback for older clients.
  if (!wantsStream) {
    try {
      const message = await client.messages.create(requestParams(payload));
      const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
      return json(parseModelJSON(text), 200);
    } catch (_e) {
      // The client renders its deterministic CoachResponder on any non-200 — never block.
      return json({ error: "coach_unavailable" }, 503);
    }
  }

  // SSE — stream the reply as it's written, then the card.
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      const send = (event: string, data: unknown) =>
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      let buf = "";
      let emitted = 0;
      try {
        const stream = client.messages.stream(requestParams(payload));
        for await (const event of stream) {
          if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
            buf += event.delta.text;
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
