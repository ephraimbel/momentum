# Coaching-Loop Audit — does the plan actually adapt?
### How the AI + training plan works today, where it's good, and what's missing for a real adaptive coach

> Audited 2026-06-10 against the live code (`PlanEngine`, `PlanCoaching`, `AthleteModelEngine`,
> `AIService`, edge functions, `NotificationService`). Grounded in file:line evidence. Honors the
> PRD §9 principle: **the deterministic engine computes numbers; the AI only narrates/proposes.**

---

## 1. The lifecycle today (onboarding → app), step by step

1. **Onboarding** (`OnboardingViewModel.finish`): builds a `UserProfile`, then
   `PlanService.regenerate(...)` runs `PlanEngine.generate` to create a 4–16 week `TrainingPlan`, and
   `AthleteModelService.seedOnboarding` writes 2 identity/motivation notes. A 5k pace (`p5kSPerKm`) is
   set from the optional calibration run (Riegel) or an experience default (new 6:00/km, some 5:30,
   experienced 5:00).
2. **Plan generation** (`PlanEngine`): macrocycle of build weeks (+8%/wk volume), a deload every 4th
   week (×0.7), and a 3-week taper if a race date is set. Running paces are offsets from p5k (easy
   +80 s/km, long +90, tempo +20, intervals +0). Hybrid scheduling guarantees a hard run never lands
   the day after a heavy lower-body lift. Strength splits are equipment-aware (Full Body → PPL by days).
