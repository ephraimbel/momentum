# Athlete Model — design (v1 draft, 2026-06-09)

> The memory layer that makes Momentum *learn* each user. This is the architectural
> expression of the north-star: a personal AI that understands you better the longer you
> train. Read [`PRD.md`](PRD.md) first — this doc extends it; it does not override §9's
> "deterministic engine, AI only narrates" principle.

---

## 0. The one idea

Momentum's AI today has **amnesia**. `AIService.workoutRead(for:)` reads *one* workout,
narrates it, and forgets (`Momentum/Services/AIService.swift:8-16`). Onboarding fills a
`UserProfile` once and it never changes. `ProgressInsights` recomputes ACWR from scratch
every time and remembers nothing between sessions.

To "understand you perfectly" we need a **persistent, evolving model of the athlete** that
accumulates after every workout and that the AI both **reads from** and **writes back to**.
That model is the product. Everything below is how it works, with no piece left vague.

---

## 1. Principles (inherited + new)

1. **Deterministic facts, AI narration only.** Numbers and patterns are computed by pure,
   testable Swift (like the existing engines). The LLM never computes a number — it
   interprets facts and writes prose/short memory notes. (PRD §9.)
2. **Reconstructable by default.** Everything quantitative is *derived* from raw workouts,
   so it can be rebuilt from scratch at any time. The only non-reconstructable layer is the
   AI's qualitative memory + user corrections — that layer is the backup/sync priority.
3. **Never block, never shame, no medical claims.** The post-workout moment must never wait
   on the network; memory updates are best-effort. Reuse the existing sanitizer
   (`WorkoutReadTemplates.swift:104-114` banned terms: injur/pain/diagnos/medical/rehab).
4. **Earn understanding; don't fake it.** Every belief carries a confidence level tied to
   evidence volume. Day 1 the model is honestly thin ("still learning your rhythm"); by
   week 8 it's sharp. We design the cold-start arc, we don't paper over it.
5. **The user owns the model.** Any belief is correctable in one tap. A correction becomes a
   high-priority memory the AI must respect. This is the core trust mechanic.

---

## 2. Two tiers

| Tier | What | Who writes it | Reconstructable? | Example |
|------|------|---------------|------------------|---------|
| **A — Facts** | Structured, quantitative signals | Pure Swift engine, on every workout | Yes (from history) | "Trains 78% of sessions before 9am"; "easy-run pace −6% at same RPE over 8 weeks" |
| **B — Memory** | Short qualitative beliefs | The LLM (and the user) | **No** | "You get discouraged when you miss a long run — keep those sacred"; "Prefers 45-min sessions even when given 60" |

Tier A is the evidence. Tier B is the *understanding* the AI distills from that evidence and
remembers across sessions. Tier A makes Tier B honest (notes must cite facts); Tier B makes
Tier A feel human.

---

## 3. Data model (SwiftData)

New models, registered in `PersistenceController.models`
(`Momentum/Persistence/PersistenceController.swift:13-20`). All properties have defaults
(SwiftData requirement, matches existing models). One `AthleteModel` per `UserProfile`
(1:1), with two child collections.

