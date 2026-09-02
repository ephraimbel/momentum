# Momentum — Endurance Focus (Repositioning + PRD)

> **Status:** Living positioning source; execution active. This document supersedes the "hybrid
> athlete" positioning in `PRD.md` §1. Part II of `PRD.md` remains authoritative for architecture.
> The Apple Health doctrine below reflects the 2026-08-15 owner decision: signals only, never workout
> import. This is a **refocus, not a rebuild**.

One-liner: **keep moving.**
Positioning: **the running app that grows with you — from your first 5K to your first ultra.**

---

## 1. The bet (and the honest case for it)

We were splitting one product across two buyers (runners *and* lifters) with one onboarding, one plan
engine, one identity — and being merely good at both. We're narrowing to **endurance athletes, runners
first**, because:

- Running is a huge, monetizable, retention-friendly market on its own (Strava acquired Runna for a
  reason). Focus sharpens onboarding, the plan engine, the charts, and the story.
- The real whitespace is **personalization + adaptation**. The common complaint about Runna and its
  peers: *great at a generic base, poor at truly personalizing and at adapting when you're not
  recovering or you get hurt.* That is exactly our north-star (an app that **learns** each user) and
  the #1 gap in `RUNNA-COMPETITIVE-ROADMAP.md`. Reading a runner's Oura/Garmin/Watch recovery and
  reshaping the week — done safely and beautifully — is a **data + trust moat** that's hard to copy.
- Strength stays as a **supporting pillar** (strength-for-runners: economy + durable force), never
  the headline. Every serious runner lifts; this differentiates us from Runna without diluting focus.

**Non-negotiable guardrails (the risks, named):**
- **Adaptation is deterministic, bounded, and explainable.** HRV/sleep are noisy; a plan that lurches on
  one bad night feels broken and destroys trust. Rules-based, capped, always with a one-line reason,
  never a red "failed" state.
