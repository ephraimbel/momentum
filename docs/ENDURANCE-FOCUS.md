# Momentum — Endurance Focus (Repositioning + PRD)

> **Status:** Strategy locked, execution pending. This document supersedes the "hybrid athlete"
> positioning in `PRD.md` §1 for everything going forward. The engines, design system, and data model
> in `PRD.md` still stand — this is a **refocus, not a rebuild**.

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
- Strength stays as a **supporting pillar** (strength-for-runners: economy + injury prevention), never
  the headline. Every serious runner lifts; this differentiates us from Runna without diluting focus.

**Non-negotiable guardrails (the risks, named):**
- **Adaptation is deterministic, bounded, and explainable.** HRV/sleep are noisy; a plan that lurches on
  one bad night feels broken and destroys trust. Rules-based, capped, always with a one-line reason,
  never a red "failed" state.
- **Fueling, not dieting.** Evidence-based long-run/race fueling + hydration only. No calories/macros/
  medical/weight advice.
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
- Progress metrics already present: VO2max + age/sex rating, CTL/ATL/TSB, ACWR band.

---

## 4. Baseline fitness — knowing where to start them  ⭐ (deep dive)

**A plan is only as good as its starting estimate.** This is the first thing we get right. We resolve a
**baseline** = current fitness (→ VDOT + target paces) + safe starting load (weekly volume, longest run)
+ constraints. Sources, best → fallback:

1. **Import from Apple Health (preferred, zero effort).** Read the last ~8–12 weeks of runs → estimate
   VDOT from best sustained efforts, current weekly volume, longest recent run, typical easy pace, run
   frequency. If they have history, we already know a lot — this is the "wow, it gets me" moment.
2. **Recent race result.** Distance + time → VDOT/Riegel → current fitness + race predictions.
3. **Guided benchmark (no history).** Prescribed by experience:
   - Beginner → a **talk-test walk/run assessment** (how long can you run easy continuously), never a
     hard TT.
   - Improver+ → a short time trial (1 mile or 5-min hard, or Cooper 12-min) with a clear warmup/cooldown.
4. **Self-report (combine / fallback).** Experience, typical weekly mileage, longest run, comfortable
   pace, days available.

**Baseline confidence.** We store how sure we are (high = imported data or recent race; low =
self-report). **Low confidence → start conservative and let the first 1–2 weeks calibrate** from actual
runs (paces, RPE, HR). This *is* the "learns you" promise — the plan self-corrects instead of pretending
to know.

**Also captured (drives the engine):** height, weight, sex, DOB (→ VDOT, HR zones, VO2max norms we
already use), injury history, days/week + minutes available, long-run day, terrain (treadmill/road/
trail), gym access, resting HR & max HR (from Health or estimated).

**Safety gate:** beginners and anyone flagging a health condition see a non-blocking "check with your
doctor before starting a new program" note.

---

## 5. Onboarding flow (endurance profiler)

Goal: understand the athlete fully, fast, and make it feel like a coach interview — not a form.

1. **Goal** — race (distance + date + optional goal time) OR "get fitter, no race." Branches everything.
2. **Discipline** — run (default) / ride / walk / hike / trail. Run-first; others map-based.
3. **Experience & history** — new / returning / consistent; injury history.
4. **Baseline** — §4 (import Health · recent race · benchmark · self-report).
5. **Body** — height, weight, sex, DOB.
6. **Availability** — days/week, long-run day, minutes/session, terrain, gym access.
7. **Connect Apple Health** — §7 (the recovery + wearables step, with the friendly copy).
8. **Plan intensity** — Take your time / Balanced / Aggressive (§6), with the honest time-to-goal check.
9. **Reveal** — "your plan is ready" with the **map route animation** (§13).
10. **Notifications** — the Runna-style reminder primer (already built).

Keep the welcome aesthetic (Space Grotesk + serif + the photo background) throughout.

---

## 6. Plan engine — periodization, intensity tiers, honesty  ⭐ (deep dive)

### 6.1 Real periodization
Not a list of runs — mesocycles: **Base → Build → Peak → Taper → Race → Recover**, with:
- **Down weeks every 3–4 weeks** (cutback in volume/intensity).
- **80/20** easy/hard intensity distribution (polarized).
- Long-run progression caps; weekly volume ramp caps.
- Workout library: easy, long, recovery, tempo/threshold, intervals/VO2, strides, hills, race-pace,
  time trials, plus **strength-for-runners** and **cross-training** days.

### 6.2 The safety governor (ACWR)
We already compute **acute:chronic workload ratio**. Wire it into *generation*: the plan physically
cannot ramp load into the injury-risk zone (ACWR > ~1.5). This is a hard constraint on every week the
engine produces and on every adaptation it makes.

### 6.3 Intensity tiers — Take your time / Balanced / Aggressive
After baseline + goal, the athlete chooses how hard to push. Same destination, different ramp + risk:

| Tier | Volume ramp | Down weeks | Hard sessions/wk | Best for | We tell them |
|---|---|---|---|---|---|
| **Take your time** | ~5–8%/wk | more frequent | fewer | injury-prone, beginners, busy | "Lower injury risk, most sustainable." |
| **Balanced** *(default)* | ~8–10%/wk | every 3–4 | standard | most runners | "The recommended path." |
| **Aggressive** | faster, higher peak | fewer | more | experienced, low-risk, motivated | "Max fitness — **higher injury/burnout risk**; we'll watch your recovery harder and pull back sooner." |

Aggressive plans are held to a **tighter adaptive leash**: the recovery + injury governors watch load/
HRV more closely and deload earlier. Pushing hard is allowed; pushing hard *blindly* is not.