```swift
@Model final class AthleteModel {
    var id: UUID = UUID()
    var updatedAt: Date = Date()
    var version: Int = 1                      // schema/distillation version for migration

    // --- Tier A: derived facts (recomputed each workout; see §4) ---
    // Rhythm
    var trainingHourHistogram: [Int] = Array(repeating: 0, count: 24)  // counts by hour-of-day
    var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)        // counts by weekday
    var medianSessionMinutes: Double = 0
    var preferredSessionMinutes: Double = 0    // mode of completed durations
    // Adherence
    var planAdherence28d: Double = 0           // completed / (completed+missed), trailing 28d
    var movedSessionRate28d: Double = 0
    // Discipline mix
    var disciplineShare: [String: Double] = [:]   // WorkoutType.raw -> fraction, trailing 56d
    var disciplineTrend: [String: Double] = [:]    // share delta vs prior period
    // Fitness trajectory (the "progress over time" backbone)
    var paceAtEffortTrendPct: Double = 0       // easy-run pace change at matched RPE, 8wk (−better)
    var e1rmTrendByExercise: [String: Double] = [:]  // exercise name -> % change, 8wk
    var weeklyVolumeTrendPct: Double = 0
    // Load / recovery
    var currentACWR: Double = 0
    var overreachThresholdACWR: Double = 1.5   // legacy persisted name; low-confidence high-strain context, never a safety threshold
    var typicalRecoveryDays: Double = 1        // days after a hard session before quality returns
    // Achievement
    var prCountByMonth: [String: Int] = [:]    // "2026-06" -> count
    var lastPRAt: Date?
    // Risk (churn / overtraining early-warning — ties to retention research)
    var frequencyTrend28d: Double = 0          // sessions/wk delta; negative = fading
    var consecutiveMissed: Int = 0
    // Confidence bookkeeping
    var signalSampleCounts: [String: Int] = [:]  // signalKey -> #workouts backing it

    @Relationship(deleteRule: .cascade) var notes: [MemoryNote] = []
    @Relationship(deleteRule: .cascade) var snapshots: [FitnessSnapshot] = []
    init() {}
}

@Model final class MemoryNote {                // Tier B
    var id: UUID = UUID()
    var category: String = "habit"             // habit | preference | response | motivation | risk | identity
    var text: String = ""                      // ≤140 chars, second person, no-shame, no-medical
    var confidence: String = "emerging"        // emerging | growing | confident
    var source: String = "ai"                  // ai | user | onboarding
    var evidenceKeys: [String] = []            // Tier-A signal keys / workout IDs supporting it
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isActive: Bool = true                   // retired notes kept (audit) but not surfaced/sent
    var pinned: Bool = false                    // user-sourced corrections pin to top, AI must honor
    init() {}
}

@Model final class FitnessSnapshot {            // weekly time series — unlimited-horizon progress
    var weekStart: Date = Date()
    var p5kEquivSPerKm: Double?                 // running fitness proxy (Riegel-normalized)
    var topE1RMByLift: [String: Double] = [:]
    var weeklyLoad: Double = 0
    var weeklyDistanceM: Double = 0
    var acwr: Double = 0
    init() {}
}
```

Add the three to the `models` array and add `var athlete: AthleteModel?` (cascade) to
`UserProfile` (`Momentum/Models/UserProfile.swift:25-27`, alongside `workouts`/`plan`/`prs`).

**Why a persisted snapshot series?** `ProgressInsights` only holds a rolling 8 weeks in
memory (`Engines/ProgressInsights.swift` `weeks`). To show "how you've progressed" over
*months*, we persist one `FitnessSnapshot` per ISO week. This is the spine of the trajectory
view and is cheap (≈52 rows/year).

---

## 4. Tier A — the deterministic extractors

New pure engine `Momentum/Engines/AthleteModelEngine.swift`, same shape as
`ProgressInsights` (pure, init-time, fixture-tested). It takes the full workout history +
the plan and **fully recomputes** the facts (history is small — hundreds of rows — so full
recompute beats error-prone incremental updates; matches how every existing engine works).

Precise definitions (so there is no ambiguity to get wrong):

