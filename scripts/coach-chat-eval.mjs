#!/usr/bin/env node
// Eval harness for the coach-chat Edge Function (the LLM half of the coach).
//
// The iOS client re-validates every card, so a misbehaving model is SAFE — but it can be silently
// degraded (cards dropped, ids invented, rules ignored). This harness proves the live model actually
// follows the contract: right card kind per ask, ids echoed verbatim from context, adapt-lock and
// earned-bump rules respected, replies short and dash-free.
//
// Run against the DEPLOYED function:
//   supabase functions deploy coach-chat                # once, from an account with project access
//   EVAL_URL="https://<ref>.supabase.co/functions/v1/coach-chat" \
//   EVAL_BEARER="<anon or service key>" node scripts/coach-chat-eval.mjs
//
// Or against a LOCAL serve (needs Docker + ANTHROPIC_API_KEY):
//   supabase functions serve coach-chat --env-file supabase/.env.local
//   EVAL_URL="http://127.0.0.1:54321/functions/v1/coach-chat" EVAL_BEARER="dev" node scripts/coach-chat-eval.mjs
//
// Self-test (no network — verifies the assertions themselves):
//   node scripts/coach-chat-eval.mjs --mock

const MOCK = process.argv.includes("--mock");
const URL_ = process.env.EVAL_URL;
const BEARER = process.env.EVAL_BEARER;
if (!MOCK && (!URL_ || !BEARER)) {
  console.error("Set EVAL_URL and EVAL_BEARER, or run with --mock. See header for instructions.");
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Fixture context — a realistic athlete. Mirrors the iOS ContextDTO field-for-field.
// ---------------------------------------------------------------------------

const SESSION_IDS = [
  "0A6E2E9B-1111-4A62-9C01-000000000001",
  "0A6E2E9B-1111-4A62-9C01-000000000002",
  "0A6E2E9B-1111-4A62-9C01-000000000003",
];

function isoInDays(n) {
  const d = new Date(Date.now() + n * 86400_000);
  return d.toISOString().slice(0, 10);
}
function weekdayInDays(n) {
  return new Date(Date.now() + n * 86400_000).toLocaleDateString("en-US", { weekday: "long" });
}

const BASE_CONTEXT = {
  status: "Building",
  recommendation: "hold",
  acwr: 1.05,
  loadTrendPct: 4,
  distanceTrendPct: 6,
  streak: 9,
  goal: "raceDistance",
  disciplines: ["running"],
  todayPlan: "Easy 8 km ~5:40 /km",
  memory: ["Prefers morning runs", "Hates treadmills"],
  preferredSessionMinutes: 55,
  topDiscipline: "Run",
  overreachACWR: 1.4,
  paceAtEffortTrendPct: -3,
  upcoming: [
    { id: SESSION_IDS[0], dateISO: isoInDays(1), weekday: weekdayInDays(1), brief: "Easy 8 km ~5:40 /km", discipline: "running", status: "planned" },
    { id: SESSION_IDS[1], dateISO: isoInDays(2), weekday: weekdayInDays(2), brief: "Tempo 6 km ~4:50 /km", discipline: "running", status: "planned" },
    { id: SESSION_IDS[2], dateISO: isoInDays(4), weekday: weekdayInDays(4), brief: "Long 16 km ~5:55 /km", discipline: "running", status: "planned" },
  ],
  race: { dateISO: isoInDays(42), distanceM: 21097.5, goalFinishTimeS: 6600, weeksOut: 6 },
  settings: {
    daysPerWeek: 4, sessionMinutes: 60, equipment: "fullGym", preferredDays: [2, 4, 6, 7],
    planIntensity: "balanced",
    goalOptions: ["loseFat", "buildMuscle", "getStronger", "raceDistance", "endurance", "generalFitness", "stayConsistent"],
    equipmentOptions: ["fullGym", "dumbbellsOnly", "homeMinimal", "bodyweight"],
  },
  feasibility: { verdict: "onTrack", headline: "You're on track", weeksAvailable: 6, weeksNeeded: 5 },
  adaptLock: { lastAdaptedAtISO: null, canAdaptLoad: true },
  isPaused: false,
  activeInjuryArea: null,
  injuryAreas: ["shins", "knee", "itBand", "ankle", "achilles", "foot", "calf", "hamstring", "hip", "back"],
  lastWorkout: {
    dateISO: isoInDays(0), type: "Run", distanceM: 8100, durationS: 2750,
    avgPaceSPerKm: 340, avgHR: 152, rpe: 6, plannedBrief: "Easy 8 km ~5:40 /km",
    splitNote: "negative split, second half 5 s/km quicker", repsNote: null,
  },
  memoryCategories: ["habit", "preference", "response", "motivation", "risk", "identity"],
};

const VALID_KINDS = new Set([
  "none", "nav", "changeGoal", "changeRace", "changeDays", "changeSessionLength",
  "moveSession", "skipSession", "easeWeek", "bumpLoad", "easePaces",
  "changeEquipment", "injuryReport", "pausePlan", "resumePlan",
  "explainPlan", "weekRecap", "racePlan", "memory", "rememberNote",
  "racePredictor", "todayBriefing", "zones",
]);

// ---------------------------------------------------------------------------
// Cases — {name, message, patch(context), checks(reply, card) -> [failures]}
// ---------------------------------------------------------------------------

const kindIs = (...ok) => (r, card) =>
  ok.includes(card?.kind) ? [] : [`expected kind ∈ [${ok}], got "${card?.kind}"`];

const CASES = [
  {
    name: "plain question stays cardless",
    message: "How am I doing overall?",
    checks: [kindIs("none")],
  },
  {
    name: "ease ask proposes easeWeek",
    message: "This week feels way too hard, can we ease it off?",
    checks: [kindIs("easeWeek")],
  },
  {
    name: "adapt-lock blocks easeWeek, explained in words",
    message: "This week feels way too hard, can we ease it off?",
    patch: (c) => { c.adaptLock = { lastAdaptedAtISO: isoInDays(-2), canAdaptLoad: false }; },
    checks: [
      kindIs("none", "nav"),
      (r) => /week|adjust|recent/i.test(r) ? [] : ["reply should explain the once-a-week rule"],
    ],
  },
  {
    name: "move session echoes a real id",
    message: `Can you move ${weekdayInDays(2)}'s tempo to ${weekdayInDays(5)}?`,
    checks: [
      kindIs("moveSession"),
      (r, card) => SESSION_IDS.includes(card?.sessionId) ? [] : [`sessionId "${card?.sessionId}" not from context.upcoming`],
      (r, card) => /^\d{4}-\d{2}-\d{2}$/.test(card?.newDateISO ?? "") ? [] : [`newDateISO "${card?.newDateISO}" malformed`],
    ],
  },
  {
    name: "days change carries the number",
    message: "I can only train 3 days a week from now on.",
    checks: [
      kindIs("changeDays"),
      (r, card) => card?.daysPerWeek === 3 ? [] : [`daysPerWeek should be 3, got ${card?.daysPerWeek}`],
    ],
  },
  {
    name: "injury report names the area, leaves severity to the app",
    message: "My shin has been hurting on runs lately.",
    checks: [
      kindIs("injuryReport"),
      (r, card) => card?.injuryArea === "shins" ? [] : [`injuryArea should be "shins", got "${card?.injuryArea}"`],
      (r, card) => !card?.injurySeverity ? [] : ["injurySeverity should be left empty (the app asks)"],
    ],
  },
  {
    name: "remember distills a note",
    message: "Please remember that I really hate treadmill running.",
    checks: [
      kindIs("rememberNote"),
      (r, card) => /treadmill/i.test(card?.note ?? "") ? [] : [`note "${card?.note}" lost the fact`],
      (r, card) => (card?.note ?? "").length <= 160 ? [] : ["note too long"],
    ],
  },
  {
    name: "memory ask renders the memory card",
    message: "What do you know about me?",
    checks: [kindIs("memory")],
  },
  {
    name: "why-my-plan renders the explainer",
    message: "Why is my plan built this way?",
    checks: [kindIs("explainPlan")],
  },
  {
    name: "week ask renders the recap",
    message: "How was my week?",
    checks: [kindIs("weekRecap")],
  },
  {
    name: "race pacing with a race set",
    message: "How should I pace my race?",
    checks: [kindIs("racePlan")],
  },
  {
    name: "race pacing with no race steers to setup",
    message: "How should I pace my race?",
    patch: (c) => { c.race = null; },
    checks: [
      (r, card) => card?.kind !== "racePlan" ? [] : ["must not build a race plan without a race"],
      (r, card) => card?.kind !== "nav" || card?.nav === "planSettings" ? [] : [`nav should be planSettings, got "${card?.nav}"`],
    ],
  },
  {
    name: "vacation proposes a pause",
    message: "I'm traveling for work all of next week, no running possible.",
    checks: [kindIs("pausePlan")],
  },
  {
    name: "unearned bump is refused in words",
    message: "Bump my volume up, I want to train harder.",
    patch: (c) => { c.recommendation = "hold"; },
    checks: [
      (r, card) => card?.kind !== "bumpLoad" ? [] : ["bumpLoad requires recommendation=increase"],
    ],
  },
  {
    name: "predictor ask renders the predictor card",
    message: "What could I race right now?",
    checks: [kindIs("racePredictor")],
  },
  {
    name: "zones ask renders the zones card",
    message: "What are my heart rate zones?",
    checks: [kindIs("zones")],
  },
  {
    name: "today ask renders the briefing card",
    message: "Brief me on today's session.",
    checks: [kindIs("todayBriefing")],
  },
  {
    name: "debrief cites the real workout",
    message: "How did my run today go?",
    checks: [
      kindIs("none"),
      (r) => /8|split|5:4|152|negative/i.test(r) ? [] : ["debrief should cite numbers from context.lastWorkout"],
    ],
  },
];

// Universal hygiene checks applied to every case.
const UNIVERSAL = [
  (r) => !/[—–]/.test(r) ? [] : ["reply contains an em/en dash"],
  (r) => r.trim().split(/\s+/).length <= 75 ? [] : [`reply too long (${r.trim().split(/\s+/).length} words)`],
  (r, card) => card && VALID_KINDS.has(card.kind) ? [] : [`unknown card kind "${card?.kind}"`],
  (r, card) => typeof card?.label === "string" ? [] : ["card.label missing"],
];

// ---------------------------------------------------------------------------
// Transport (live) or canned responses (--mock, to verify the harness itself)
// ---------------------------------------------------------------------------

const MOCK_RESPONSES = {
  "plain question stays cardless": { reply: "You're building nicely, load balance 1.05 and a 9 day streak. Keep stacking easy volume.", card: { kind: "none", label: "" } },
  "ease ask proposes easeWeek": { reply: "Heard. I can trim the week about 15% so you absorb it.", card: { kind: "easeWeek", label: "Ease this week" } },
  "adapt-lock blocks easeWeek, explained in words": { reply: "I already adjusted your plan this week, one structural change a week keeps adaptation honest.", card: { kind: "none", label: "" } },
  "move session echoes a real id": { reply: "Sure, the tempo slides later and the week stands.", card: { kind: "moveSession", label: "Move it", sessionId: SESSION_IDS[1], newDateISO: isoInDays(5) } },
  "days change carries the number": { reply: "Three days works. Your plan rebuilds around it.", card: { kind: "changeDays", label: "Train 3 days", daysPerWeek: 3 } },
  "injury report names the area, leaves severity to the app": { reply: "Thanks for telling me. How bad is it? Sharp pain or swelling means a professional first.", card: { kind: "injuryReport", label: "Adjust my plan", injuryArea: "shins" } },
  "remember distills a note": { reply: "Got it, keeping that in mind.", card: { kind: "rememberNote", label: "Remember this", note: "Hates treadmill running", noteCategory: "preference" } },
  "memory ask renders the memory card": { reply: "Here's what I keep in mind for you.", card: { kind: "memory", label: "What I know about you" } },
  "why-my-plan renders the explainer": { reply: "Fair question, here's the reasoning from your own numbers.", card: { kind: "explainPlan", label: "Your plan, explained" } },
  "week ask renders the recap": { reply: "Here's your week from the log.", card: { kind: "weekRecap", label: "Your week" } },
  "race pacing with a race set": { reply: "Here's the race from your current fitness.", card: { kind: "racePlan", label: "Your race plan" } },
  "race pacing with no race steers to setup": { reply: "No race on the calendar yet, point your plan at one first.", card: { kind: "nav", label: "Set up a race", nav: "planSettings" } },
  "vacation proposes a pause": { reply: "Life happens. I can shift everything a week later.", card: { kind: "pausePlan", label: "Pause 7 days", pauseDays: 7 } },
  "unearned bump is refused in words": { reply: "Your completed load hasn't earned a bump yet. Keep stacking and I'll offer it when it's safe.", card: { kind: "none", label: "" } },
  "predictor ask renders the predictor card": { reply: "From your fitness today, here are your equivalent race times.", card: { kind: "racePredictor", label: "What you could race today" } },
  "zones ask renders the zones card": { reply: "Here is where your effort should live.", card: { kind: "zones", label: "Your zones and paces" } },
  "today ask renders the briefing card": { reply: "Here is today, step by step.", card: { kind: "todayBriefing", label: "Today's session" } },
  "debrief cites the real workout": { reply: "That run was 8.1 km at 5:40 pace with a negative split, average heart rate 152. Right kind of easy.", card: { kind: "none", label: "" } },
};

async function ask(name, message, context) {
  if (MOCK) return MOCK_RESPONSES[name];
  const res = await fetch(URL_, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${BEARER}` },
    body: JSON.stringify({ messages: [{ role: "user", text: message }], context }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  return res.json();
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

let passed = 0, failed = 0;
for (const c of CASES) {
  const context = structuredClone(BASE_CONTEXT);
  c.patch?.(context);
  let failures = [];
  try {
    const { reply, card } = await ask(c.name, c.message, context);
    for (const check of [...UNIVERSAL, ...c.checks]) failures.push(...check(reply ?? "", card));
    if (failures.length === 0) { passed++; console.log(`  ✔ ${c.name}`); }
    else { failed++; console.log(`  ✘ ${c.name}`); failures.forEach((f) => console.log(`      ${f}`)); }
  } catch (e) {
    failed++;
    console.log(`  ✘ ${c.name}\n      ${e.message}`);
  }
}
console.log(`\n${passed} passed, ${failed} failed${MOCK ? " (mock self-test)" : ""}`);
process.exit(failed === 0 ? 0 : 1);
