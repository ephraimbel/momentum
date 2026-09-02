# Runna competitive teardown → Momentum running roadmap

> **Historical roadmap (2026-07-06; superseded for implementation on 2026-09-01).** Current work is
> governed by [`ELITE-RUNNING-SYSTEM.md`](ELITE-RUNNING-SYSTEM.md). Do not treat older ACWR injury/
> safety language or any Health workout-ingestion assumption below as an active requirement.

> Research date: 2026-07-06. Runna facts are from Runna's own support docs, Strava's press release,
> and real user reviews (Trustpilot / App Store / Reddit), adversarially fact-checked. Momentum's
> current state is from a codebase audit. Companion to [`RUNNING-EXCELLENCE.md`](RUNNING-EXCELLENCE.md)
> (the feature-by-feature R1–R5 running roadmap). Note: the coaching loop is now **closed** (pace
> recalibration + ACWR auto-adapt are wired in `WorkoutRunner.finish()`), so the status table in
> `docs/COACHING-LOOP-AUDIT.md` is out of date — trust the code, not that table.

## TL;DR
Runna's moat isn't its AI — its plans are **human-coach templates**; AI only monitors progress and
nudges paces. Its moat is **execution**: every session is a *structured workout* (warm-up → reps at a
target pace → timed recovery → cool-down) that a watch **guides you through live** with audio cues and
pace prompts. That is exactly the layer Momentum is missing. Momentum already **matches or beats** Runna
on onboarding depth, adaptive/no-shame coaching (our loop is *closed and automatic*; Runna's is a manual
"Plan Realignment" pop-up), cross-discipline intelligence, and aesthetics. So the play is narrow and
winnable: **build the structured-workout + guided-run stack to reach parity on running, then win on
generative AI coaching, hybrid sequencing, taste, and trust.**

Positioning shift the user asked for: keep the hybrid wedge, but elevate **running to first-among-equals**
— the running experience must feel Runna-grade, not one-of-four.

---

## What Runna actually does (verified)

**Onboarding.** Asks: goal + race (5K/10K/half/marathon) + date; **ability level** (Beginner/Intermediate/
Advanced/Elite, with concrete definitions); **recent race/distance finish times**; days/week (**min 2, max
4–7 by level, no 1-run plans**); preferred **long-run day**. From this it sets **initial pace targets from
day one** and seeds **current weekly mileage + longest run**.

**Plan & workout structure.** Periodized (aerobic base → key block → race-specific speed → taper); pace &
volume "step up a small structured amount each week," capped by a conservative weekly ceiling. The unit
that matters: **each session is a native structured workout** — warm-up, intervals/reps at explicit target
paces, timed recoveries, tempo blocks, long runs, cool-down. Paces **auto-suggest up/down from completed
runs** (user accepts/declines — "Pace Insight Recommendations"). Post-run you log **RPE**, which feeds the
next recommendation.

**Guided in-run (the killer feature).** On Apple Watch/Garmin the workout guides you **step by step**:
shows distance remaining, current pace vs target, prompts **speed up / slow down** (pacing to the *midpoint*
of the target range), and **counts down recovery** so you know exactly when to run again. Audio cue set:
"Get ready to start" → "Start running" → pace alerts → pause/resume → halfway → "Lap x completed in x" →
"Workout completed in x." Structured sessions sync phone→watch (Garmin: next 2 weeks every Monday).

**Adaptation.** Mostly **manual & rule-based**: a "Plan Realignment" pop-up appears after **3+ missed
workouts or a missed week**, offering skip / rearrange / extend / rebuild. A single skipped run is just
"noted." AI is monitoring + insights, **not** workout authorship.

**Strength/cross-training.** Running-specific strength (session types: Legs & Core / Full Body / Upper
Body), plus mobility, dynamic drills, plyometrics; user picks sessions/week, level, length, equipment.
It's bolted alongside running, **not fatigue-sequenced against it.**

**Pricing / business.** Strava acquired Runna (Apr 2025); Strava+Runna bundle **$149.99/yr, annual-only,
up to 60% off**; standalone Runna is a separate sub. **7-day** trial (not two weeks).

**What users hate (our openings).**
1. **Billing/cancellation dark-patterns** — charged after cancelling, uninstall doesn't stop billing,
   annual locked 12 months, slow support (72 hr+, no phone). *Most-cited complaint, systemic.*
2. **"Same for everyone, just pace changes"** — plans feel impersonal, thin variety, weak for fast runners.
3. **Default plans "too aggressive"** → beginner injury risk.
4. **Sync reliability** — missing/delayed/duplicate workouts; silently breaks its own adaptation.
5. **Adaptation is manual** — the app makes *you* choose how to fix a missed week.

---

## Momentum today (so we don't rebuild what exists)

**Already strong / ahead of Runna:**
- **Onboarding** — goal-branching, discipline select, metrics, race path, and **pace calibration** (by-feel
  *or* recent-benchmark → Riegel), live "easy pace ≈ X/mi" preview. Parity-plus with Runna.
- **Closed, automatic coaching loop** (`PlanCoaching`, `WorkoutRunner.finish()`): faster-only pace
  recalibration (Riegel, ≤3%/update), ACWR **auto-adapt** (protective ease/rest applied *automatically*),
  no-shame **missed-session reconciliation**, notifications — all shipped. This beats Runna's manual pop-up.
- **Athlete Model** — a persistent, private, AI-evolved memory of the athlete (`AthleteModel`, learned
  beliefs with confidence). Runna has nothing like it.