| Signal | Definition | Min evidence for "confident" |
|--------|------------|------------------------------|
| `trainingHourHistogram` | bucket each `Workout.startedAt` by local hour | 8 workouts |
| Morning/evening label | hour with ≥60% mass over a 6-hour window | 8 |
| `weekdayHistogram` + skip days | weekdays with completed sessions vs `PlannedSession.status==.missed` | 4 weeks |
| `preferredSessionMinutes` | mode of `durationS/60` rounded to 15-min bins | 6 |
| `planAdherence28d` | `completed / (completed + missed)` over trailing 28d from `PlannedSession.status` (via `PlanCoaching`) | needs an active plan |
| `disciplineShare` / `disciplineTrend` | fraction of workouts by `type` (trailing 56d) and delta vs the prior 56d (reuses `ProfileStats.countsByType` logic) | 10 |
| `paceAtEffortTrendPct` | among **easy** runs (`runType==.easy`/`.recovery` or `perceivedEffort≤4`), linear trend of `avgPaceSPerKm` over 8wk. Negative = getting fitter. The single most motivating signal. | 6 comparable runs |
| `e1rmTrendByExercise` | per exercise, % change of best `StrengthMath.e1RM` over 8wk (reuses `StrengthPRs`/`StrengthMath`) | 4 sessions w/ that lift |
| `currentACWR` / `overreachThresholdACWR` | Recent-to-usual load ratio plus a legacy-named, low-confidence observation from ratios preceding ≥3 high-RPE easy sessions. Descriptive context only; never injury prediction, clearance, or a personal limit. | 6 weeks |
| `typicalRecoveryDays` | mean days from a hard session (top-tertile load) until easy-pace-at-effort returns to baseline | 8 weeks |
| `frequencyTrend28d` | sessions/week slope over trailing 28d; **negative is the churn early-warning** | 4 weeks |

Everything above is a pure function of data the app already stores. Reuse, don't duplicate:

- **ACWR / load / weekly series** → `ProgressInsights` (`Engines/ProgressInsights.swift`).
- **Streak / consistency / grace** → `StreakCalculator`.
- **e1RM / volume / muscle balance** → `StrengthMath`, `StrengthPRs`.
- **Splits / fastest windows / pacing** → `CardioMetrics`, `GPSProcessor`.
- **Adherence / missed / moved** → `PlanCoaching` + `PlannedSession.status`.
- **Lifetime aggregates** → `ProfileStats`.

The AthleteModelEngine's *new* work is only: the behavioral signals (time-of-day, weekday,
session-length preference, adherence trend, discipline trend, pace-at-effort trajectory,
recovery response, overreach threshold, churn-risk). Each writes a `signalSampleCounts`
entry so confidence is computable.

---

## 5. Tier B — the AI memory

Memory notes are how the model "understands" rather than just "measures." The LLM owns them,
bounded and sanitized.

- **Schema**: see `MemoryNote` above. ≤140 chars, second person, one belief per note.
- **Categories**: `habit` (when/how you train), `preference` (what you choose),
  `response` (how your body reacts to load), `motivation` (what keeps you going — seeded from
  onboarding `reason`), `risk` (overtraining/fading — used gently), `identity` (the one-line
  "who you are as an athlete").
- **Lifecycle ops** the LLM may return: `add`, `revise` (by id), `retire` (by id). Retired
  notes are soft-deleted (`isActive=false`) for audit, never surfaced or re-sent.
- **Bounded**: keep ≤ 20 active notes (oldest low-confidence retired first). Keeps the prompt
  small and the surface legible.
- **Grounding rule (in the system prompt)**: every note must be supported by a Tier-A fact or
  named workouts; the LLM receives `evidenceKeys` it must fill. No note may invent a number.
- **Sanitization on ingest**: run the same banned-term filter as `WorkoutReadTemplates`; drop
  any note that trips it. No-shame phrasing enforced by prompt + filter.
- **User corrections**: a tap on any surfaced belief opens "that's not quite right" → writes a
  `source:"user", pinned:true` note. Pinned notes are always sent to the LLM with an
  instruction to honor them over its own inferences, and never auto-retired.
- **Onboarding seed**: at plan creation we seed 2–3 notes from `UserProfile`
  (goal, experience, `reason`) so the model is never empty — e.g. *motivation*: "You're here
  for a clear head, not a podium." This is the cold-start floor.

---

## 6. The pipeline — end to end, on every workout

Trigger point: the workout-save path, after the capture engines persist
(`WorkoutStores.swift` `finishWorkout` — GPS `:50-65`, strength `:128-137`). The summary
screen is already where the AI read is requested (`AIReadCard.swift:21-26`), so we hang the
model update off the same moment but split fast/slow work.