- **Fueling, not dieting.** Evidence-based fueling for the training in front of you. *(Amended
  2026-07-16: FUEL now includes light meal tracking — one sentence/photo per meal, AI-estimated
  kcal/carbs/protein/fat/sodium/fluids, judged by the deterministic `FuelReadiness` engine against
  the athlete's sessions.)* Every target is a FLOOR ("enough to fund the work"), never a ceiling:
  no deficits, no weight-loss framing, no diet ledger, no medical advice. Under-fueling gets the
  gentle warning — the health-positive direction for endurance athletes (RED-S runs on under-eating).
- **No medical claims, ever.** Injury guidance is general management + "see a professional," never a
  diagnosis. Beginners / health conditions get a "check with your doctor first" nudge.

---

## 2. Who it's for

Every stage, one adaptive engine, different starting point + horizon:

| Stage | Typical goal | What they need most |
|---|---|---|
| New runner | First 5K / run-walk to continuous | Gentle ramp, no injury, confidence, no shame |
| Improver | First 10K / half, get faster | Structure, easy/hard balance, progress they can see |
| Committed | First/faster marathon | Real periodization, taper, fueling, load management |
| Advanced | Ultra, PRs | Volume, back-to-backs, vert, recovery precision *(later phase)* |
| No-goal | "Get fitter and stay healthy" | Rolling safe progression, no peak/taper |

**Ultra is in the vision, not the first release.** Build 5K→marathon first; design the engine to extend
to ultra (back-to-backs, time-on-feet, vert, walk-break strategy, fueling-as-survival), ship ultra once
the core is proven.

---

## 3. What changes vs. what we keep

**Refocus (cheap):**
- IA + copy lead with running; strength demoted to a supporting section + "strength for runners" plan
  days. The strength logger, muscle map, and e1RM stay — just not the hero.
- Onboarding becomes an endurance-athlete profiler (§5).
- Today, Plan, and Progress lead with the run/route/data story.

**Keep / transfers (already built):**
- Engines: `GPSTrackingEngine`, VDOT/Riegel (`VO2maxEstimator`), `PlanEngine`, adaptation scaffolding
  (`RecoverySignals`, `RecoveryModel`, `PlanCoaching`), `StructuredWorkout`, `RouteDrawMap`.
- Design system (monochrome + iridescent-on-progress), name, wordmark, "keep moving."
- Progress metrics already present: VO2max + age/sex rating, CTL/ATL/TSB, and recent-to-usual load
  context.

---

## 4. Baseline fitness — knowing where to start them  ⭐ (deep dive)

**A plan is only as good as its starting estimate.** This is the first thing we get right. We resolve a
**baseline** = current fitness (→ VDOT + target paces) + safe starting load (weekly volume, longest run)
+ constraints. Sources, best available → fallback:

1. **Existing Momentum history.** Use only workouts the athlete recorded/saved in Momentum or restored
   through their Momentum account sync. Estimate current weekly volume, longest recent run, frequency,
   and pace-at-effort from that intentional history. **Apple Health never supplies or backfills workout
   history.**
2. **Recent race result.** Distance + time → VDOT/Riegel → current fitness + race predictions.
3. **Guided benchmark (no useful history).** Prescribed by experience:
   - Beginner → a **talk-test walk/run assessment** (how long can you run easy continuously), never a
     hard TT.
   - Improver+ → a short time trial (1 mile or 5-min hard, or Cooper 12-min) with a clear warmup/cooldown.
4. **Self-report (combine / fallback).** Experience, typical weekly mileage, longest run, comfortable
   pace, days available.

**Baseline confidence.** We store how sure we are (high = enough recent Momentum history or a recent
race; low = self-report). **Low confidence → start conservative and let the first 1–2 weeks calibrate**
from workouts recorded in Momentum (pace, RPE, HR, completion, and check-ins). This *is* the "learns
you" promise — the plan self-corrects instead of pretending to know.

**Also captured (drives the engine):** height, weight, sex, DOB (→ VDOT, HR zones, VO2max norms we
already use), injury history, days/week + minutes available, long-run day, terrain (treadmill/road/
trail), gym access, resting HR (from Health or entered), and max HR (entered, field-tested, or
estimated).

**Safety gate:** beginners and anyone flagging a health condition see a non-blocking "check with your
doctor before starting a new program" note.

---

## 5. Onboarding flow (endurance profiler)

Goal: understand the athlete fully, fast, and make it feel like a coach interview — not a form.

1. **Goal** — race (distance + date + optional goal time) OR "get fitter, no race." Branches everything.
2. **Discipline** — run (default) / ride / walk / hike / trail. Run-first; others map-based.
3. **Experience & history** — new / returning / consistent; injury history.
4. **Baseline** — §4 (Momentum history · recent race · benchmark · self-report).
5. **Body** — height, weight, sex, DOB.
6. **Availability** — days/week, long-run day, minutes/session, terrain, gym access.
7. **Connect Apple Health** — §7 (recovery signals from today forward; never workout import).
8. **Plan intensity** — Take your time / Balanced / Aggressive (§6), with the honest time-to-goal check.
9. **Reveal** — "your plan is ready" with the **map route animation** (§13).
10. **Notifications** — the Runna-style reminder primer (already built).

Keep the welcome aesthetic (Space Grotesk + serif + the photo background) throughout.

---

## 6. Plan engine — periodization, intensity tiers, honesty  ⭐ (deep dive)

### 6.1 Real periodization
Not a list of runs — mesocycles: **Base → Build → Peak → Taper → Race → Recover**, with:
- **Down weeks every 3–4 weeks** (cutback in volume/intensity).
- A **mostly-easy** intensity distribution with quality scaled to event, phase, experience, and
  frequency. The familiar 80/20 split is a reference, not a universal rule.
- Long-run progression caps; weekly volume ramp caps.
- Workout library: easy, long, recovery, tempo/threshold, intervals/VO2, strides, hills, race-pace,
  time trials, plus **strength-for-runners** and **cross-training** days.

### 6.2 The workload progression governor
`ACWRGovernor` (legacy type name) compares a planned week with its trailing four-week average and
reduces abrupt volume increases beyond the app's conservative 1.3× planning limit. That limit is a
deterministic **product guardrail**, not an injury threshold, a universal safe zone, or permission to
add work below it. The ratio describes exposure change only. Athlete-reported pain, illness, session
response, recovery signals, experience, and schedule still govern the decision. Structural recovery
changes require corroborating inputs and remain bounded and throttled.

### 6.3 Intensity tiers — Take your time / Balanced / Aggressive
After baseline + goal, the athlete chooses how hard to push. Same destination, different ramp + risk:

| Tier | Volume ramp | Down weeks | Hard sessions/wk | Best for | We tell them |
|---|---|---|---|---|---|
| **Take your time** | ~5–8%/wk | more frequent | fewer | beginners, returning runners, busy | "Lowest build pressure, most recovery margin." |
| **Balanced** *(default)* | ~8–10%/wk | every 3–4 | standard | most runners | "The recommended path." |
| **Aggressive** | faster, higher peak | fewer | more | experienced runners with a current base | "Fastest feasible build, least recovery margin; we'll pull back sooner when your response calls for it." |

Aggressive plans are held to a **tighter adaptive leash**: the recovery and athlete-feedback
guardrails watch load response more closely and deload earlier. It is never offered as a shortcut
around an infeasible goal.

### 6.4 Honesty engine (be truthful about time)
Compute **weeks available** vs **weeks needed** for a safe build to the goal from current fitness. If the
race is too soon:
- Never sell a fantasy. Say it plainly:
  > "A safe first-marathon build from where you are is ~16 weeks. You have 9. Honest options:"
  > 1. **Target a realistic finish for this race** (~predicted time), or
  > 2. **Move the race** (suggest a date), or
  > 3. **Run the half now, marathon later.**
  > "An aggressive plan adds training pressure and leaves less recovery margin. It does not make an
  > infeasible goal safe or realistic."
- This honesty is a **feature and a trust differentiator**, not a limitation.

### 6.5 No-goal mode
A rolling "get fitter, stay healthy" plan: progressive but with **no peak/taper**, periodic down weeks,
and a gentle fitness ceiling scaled to their availability. They can convert to a race plan anytime.

### Principle: deterministic numbers, AI narrates.
Loads/paces/volumes are rules-based and testable. The LLM authors rationale and bounded tweaks only.

---

## 7. HealthKit + wearables (recovery input)

**The connect step copy (friendly, precise, benefit-first):**

> **Train with your whole picture**
> Connect Apple Health and Momentum starts learning your recovery signals — sleep, HRV, resting heart
> rate, and more — from today forward, so your coaching can respond as your personal baseline forms.
> Wear an **Oura, Garmin, Whoop, or Apple Watch**? Supported signals they write to Apple Health can
> contribute too; availability depends on the device and its Apple Health permissions.
> Your workout journal stays intentional: connecting Health never imports history or creates a
> Momentum workout. You control each permission and can disconnect anytime.
> **[Connect Apple Health]** · *Maybe later*

**Read as signals:** sleep, HRV, resting and walking heart rate, respiratory rate, wrist temperature,
VO2max, body mass, and steps. `HealthService.workoutSpans(from:to:)` may read workout **time windows
only** so a known session is not double-counted as incidental movement; it never returns workout
content and never creates a `Workout` row.

**Write:** after the athlete completes and saves a Momentum workout, the app may write that completed
workout outward to Apple Health with permission. This does not make Apple Health a source of Momentum
workouts. There is no history scan, workout backfill, or import action anywhere in the product.

Apple Health is the one wearable-signal bridge. Momentum does not promise that every third-party
device writes every supported signal, and it does not present connection as a Garmin/Oura/Whoop
workout import.

---

## 8. Adaptation — recovery engine + injury loop  ⭐ (deep dive)

Two inputs feed one adaptive coach: **data-driven** (HRV/sleep/RHR/load) and **athlete-reported**
(check-ins + injuries). Both produce **bounded, deterministic, explainable** plan changes. Never shame.

### 8.1 Recovery / readiness engine
- Signals: HRV trend, resting HR trend, sleep (duration + consistency), athlete check-in, and
  recent-to-usual training-load context. `MorningReadiness` is a low-confidence context index with
  visible signal coverage, not a physiological clearance score.
- Output → bounded daily or weekly reductions only when independent inputs agree, each with a plain
  reason. Positive-looking data never adds work or overrides what the athlete reports.
- Multi-signal load-response guardrail: much-higher-than-recent load plus an out-of-norm recovery
  signal may force a bounded cutback. It does not diagnose overtraining or predict injury.
- Missed sessions: no-shame reschedule (already `reconcileMissed`), never "failed."

### 8.2 Injury loop (athlete-reported)  ⭐
**Inputs:**
- **Pre-run / daily check-in** (10 seconds): energy, legs (fresh/heavy/sore), any pain? (sleep auto from
  Health). Post-run RPE already exists.
- **"Report an issue"** flow: body area (shin, calf, knee, ankle, foot, hip, IT band, hamstring,
  Achilles, back), quality (sharp / dull / ache), timing (during / after / constant), and severity:
  1. **Twinge** — mild, no change to how you run.
  2. **Moderate** — hurts / changes your gait but you can run.
  3. **Severe** — can't run / sharp pain.

**Classification → plan response (rules-based, non-medical):**

- **Mild/no movement change:** remove intensity, reduce aggravating work, and ask the athlete to
  monitor during and after. No diagnosis or home-treatment prescription.
- **Pain changes gait or function:** stop impact work; offer non-impact activity only when the athlete
  reports it is comfortable; recommend qualified assessment when it persists, worsens, or concerns
  them.
- **Severe or red-flag report:** stop generated running guidance and strongly recommend appropriate
  professional/urgent assessment. The app does not decide that cross-training is suitable.

- **Never diagnose.** Describe management + red flags ("sharp pain, swelling, or can't bear weight → stop
  and see a professional"). No "this is shin splints."
- Comfortable cross-training can maintain routine and some aerobic stimulus, but it is not counted as
  proof that running tolerance or fitness was preserved.
- **Honest re-timing:** re-check feasibility after the interruption and widen uncertainty; never claim
  an exact amount of fitness was lost.

**Return-to-run progression:** when the athlete reports improvement and any advised professional
guidance allows it, use a conservative walk/run progression gated by symptom/function checkpoints.
Advance only when the athlete reports the current step remains acceptable during and after; hold or
back off when symptoms recur, and do not overrule professional guidance.

**Narration + record:** "We're reducing the aggravating work and protecting the continuity we can.
Here's the next conservative step." Logged in adaptation history + the bell inbox.

Together, §8.1 + §8.2 are the **"actually adapts"** moat.

---

## 9. Live run guidance (trainer, not just tracker)

Real-time audio + haptic coaching through a structured workout ("400 m at 4:30 — go … ease off, recovery
jog"), pace/HR targets, interval countdowns, and encouragement. This is Runna's #1 weakness and where we
earn "trainer." Extends `StructuredWorkout` + `RUNNING-EXCELLENCE.md`.

## 10. Heart-rate zones
Estimate max HR / LTHR (Health or a field test) → 5 zones → prescribe by pace **and** HR, and show a
post-run zone distribution. Currently missing; needed for pro-grade plans and data.

## 11. Fueling (safe, evidence-based)
Long-run + race fueling: carbs/hr by duration, hydration, pre/during/post timing, and a race-day plan.
General and evidence-based. **Not** calories/macros/dieting/medical.

---

## 12. Pro data — Progress & Plan pages (the "worth-billions" feel)

Inspiration: Garmin / COROS / Oura restraint + clarity. Our monochrome canvas, iridescent reserved for
earned progress. Beautiful, legible, honest charts.

**Progress:**
- **Fitness / Fatigue / Form** (CTL / ATL / TSB) — the training-load story.
- **VO2max** trend + age/sex rating + the range bar (done) with the ⓘ method note (done).
- **Weekly volume** + **intensity distribution** (80/20 check).
- **HR & pace zones** distribution.
- **Race predictions** (Riegel/VDOT) with confidence.
- **Recovery & sleep** trends; **recent-to-usual load-change** context with no universal target band.

**Plan:**
- Structured **week view** with the periodization phase label (Base/Build/Peak/Taper) and current
  intensity tier.
- **Workout detail**: structured intervals, target paces + HR, coach rationale, and a fueling note on
  long runs.
- Strength-support days; adaptation history (why the plan changed).

## 12.1 Coaching touchpoints + notifications
Weekly check-in summary, pre-race briefing, post-race analysis, race countdown, recovery nudges,
missed-workout (no-shame). Home = the bell inbox (built).

---

## 13. Design & animation

Keep monochrome + iridescent (earned-only), Space Grotesk + Inter + serif, tabular figures, transform-
only animation at 60fps, honor Reduce Motion.

**Plan-reveal animation — replace the body/muscle animation with a MAP ROUTE animation.**
On "your plan is ready," a **clean, high-end map animation of a real-looking route being run**:
- A **self-drawing route** traces along a plausible real path (streets/park loop) — reuse
  `RouteDrawMap` (the onboarding self-drawing route) + our centripetal-spline smoothing so the line is
  buttery, not jagged.
- The trace draws in the **brand iridescent** (earned), led by the **purple location puck** (a runner
  moving along the route). Camera gently follows the head of the line.
- Ends settling on the finished route with the plan summary revealing over/after it.
- **Reduce Motion:** static finished route + crossfade.
- Why: it's on-brand for a map-first running app, ties the reveal to *what you'll actually do*, and
  feels premium — a runner covering a real route, not an abstract body.

Running-first motion language throughout (route draws, pace, distance) over strength/muscle motifs.

---

## 14. Safety & legal
- No medical claims. Injury guidance = general management + "see a professional." No diagnosis.
- "Check with your doctor before starting" for beginners / flagged conditions.
- Fueling is general and evidence-based, never personalized nutrition/medical.
- Apple Health supplies recovery signals and workout time windows only; it never supplies Momentum
  workouts. Completed Momentum workouts may be written outward with permission. Disconnect anytime;
  owner-only sync applies to Momentum's own cloud data.

## 15. Monetization
Pro = the adaptive engine + wearable-driven recovery/injury adaptation + live guidance + pro data +
fueling. Free = tracking + a basic plan. (Paywall redesigned; purple accent.) The depth *is* the reason
to pay.

## 16. Non-goals (for now)
Ultra-specific training (later), **social feed/kudos (built, back-burnered from v1 2026-07-16 —
code + Supabase backend preserved; ships solo-first, "Bevel for endurance athletes", and the feed
returns once a real user base exists)**, dieting/weight-loss coaching (never — fueling-readiness
meal tracking shipped 2026-07-16 is floors-only, see the guardrail above), non-endurance sports as
a headline (trackable, not marketed).

---

## 17. Phased execution

- **Phase 0 — Positioning & IA** (small): running-first reframe; demote strength to supporting; copy.
- **Phase 1 — Deep onboarding + baseline** (medium): endurance profiler, **baseline fitness** (§4)
  from Momentum history/race/benchmark/self-report, goal-feasibility guardrails, body metrics, and
  **Apple Health signal connection** (§7) with no workout import.
- **Phase 2 — Adaptive engine** (large, the moat): recovery/readiness (§8.1) + **injury loop** (§8.2) +
  workload progression governor (§6.2) + intensity tiers + honesty engine (§6.3–6.4).
- **Phase 3 — Pro data & plan UI** (large): Progress + Plan redesign (§12), **HR zones** (§10), **live
  run guidance** (§9).
- **Phase 4 — Fueling** (medium): §11.
- **Cross-cutting:** the **map-reveal animation** (§13) lands with Phase 1's reveal.

Start Phase 0 + 1. Phase 2 is what makes or breaks the bet.