### 6.4 Honesty engine (be truthful about time)
Compute **weeks available** vs **weeks needed** for a safe build to the goal from current fitness. If the
race is too soon:
- Never sell a fantasy. Say it plainly:
  > "A safe first-marathon build from where you are is ~16 weeks. You have 9. Honest options:"
  > 1. **Target a realistic finish for this race** (~predicted time), or
  > 2. **Move the race** (suggest a date), or
  > 3. **Run the half now, marathon later.**
  > "An aggressive plan gets you closer but raises injury risk — here's the tradeoff."
- This honesty is a **feature and a trust differentiator**, not a limitation.

### 6.5 No-goal mode
A rolling "get fitter, stay healthy" plan: progressive but with **no peak/taper**, periodic down weeks,
and a gentle fitness ceiling scaled to their availability. They can convert to a race plan anytime.

### Principle: deterministic numbers, AI narrates.
Loads/paces/volumes are rules-based and testable. The LLM authors rationale and bounded tweaks only.

---

## 7. HealthKit + wearables (recovery input)

**The connect step copy (friendly, read-only, benefit-first):**

> **Train with your whole picture**
> Connect Apple Health and Momentum learns how you're *actually* recovering — your recent runs, heart
> rate, sleep, and resting heart rate — so each week adapts to you instead of following a generic
> template.
> Wear an **Oura, Garmin, Whoop, or Apple Watch**? They already sync to Apple Health, so connecting
> once brings all of it in — no separate logins.
> It's **read-only**, it stays **on your device and in your control**, and you can disconnect anytime.
> **[Connect Apple Health]** · *Maybe later*

**Read (read-only):** workouts, distance/pace, heart rate, resting HR, HRV (SDNN), sleep, active energy,
VO2max (if present), body mass, DOB, sex. Apple Health is the single integration — Garmin/Oura/Whoop/
Watch all sync into it, so we cover them with one connection and no fragile third-party APIs (matches
the "connect to Garmin = Apple Health import" decision).

---

## 8. Adaptation — recovery engine + injury loop  ⭐ (deep dive)

Two inputs feed one adaptive coach: **data-driven** (HRV/sleep/RHR/load) and **athlete-reported**
(check-ins + injuries). Both produce **bounded, deterministic, explainable** plan changes. Never shame.

### 8.1 Recovery / readiness engine
- Signals: HRV trend, resting HR trend, sleep (duration + consistency), training load (CTL/ATL/TSB),
  ACWR. Build the real readiness score on top of `RecoverySignals`/`RecoveryModel`.
- Output → bounded weekly adjustments: keep / ease intensity / insert recovery / recommend a down week —
  each with a plain reason ("Easy week — your HRV's been low and sleep short for 4 days").
- Overtraining tripwire: ACWR too high + HRV suppressed + RHR elevated → force a cutback.
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
| Severity | Running | Fitness preservation | Guidance (general only) |
|---|---|---|---|
| Twinge | keep easy, cut intensity, add mobility | full | monitor; ice/mobility |
| Moderate | rest the impact; cross-train (bike/pool) | maintain via cross-training | RICE; if not improving in ~3–5 days, see a physio |
| Severe | stop running | non-impact cross-train only if pain-free | **strongly recommend seeing a professional**; return-to-run gated |

- **Never diagnose.** Describe management + red flags ("sharp pain, swelling, or can't bear weight → stop
  and see a professional"). No "this is shin splints."
- **Cross-training preserves CTL** so a pause doesn't crater fitness.
- **Honest re-timing:** "This 5-day pause costs ~X of fitness; your goal is still realistic / here's the
  adjusted target."

**Return-to-run progression:** when the athlete reports feeling better, a **walk/run ramp gated by
pain-free checkpoints** (e.g., 20-min walk pain-free → 1-min run / 2-min walk × 8 → …). Advance only if
pain stays ≤ twinge; back off automatically if it flares.

**Narration + record:** "Injuries happen to every runner — we're protecting your season. Here's the smart
way back." Logged in adaptation history + the bell inbox.

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
- **Recovery & sleep** trends; **ACWR / injury-risk** band.

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
- HealthKit read-only, on-device, disconnect anytime; owner-only sync.

## 15. Monetization
Pro = the adaptive engine + wearable-driven recovery/injury adaptation + live guidance + pro data +
fueling. Free = tracking + a basic plan. (Paywall redesigned; purple accent.) The depth *is* the reason
to pay.

## 16. Non-goals (for now)
Ultra-specific training (later), social feed/kudos (deferred), personalized nutrition/dieting (never),
non-endurance sports as a headline (trackable, not marketed).

---

## 17. Phased execution

- **Phase 0 — Positioning & IA** (small): running-first reframe; demote strength to supporting; copy.
- **Phase 1 — Deep onboarding + baseline** (medium): endurance profiler, **baseline fitness** (§4) incl.
  Health import + goal-feasibility guardrails, body metrics, **Apple Health connect** (§7).
- **Phase 2 — Adaptive engine** (large, the moat): recovery/readiness (§8.1) + **injury loop** (§8.2) +
  ACWR safety governor (§6.2) + intensity tiers + honesty engine (§6.3–6.4).
- **Phase 3 — Pro data & plan UI** (large): Progress + Plan redesign (§12), **HR zones** (§10), **live
  run guidance** (§9).
- **Phase 4 — Fueling** (medium): §11.
- **Cross-cutting:** the **map-reveal animation** (§13) lands with Phase 1's reveal.

Start Phase 0 + 1. Phase 2 is what makes or breaks the bet.