```
workout saved (local, durable — already guaranteed)
        │
        ▼
[1] AthleteModelService.ingest(workout)         ── on-device, synchronous, ALWAYS runs
        ├─ AthleteModelEngine.recompute(history) → update AthleteModel (Tier A facts)
        ├─ upsert this week's FitnessSnapshot
        └─ recompute confidence levels
        │
        ▼
[2] Enriched workout-analysis call               ── network, best-effort, ≤4s budget
        │  request = WorkoutDigest + planned + units
        │           + athlete: { facts(compact), activeNotes, last 2 narratives }
        │  ┌─ success → render personalized narrative + insights
        │  │            + apply memoryUpdates (sanitize, cap to 20)  → persist Tier B
        │  └─ timeout/err → WorkoutReadTemplates.read(...) (today's behavior; never blocks)
        ▼
[3] (optional, periodic) deep consolidation       ── background, weekly
           re-derives the identity note + retires stale beliefs from the full snapshot series
```

Key properties:
- **[1] never fails** — pure local compute; the model deepens even fully offline.
- **[2] never blocks** — identical fallback to today; personalization is additive.
- **Single round-trip** for the common case: the read *and* memory updates come back together,
  so we don't pay for two LLM calls per workout.
- **Debounce**: if a user saves several workouts quickly, coalesce [1] and only send the
  latest [2].

Wiring: introduce `AthleteModelService` (owns the engine + a `ModelContext`, injected via the
`Services` container — `App/Services.swift:14-58`). `AIService` (the live impl,
`Services/AIService.swift`) gains a dependency on it to (a) fetch athlete context before the
call and (b) apply returned `memoryUpdates`. The `AIServing` protocol signature is unchanged;
only the live implementation grows.

---

## 7. Edge function contract (enriched `workout-analysis`)