3. **A workout happens.** On finish (`TodayView.finish`): the planned session is marked complete (or a
   free workout is *credited* to today's matching session), and `athleteModel.ingest` recomputes the
   Athlete Model from full history.
4. **Post-workout read** (`WorkoutReadTemplates` / `AIService`): a ≤55-word narrative. If Supabase is
   configured, the `workout-analysis` edge function can return richer text **plus** a `planAdjustment`
   and `memoryUpdates`; otherwise a deterministic template runs. The moment never blocks.
5. **Missed sessions** (`PlanCoaching.reconcileMissed`, on Today appear): past still-planned sessions
   **move** to the next open day — never a red "failed" state. ✅ no-shame, working.
6. **The only adaptation knob** (`PlanCoaching.apply`): the Progress tab shows an ACWR-based rec
   (increase / ease / rest); the user **taps a button** to apply ±10–15% to *future* sessions.

---

## 2. Verdict — plan quality is good; the loop is open

**What's genuinely good (keep it):**
- Sound periodization: build/deload/taper, ~80/20 easy-to-quality, one quality session/week.
- Sensible runner paces from a real model (Riegel + Daniels-style offsets).
- Smart hybrid recovery scheduling (the squat→hard-run invariant is even unit-tested).
- Deterministic + testable (113+ tests). No medical claims. No-shame rescheduling.

**The core problem: the plan is essentially _static after onboarding._** Performance does not change
future training. The system *computes* the right adaptive signals but never feeds them back.

---

## 3. The gaps (what "progressively adjusts + notifies" needs vs. what exists)

| Capability the user asked for | Status | Evidence |
|---|---|---|
| Re-calibrate paces as the runner gets fitter | ❌ none | `p5kSPerKm` set once at onboarding; never updated. `AthleteModelEngine` computes `paceAtEffortTrendPct` but **nothing consumes it** for the plan. |
| Strength load/volume progresses on performance | ❌ none | `GeneratedExercise.progression` ("double"/"linear"/…) is stored but **never applied**; next week's weights/reps don't move from what you logged. |
| Plan auto-adjusts to actual fatigue (ACWR) | ⚠️ manual only | `PlanCoaching.apply` exists and is good, but only runs on a **button tap** in Progress. ACWR is computed continuously; nothing acts on it automatically. |
| "I updated your next workout because…" updates | ❌ none | `NotificationService` is a **stub**; `scheduleRest` is a no-op. Zero local/push notifications anywhere. |
| AI proposes plan changes | ⚠️ wired one-way | `workout-analysis` returns `planAdjustment` and `coach-chat` returns an `adjustPlan` action — **neither is acted on** in-app; the read shows the text only. |
| Athlete Model → plan | ❌ disconnected | The model is display-only ("You" surface + narrative). No path from `AthleteModel` into `PlanEngine`/`PlanCoaching`. |
| Learn missed-day patterns | ❌ none | `reconcileMissed` reschedules but doesn't learn (e.g., "you always miss Tuesdays → move quality off Tuesday"). |

**Runner-specific notes:** paces are good but **intervals are prescribed at exactly 5k pace** (`+0`),
which is conservative for true VO2 work (400 m reps usually run faster than 5k pace). And the
single most valuable runner moment — *"your easy pace dropped, you're getting fitter, here are your
new paces"* — never happens, even though `paceAtEffortTrendPct` already measures exactly that.

---

## 4. Proposed fix — close the loop (phased; deterministic computes, AI narrates)

**P1 — Recalibrate from reality (runners first; highest ROI; the data already exists).**
After a run, compute its Riegel 5k-equivalent from actual distance+time (gated by effort/RPE so easy
runs don't count). If it (or a confident negative `paceAtEffortTrendPct`) beats the stored p5k, lower
`plan.p5kSPerKm` (bounded, e.g. ≤3%/update) and re-derive **future** session paces. This is the
"the app is learning me" moment. ~Self-contained in `PlanCoaching` + the finish flow.

**P2 — Performance-based progression (close the volume/load loop).**
- *Strength:* actually apply `progression`. Compare logged working sets to targets: hit top of range
  at/under target RPE → bump next occurrence (double progression / +load); missed reps or RPE too high
  → hold or shave. Writes next session's targets.
- *Running:* scale the next week's ramp by adherence + perceived effort instead of a fixed +8%.

**P3 — Auto-adaptive load (use ACWR without a tap).**
Run the ACWR rec automatically on a cadence (post-workout/daily), apply **bounded** changes once, and
surface a no-shame coach note. Reuse `PlanCoaching.apply` (mind the compounding caveat already noted
in its docs).

**P4 — Notifications / updates (the explicit ask).**
Implement `NotificationService`: (a) next-workout reminder the morning of a planned session
("Today: 8 km easy ~6:20/km"); (b) a "plan updated" nudge when an adaptation fires ("Eased this
week ~15% — your load was climbing"); (c) the stubbed rest-timer notification. Gate on the onboarding
notifications primer.

**P5 — Let the AI _propose_ (wire what already returns).**
Act on `workout-analysis.planAdjustment` and the coach `adjustPlan` action: the AI suggests, the
deterministic engine computes and applies on confirm ("Add a tempo Thursday? [Apply]"). Keeps the
"rules compute, AI narrates" contract.

**Recommended order:** P1 → P4 → P2 → P3 → P5. P1 makes runners feel the adaptation immediately; P4
makes it *visible* (updates); P2/P3 deepen it; P5 adds the conversational layer.

---

## 5. Principle compliance for the fixes
- [ ] All new numbers come from the deterministic engine; AI only narrates/proposes.
- [ ] Adaptations are **bounded** (no runaway compounding — see `apply` caveat) and **no-shame**.
- [ ] Recalibration gated by effort/confidence (don't drop paces off one easy jog).
- [ ] No medical claims; honors Reduce-Motion/notification permission.
- [ ] Every change reconstructable + unit-tested (fixtures for "fitter → faster paces", "missed reps → hold").

## Key files
`Engines/PlanEngine.swift` · `Engines/PlanCoaching.swift` · `Engines/AthleteModelEngine.swift` ·
`Engines/ProgressInsights.swift` (ACWR/rec) · `Services/AthleteModelService.swift` ·
`Features/Today/TodayView.swift` (`finish`) · `App/Services.swift` (NotificationService stub) ·
`supabase/functions/{workout-analysis,coach-chat,plan-narrate}`