- **AI scaffolding** — Supabase edge fns (`workout-analysis`, `plan-narrate`, `coach-chat`) with
  deterministic fallbacks; post-workout "Coach read"; Coach chat. (Server keys are CONFIG-PENDING — AI runs
  on templated fallbacks until Supabase is wired.)
- **Structured *strength*** (`GeneratedExercise`: sets/reps/RPE/%1RM/progression), Apple Watch slices 1–3,
  offline-first SwiftData (our sync won't silently drop workouts like Runna's), aesthetics + TikTok profile.

**The three real gaps (running):**
1. **No structured running-workout data model.** `GeneratedSession.intervals` is a **plain string**
   (`"6×400m @ 5K pace"`) — not rep-by-rep segments with per-segment target pace/duration/recovery.
2. **No guided in-run execution.** Live run is free-GPS + km/mi voice splits only; the plan's intervals
   are never parsed or driven during the run (no prompts, countdowns, pace-adherence cues).
3. **No structured session on the watch.** Watch slices exist, but there's no guided-workout screen.

Plus a known plan-quality flaw: intervals are prescribed at *exactly* 5K pace (no true VO2/threshold split).

---

## Roadmap — what to build

### P0 · Reach Runna parity on running (the wedge)
1. **Structured workout model.** New value type `StructuredWorkout { segments: [Segment] }`, where
   `Segment` = `{ kind: warmup|rep|recovery|tempo|steady|cooldown, target: paceRange|duration|distance,
   repeatGroup? }`. Persist on `GeneratedSession` and `Workout.plannedSession`. Refactor `PlanEngine`
   `cardioSessions` to emit real segments instead of the `intervals` string. Keep the deterministic rule:
   engine computes every pace/segment; AI only narrates. *(Foundational — everything below depends on it.)*
2. **Guided in-run "session runner."** A live executor that walks the `StructuredWorkout`: current-segment
   card (e.g. "Interval 3/6 · 800 m · target 4:30–4:40/km"), distance/time remaining, auto-advance, and a
   **pace-adherence state** (in / above / below → prompt to the *midpoint*, à la Runna). Reuse
   `VoiceCoachService` + extend `CoachingCueBuilder` for segment cues: "Start running", "Speed up/Ease off",
   "Recovery — 90s" with countdown, "Halfway", "Interval x of y", "Workout complete." Drive it from the
   parsed plan (today it's ignored).
3. **Apple Watch guided run.** Extend the watch slices with a guided-workout screen: segment, target vs
   current pace, haptic speed-up/slow-down, recovery countdown; sync the structured session phone→watch.

### P1 · Out-personalize + out-coach Runna
4. **Onboarding running-depth tweaks** (small): add an **ability tier** + **current weekly mileage** +
   **longest run** to the running calibration step (seeds volume accurately, like Runna); make the race
   path more prominent now that running leads. Keep by-feel/benchmark calibration.
5. **Real workout variety** (kills Runna's "same for everyone"): add fartlek, progression runs, hill reps,
   strides/drills, and a true **threshold vs VO2** distinction (fix the "intervals @ exactly 5K pace"
   flaw); always include warm-up/cool-down segments.
6. **Generative AI coach that authors rationale for *every* session** and answers "why this workout / can I
   move it?" in context — extend `plan-narrate` + `coach-chat` grounded in the Athlete Model. Runna's AI
   only monitors; ours explains and adjusts within deterministic bounds. *(Requires wiring live Supabase
   keys — currently CONFIG-PENDING.)*
7. **Post-run RPE → adaptation.** Capture `perceivedEffort` (field exists) and feed it into pace
   recalibration/auto-adapt, matching Runna's RPE loop but automatic.
8. **Hybrid sequencing, made visible.** Surface the cross-discipline moment Runna structurally can't do —
   "moved legs off Thursday so your long run is fresh." Fatigue-aware run+lift ordering in the weekly plan.

### P2 · Retention & trust (turn Runna's complaints into our marketing)
9. **Trust-first billing** — transparent, one-tap cancel, no "uninstall ≠ cancel" trap. Directly answers
   Runna's #1 complaint; a positioning win.
10. **Reliability as a feature** — lean on offline-first SwiftData (zero lost/duplicate workouts) where
    Runna's sync silently breaks its own adaptation.
11. **Engagement moments** — weekly plan-preview notification, "your paces just got faster" (partly exists),
    streak/PR/greatest-hits (the new TikTok profile) for emotional retention Runna lacks.

---

## Scorecard

| Capability | Runna | Momentum today | After P0–P1 |
|---|---|---|---|
| Onboarding depth / pace calibration | ✅ | ✅ (parity+) | ✅ |
| Structured interval workouts | ✅ | ❌ (string only) | ✅ |
| Guided in-run audio/pace coaching | ✅ | ⚠️ splits only | ✅ |
| Watch guided workout | ✅ | ⚠️ slices, no guide | ✅ |
| Auto plan adaptation | ⚠️ manual pop-up | ✅ automatic | ✅✅ |
| Persistent AI athlete model | ❌ | ✅ | ✅ |
| Generative AI that authors/explains | ❌ | ⚠️ scaffolded | ✅✅ |
| Hybrid run+lift sequencing | ❌ | ✅ (engine) | ✅✅ (surfaced) |
| Aesthetics / shareable identity | ⚠️ flat | ✅ | ✅✅ |
| Billing trust | ❌ | opportunity | ✅ |

**Bottom line:** P0 buys running parity; P1 is where Momentum becomes *the better Runna* for hybrid
athletes — automatic, explaining, fatigue-aware, and beautiful — instead of a human-templated plan with a
pace nudge.