Extend `supabase/functions/workout-analysis/index.ts`. **Do not send raw GPS samples** (huge,
and the LLM can't use 2,000 lat/lons) — send a compact `WorkoutDigest`.

**Request**
```jsonc
{
  "workout": {                       // WorkoutDigest — derived, not raw
    "type": "run",
    "durationS": 2730, "elapsedS": 2900,
    "perceivedEffort": 4,
    "gps": { "distanceM": 8000, "avgPaceSPerKm": 341, "elevationGainM": 120,
             "avgHR": 148, "splits": [ {"km":1,"s":345}, ... ],
             "fastest1kS": 320, "negativeSplit": true },
    "strength": null                 // or { totalVolumeKg, topSets:[{lift,weightKg,reps,e1rm}], setsByMuscle }
  },
  "planned": { "had": true, "type": "easy", "targetDistanceM": 8000, "rationale": "base" },
  "units": { "weight": "kg", "distance": "auto" },
  "athlete": {
    "facts": {                       // compact projection of Tier A (only confident signals)
      "rhythm": "early-morning, ~45min",
      "adherence28d": 0.86,
      "disciplineMix": "running 0.7 / strength 0.3, strength rising",
      "fitness": "easy pace −6% at same effort over 8wk; bench e1RM +4%",
      "load": { "recentToUsualRatio": 1.12, "priorHighStrainRatio": 1.5 }
    },
    "notes": [ {"id":"...","category":"motivation","text":"...","confidence":"confident","pinned":false} ],
    "recentNarratives": ["...","..."]   // last 2, so it won't repeat itself
  }
}
```

**System prompt additions** (to the existing one at `index.ts:21-26`):
- "You also maintain a long-term memory of this athlete. Use `athlete.facts` and
  `athlete.notes` to make the note feel like it remembers them. Reference a real pattern, not
  a generic platitude."
- "Honor any note with `pinned:true` as ground truth over your own inference."
- "Return `memoryUpdates`: 0–3 ops. Only add/revise when this workout is genuine evidence.
  Every note must cite an `evidenceKey`. Never invent numbers — use only `athlete.facts`.
  No medical/injury language; never shame."

**Response** (extends today's schema at `index.ts:28-50`)
```jsonc
{
  "narrative": "…≤55 words…",
  "insights": [ {"label":"…","value":"…","note":"…"} ],
  "planAdjustment": {"changed": false, "summary": ""},
  "memoryUpdates": [
    {"op":"add","category":"response","text":"You hold pace better the day after a rest day.",
     "confidence":"growing","evidenceKeys":["recovery","wkt_123"]},
    {"op":"revise","id":"note_abc","text":"…","confidence":"confident","evidenceKeys":["…"]}
  ]
}
```
Add `memoryUpdates` to the strict JSON schema (optional array, items closed-object). Keep
`claude-opus-4-8`, structured outputs, 503→template fallback unchanged.

A separate `athlete-consolidate` function (step [3], weekly, no latency budget) can re-author
the `identity` note and prune stale beliefs from the full snapshot series — optional for v1.

---

## 8. The "You" surface — making the learning visible

The research is blunt: invisible learning doesn't retain. The model must be *shown*, and its
weekly deepening is itself the reason to reopen the app (the day-1→30 retention lever).

**Placement** (recommendation, reversible): add a third segment to the Progress tab —
`Trends | History | You` — next to the existing segmented control
(`Features/Progress/ProgressView.swift:43-58`). Avoids diluting the clean 3-tab structure
(`App/Route.swift`) while giving the model a prominent home. Plus a small **teaser on Today**
above the bottom panel: "Momentum learned 2 new things about you →".

**"You" contents**
1. **Identity hero** — the AI `identity` note: *"An early-morning hybrid athlete building toward
   your first 10k."* Iridescent (it's progress/achievement — earns the accent per PRD §5).
2. **Your progress** — the `FitnessSnapshot` trajectory: easy-pace-at-effort curve, key e1RM
   curves, weekly volume. This is the literal "see how you've progressed over time." Count-up
   + animated line charts (reuse the chart components in ProgressView).
3. **Your rhythm / patterns / what drives you** — cards rendering `confident` MemoryNotes and
   the matching Tier-A fact, grouped by category, each with a faint confidence pip and a
   "since {month}" caption.
4. **Correction affordance** — every card has a quiet "not quite right?" → writes a pinned
   user note (§5). This is the trust loop.
5. **Cold-start state** — when confidence is thin: *"I'm still learning your rhythm — about 4
   more sessions until I've got it."* Honest, never fake.

---

## 9. Conversational layer (deferred — gated on a rich model)

**Status: deferred, and never a generic "chat" tab.** Rationale (2026-06-09): Momentum's edge
is *proactive* understanding — the app tells you what matters without being asked. A blank
"ask anything" box is reactive, faces every user with an empty prompt they don't know how to
fill, and invites the LLM to compute loads / give medical advice — against §1 and PRD §9. We
build conversation only **after Phase 4** (the model already speaks) and only once the Athlete
Model is rich enough to make it special. The differentiator isn't "chat with an AI"; it's
**"talk to the coach who has watched your training for weeks."**

When built, three rules keep it on-brand:

**(a) Contextual, not a tab.** Conversation is entered from an "ask about this" affordance on a
specific object — a workout read, a plan day, a You-surface belief — so it always starts
grounded. Preserves the 3-tab structure (no 4th tab; matches §15 placement decision).

**(b) Grounded & scoped.** The coach reasons only over *this* athlete: the `AthleteModel`
facts, active `MemoryNote`s, workout history, and current plan. It surfaces numbers from Tier A
— **never computes them** — and obeys the same guardrails as the reads (no medical/injury, no
shame, sanitizer reused). Server-side, same edge-function pattern. This is the one surface
where we relax the ≤4s budget (a conversation may take a beat), but turns and context are
capped and reuse the cached athlete context — no extra compute to assemble it.

**(c) Smart suggestions — never a blank box.** Every entry point offers 2–4 suggested prompt
chips generated *from the user's current state*, so the interaction is tap-first, type-second:
- from the plan day → "Why is tomorrow easy?"
- from a fitness trend → "How's my 10k coming?"
- from a confident belief → "Why do you think I'm a morning runner?"
- from a likely correction → "Actually, I prefer evenings" (writes a pinned note)

Chips are derived **deterministically** from context (plan, recent reads, confident notes,
churn/overreach flags), so the model proposes the conversation the user didn't know to start.

**Proactive "updates on you" — the model speaks first.** This is the other half, and the more
on-brand one: rather than wait to be asked, Momentum surfaces what it has learned.
- **Weekly digest** ("Your week with Momentum") on the You tab + optional push: what changed,
  what it learned, the trajectory delta.
- **"Momentum noticed…" nudges** — event-triggered: a new `confident` belief formed, a fitness
  milestone, overreach risk ahead, or fading frequency caught early (softened — never shown as
  "you're slipping", per §15). Delivered via the Today teaser (§8) and opt-in notifications
  (the `NotificationServing` stub, `App/Services.swift`).
- Triggers are deterministic (Tier A); the wording is AI-narrated (Tier B) and bounded.

**Memory loop.** Every conversation can write `MemoryNote`s through the same apply path as
§6–7 (corrections pin; new beliefs cite evidence). Chat is thus a first-class way the model
*learns*, not just answers — which is the only reason it earns a place at all.

---

## 10. Cold-start & confidence (the "don't promise perfectly" arc)

Each Tier-A signal maps `signalSampleCounts[key]` → `{emerging | growing | confident}` via the
thresholds in §4. Rules:
- **Only `confident` beliefs** are stated plainly on the You surface and sent to the LLM as
  facts. `growing` beliefs render faintly ("looks like you…"). `emerging` are held back.
- The **identity hero** appears only once ≥3 signals are `confident` (≈ 2–3 weeks of use).
  Before that, the hero shows the onboarding-seeded motivation note + a "getting to know you"
  progress bar.
- The arc is explicit and designed: **week 0** = onboarding seeds; **week 1** = rhythm +
  discipline mix emerge; **week 3** = adherence + session-length + first fitness trend;
  **week 8** = recovery response, overreach threshold, full identity. We promise *a relationship
  that deepens*, never "I know you perfectly."

---

## 11. Reliability, privacy, sync

- **Continuity is existential** (per the category research): losing history means the AI
  forgets who the user is. Tier A is reconstructable (safety net); **Tier B notes +
  FitnessSnapshots + user corrections are not** → they are the first thing to back up/sync.
  This is the concrete reason cloud sync (the unused `Workout.syncedAt`,
  `Models/Workout.swift:18`; stub `SyncServing`, `App/Services.swift`) graduates from "nice"
  to "foundational" and should lead the broader roadmap.
- **Privacy**: the model is deeply personal → default private; owner-only RLS on every athlete
  table when sync lands; memory notes never contain medical/injury claims (sanitizer reused).
- **User control**: a "what Momentum knows / forget this" control in the You surface; deleting
  a note is honored and can pin a counter-belief.

---

## 12. Testing — so it's correct, not just plausible

- **Tier A is fixture-tested** exactly like the existing engines (the repo already has
  `MomentumTests`): hand-built workout histories → asserted facts (e.g. a history of 9am runs →
  morning label; a falling easy-pace history → negative `paceAtEffortTrendPct`; a missed-then-
  moved plan → expected adherence). Pure functions, deterministic, no flakiness.
- **Memory-apply logic is unit-tested** with mocked edge responses: op handling (add/revise/
  retire), the 20-note cap, sanitizer rejection, pinned-note protection.
- **Pipeline tests**: [1] runs and persists offline; [2] failure falls back to template with no
  thrown error and no UI block.
- **Confidence thresholds tested** against sample counts at boundaries.

---

## 13. Worked walkthrough (how it feels when it's right)

- **Onboarding.** User picks running+strength, goal "race a 10k", reason "clear head", adds a
  recent 5k (calibration). We seed: identity-seed "new-ish hybrid runner", motivation "here for
  a clear head". You-surface shows "getting to know you."
- **Workout 1 (easy 5k, RPE 4).** [1] updates rhythm (1 sample), discipline mix. [2] returns a
  warm read; adds note `habit:"emerging"` "Looks like you train in the morning." Surface still
  honest-thin.
- **Week 1 (4 sessions).** Morning label hits `confident`. Discipline mix shows running-led.
  First FitnessSnapshot logged. Today teaser: "Momentum learned 2 things about you."
- **Week 3.** Adherence 0.9, session-length preference 45min `confident`. Easy-pace-at-effort
  trend turns negative → note `response`: "You're getting fitter — easy pace down at the same
  effort." Identity hero appears: "A consistent morning runner adding strength."
- **Week 8.** Overreach threshold learned (1.4). After two hard days the read says: "Tomorrow's
  easy — you tend to overreach past here, and the day after a rest you run your best." That is
  the AI *remembering* them. User taps "not quite right" on a stale preference → pinned
  correction → AI honors it next session. The model is now a relationship.

---

## 14. Phased build order (dependencies first)

> **Status (2026-06-09):** Phases 0–5 implemented on branch `docs/athlete-model` (full suite green;
> You surface, Today teaser, and the "Not quite right?" correction affordance verified in the
> simulator). Phase 4 ships **dark** — set `SupabaseURL` + `SupabaseAnonKey` and deploy
> `workout-analysis` to turn it on. Phases 6–8 (sync · weekly consolidation · conversational) next.

0. **Models + registration** — `AthleteModel`, `MemoryNote`, `FitnessSnapshot`; add to
   `PersistenceController.models`; relate to `UserProfile`. (Schema migration is lightweight.)
1. **`AthleteModelEngine` (Tier A) + fixtures** — pure, fully tested. No UI yet.
2. **`AthleteModelService` + ingest wiring** — recompute on workout finish; snapshots;
   confidence. Onboarding seeds initial notes. (Still no network — model deepens offline.)
3. **You surface (read-only)** — render Tier A facts + seeded notes + trajectory charts +
   cold-start states + Today teaser.
4. **Enriched edge function + memory apply** — extend `workout-analysis` request/response;
   personalize the read; persist `memoryUpdates`; sanitizer + cap + pinned-honor.
5. **Corrections** — "not quite right" → pinned user notes; "forget this".
6. **Sync of Tier B + snapshots** — the continuity guarantee (depends on the broader
   auth/sync foundation; sequence with that roadmap).
7. **(Optional) weekly `athlete-consolidate`** — identity re-authoring + stale-belief pruning.
8. **Conversational layer (deferred, §9)** — contextual, grounded coach Q&A with smart
   suggested prompts, plus proactive "Momentum noticed…" nudges and the weekly digest. Gate:
   only after phase 4 *and* a rich model; depends on `NotificationServing`. Not v1.

Each phase ships value alone: by phase 3 the app visibly learns you *with no AI cost*; phase 4
makes it speak; phase 6 makes it permanent; phase 8 lets you talk back.

---

## 15. Decisions

1. **You-surface placement** — ✅ **DECIDED (2026-06-09): third Progress segment**
   (`Trends | History | You`) plus a Today teaser card. (Not a 4th tab; not Today-led.)
2. **One LLM call vs two** — ✅ **DECIDED (2026-06-09): one folded call.** Memory updates ride
   back with the post-workout read in a single `workout-analysis` round trip. Optional weekly
   `athlete-consolidate` remains a later enhancement, not v1.
3. **Conversational layer** — ✅ **DECIDED (2026-06-09): deferred; never a generic chat tab.**
   When built it is contextual, grounded, suggestion-led, and proactive (§9), entered from
   objects rather than a 4th tab. Not before phase 4 / a rich model.

Still to confirm (don't block early phases):

4. **Note ceiling**: 20 active notes — tune after seeing real density.
5. **Churn-risk visibility**: do we ever *show* the fading-frequency signal to the user, or
   only use it to soften coaching? (Leaning: never show "you're slipping"; use it to nudge.)
6. **Confidence thresholds** in §4 are first estimates — calibrate against real histories.
