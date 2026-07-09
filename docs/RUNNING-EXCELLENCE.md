# Running Excellence — Runna teardown & integration plan

> Goal: make momentum's **running** experience best-in-class on its own — good enough that a
> pure runner who never lifts would still choose us — while keeping our hybrid (run + lift)
> and monochrome-iridescent identity. Runna is the bar. This doc maps Runna feature-by-feature
> onto our codebase, ranks what it costs us to *not* have, and sequences the build.
>
> Companion to [`EXECUTION-PLAN.md`](EXECUTION-PLAN.md) and [`COACHING-LOOP-AUDIT.md`](COACHING-LOOP-AUDIT.md).
> Status date: 2026-07-06.

---

## 1. What Runna actually is (teardown)

Runna is a **race-goal running coach**: you give it a goal (5K → ultra), current mileage,
days/week, and race date; it builds a periodized plan and then *guides you through every
session in real time* with audio. That last part — the live guided structured workout — is
its core moat, not the plan generation.

**Navigation (5 tabs + profile):**

| Tab | What it holds |
|---|---|
| **Today** | Today's session (run / strength / rest) + tips + weekly mileage + "Instant Workout" on-demand + **Plan Adjustment Tray** to realign after a missed run |
| **Plan** | **Pace Insights** (perf review + race-time estimate), **Manage Plan** (holidays, B-races, "Not Feeling 100%", ability/mileage/schedule, enable strength/yoga/pilates), drag-drop **Rearrange Workouts**, Connected Apps |
| **Activities** | Workout history (filters, manual log) + **Performance** (mileage trends, PRs, achievements, all-time stats) |
| **Community** | Polls, groups, races (social — we defer this; see [`SOCIAL-LAYER.md`](SOCIAL-LAYER.md)) |
| **Profile** | Runna Level, **shoe mileage**, HR zones, audio-cue config, parkrun barcode, Labs |

**The session model (their differentiator):** a workout is `warm-up → [reps @ target pace ×N with recoveries] → cool-down`. During it, the watch/phone shows the current step, distance left in the step, and current pace, and audio prompts: pace alerts ("speed up / slow down" when outside the target band), interval transitions, recovery countdowns, per-split pace readouts, and encouragement.

**The adaptive loop:**
- **Race predictor** — estimated finish time shown up-front and on the Race workout; updates as you train (method proprietary; behaves like Riegel/VDOT + cohort data).
- **Pace Insights** — after each speed session (intervals/tempo/time-trial), compares *achieved vs prescribed* pace and consistency, then labels you: *Pace on Point / Ahead of the Pack / Let's Review Your Pace / Variable Pace Detected / Monitoring*. If it detects a trend it recommends shifting your **training paces** (plan structure unchanged; user approves).
- **Post-run feedback** (2026) — prompts "how did that feel?" (RPE) which feeds the next block.
- **Plan difficulty × volume** — Progressive / Steady / Gradual volume, plus a difficulty knob controlling # and intensity of hard sessions.

Known weaknesses we can beat: subscription/cancellation friction, device-sync flakiness, and it's **running-only** — the strength/yoga is a bolt-on. Our hybrid engine already schedules hard runs to avoid heavy-leg days; Runna structurally can't coach that.

---

## 2. Gap analysis: Runna feature → our status

Grounded in the current codebase. ✅ = solid, 🟡 = partial/unwired, ❌ = absent.

| Capability | Runna | Us today | Where it lives / would live |
|---|---|---|---|
| Accurate live GPS (Kalman, outlier reject, auto-pause, durable) | ✅ | ✅ **strong** | `Engines/GPSTrackingEngine.swift`, `GPSProcessor.swift`, `GPSKalmanFilter.swift` |
| Live map w/ route + suggested-loop guide | ✅ | ✅ | `Features/Cardio/CardioTrackingView.swift` (`syncRouteLayers`) |
| Periodized race plan (progression, deload, taper, race-aware long run) | ✅ | ✅ **strong, deterministic** | `Engines/PlanEngine.swift`, `Models/TrainingPlan.swift` |
| Hybrid run/lift scheduling | ❌ (bolt-on) | ✅ **our edge** | `PlanEngine.schedule` (hard-run-not-after-heavy-legs invariant) |
| **Real-time structured workout guidance** (warmup/reps/recovery/cooldown, target-pace cues, rep countdown) | ✅ **core** | ❌ **biggest gap** | intervals are a `String?` shown as a chip; `Start` runs a plain free run (`WorkoutRunner.swift`) |
| Live audio coaching (pace alerts, interval transitions, recovery countdown, encouragement) | ✅ | 🟡 splits-only | `Services/VoiceCoachService.swift`, `Engines/CoachingCueBuilder.swift` |
| Live HR + HR zones | ✅ | ❌ (HR only via HealthKit *import*) | would extend `CardioViewModel` + `HealthService` |
| Live cadence | ✅ | 🟡 **hardware wired, not connected** | `Services/MotionService.swift` exists, never started in a run |
| Post-run **pace graph / splits chart / elevation profile / HR zones** | ✅ | ❌ (numbers + splits *text* only) | `Features/Summary/CardioSummaryView.swift`; Swift Charts already used in `Progress` |
| Per-split HR / cadence / elevation | ✅ | 🟡 **model fields exist, unpopulated** | `Split` in `Models/Workout.swift` (avgHR/avgCadence/elevDelta) |
| Race-time **predictor** surfaced to user | ✅ | ❌ (Riegel used only to seed paces) | `PlanEngine.riegelP5k` → surface projection |
| **Pace Insights** adaptive pace recs | ✅ | 🟡 **inputs exist** (fitness trend) | `Models/AthleteModel.swift`, `AthleteModelEngine.swift`, `PlanCoaching.swift` |
| Post-run RPE feedback → plan | ✅ | 🟡 (RPE used for load only) | `Engines/TrainingLoad.swift` (Foster session-RPE) |
| Race countdown + visible taper/periodization | ✅ | 🟡 **engine does it, UI doesn't show it** | `Features/Plan/PlanView.swift` |
| VO2max / CTL-ATL fitness-freshness / GAP / running power | ✅ (partial) | ❌ | new metrics in `Engines/` |
| Shoe mileage, HR-zone config screen | ✅ | ❌ | new `Features/Profile` surfaces |
| Plan adjustment tray (missed-run realign, "not 100%", B-races, holidays, drag-rearrange) | ✅ | 🟡 partial (`SessionDetailSheet` move/adjust) | `Features/Plan/` |
| Achievements / PRs / all-time stats | ✅ | 🟡 detected, not persisted as records | `Engines/CardioAchievements.swift` |

**Our existing edges Runna lacks:** true hybrid coaching, the **Athlete Model** long-term memory (our "private mirror" north star), the **muscle map**, route suggestion / Spots, and a monochrome-iridescent design language that reads far more premium than Runna's busy blue UI.

---

## 3. What it costs us to NOT have (priority tiers)

**Tier 1 — table stakes. A serious runner notices these missing in the first session.**
1. **Real-time structured workout guidance.** Without it we *prescribe* "6×400m @ 5K pace" and then abandon the runner to a stopwatch. This is the single feature that makes Runna feel like a coach. Highest cost, highest payoff.
2. **Rich post-run analysis (charts).** A text splits list looks like a 2015 app. Pace graph + elevation profile + HR zones is the "professional" tax.
3. **Live HR + zones.** Runners training by HR (most structured programs) cannot use us today.
4. **Wire cadence** (near-free — `MotionService` already exists).

**Tier 2 — the "coach" intelligence. Defines whether we're a tracker or a coach.**
5. **Race-time predictor** (surface what we already compute).
6. **Pace Insights adaptive loop** (achieved-vs-target → pace rec).
7. **Race countdown + visible periodization/taper** (surface the engine).
8. **Post-run RPE feedback → plan adaptation** (closes the open loop; see COACHING-LOOP-AUDIT).

**Tier 3 — depth & holistic polish.**
9. VO2max estimate + CTL/ATL fitness-freshness curve + GAP.
10. Shoe mileage, HR-zone config screen, persisted PRs/all-time stats.
11. Plan adjustment tray completeness (B-races, holidays, "not 100%", drag-rearrange).
12. Nutrition / race-week guidance (LLM-narrated, deterministic facts).

---

## 4. Build roadmap (sequenced, with integration points)

Each item follows our principles: **deterministic engine, AI only narrates; SI units stored; iridescence only marks progress; offline-first durable capture; honor Reduce Motion.**

### Phase R1 — Structured Workout Engine (the core) 🎯 — ✅ first slice shipped 2026-07-06
The one that matters most. Turn a prescribed interval session into a guided experience.

**Shipped in this pass** (compiles; 281 unit tests pass incl. 12 new):
- `Engines/StructuredWorkout.swift` — `WorkoutStep` / `StructuredWorkout` value types, `StructuredWorkoutBuilder` (parses the engine's `intervals` string + tempo + beginner run/walk into warm-up → reps → recovery → cool-down), and `StructuredRunTracker` (pure live-progress logic: current step, remaining, on-pace band, advance/skip). All deterministic + tested.
- `CoachingCueBuilder` — step-start / pace-nudge / completion cues (`spokenTarget`).
- `CardioViewModel` — holds the tracker, a 1 Hz advance task (fires cues, decoupled from GPS-fix cadence so timed recoveries count down while standing), throttled pace nudges, `skipStep()`, and step display state.
- `CardioTrackingView` — the live step banner: title/rep, big count-down, target pace, progress bar, rep dots, next-step preview, Skip; **iridescent border + bar when on pace** (earned accent = hitting the prescription). Completion pill.
- `WorkoutRunner` threads the built workout; `SessionDetailSheet` shows a grouped "Workout" step breakdown before you start.
- Tests: `MomentumTests/StructuredWorkoutTests.swift`.

**Hardened + verified (second pass):**
- Bug fixes: pace nudges suppressed while paused (stale pace → false cue); a 10 s per-step grace before nudging so EMA lag doesn't open a rep with a spurious "pick it up"; a "get ready" haptic as a timed recovery ends.
- **Live end-to-end verified in the simulator:** `--ui-test-structured-run` deep link launches a guided 6×400 m session on a synthetic GPS track; `MomentumUITests/StructuredRunUITests` drives the real banner `WARM UP → REP 1/6 → RECOVERY → REP 2/6 → … → Workout complete` via Skip (passes). Screenshot confirms the banner renders on-brand.
- Full suite green: **281 unit tests + the new UI test pass**; app compiles.

**Not yet done (follow-ups):** Watch mirroring of the current step; moving step generation into `PlanEngine` + persistence for per-step editing; per-second recovery 3-2-1 count (only a single end-of-recovery buzz today).

Original design notes below still hold for the follow-ups.

- **Model:** introduce a real step model. Replace/augment `PlannedSession.intervals: String?` with
  `[WorkoutStep]` where `WorkoutStep = { kind: .warmup/.rep/.recovery/.cooldown/.steady, target: .pace(range)/.duration/.distance, value }`. Keep the human string as a derived display label (backward-compatible). Parse the existing generator output in `PlanEngine.cardioSessions` (line ~157) into steps at generation time — the loads are still rules-based.
- **Executor:** new `StructuredRunEngine` (actor) layered over `GPSTrackingEngine` — tracks current step, distance/time left in step, target-pace adherence (on/under/over the band), auto-advances steps, emits cue events. Durable: persist step progress alongside GPS samples so a cold-launch recovers mid-workout.
- **Live UI:** an overlay on `CardioTrackingView` — current step banner ("REP 3/6 · 400m @ 5:00/km"), distance-left ring, **target-pace adherence rendered as our earned iridescence** (glows iridescent when in-band, monochrome when off — iridescence = you're hitting the prescription, i.e. progress). Rep countdown, next-step preview.
- **Audio/haptic:** extend `CoachingCueBuilder` + `VoiceCoachService` with: step-start ("Rep 3, go — 400 meters at 5K pace"), pace alerts ("ease off" / "pick it up"), recovery countdown (3-2-1 haptic), rep-complete split readout, cooldown. Reuse the existing music-ducking. Gate advanced cues to Pro (matches VoiceCoach's current Pro gate).
- **Routing:** `WorkoutRunner.swift` branches — structured session → `StructuredRunView`, free run → existing path.
- **Watch:** mirror current step + distance-left + pace on the Watch app (Slices already exist; see `watch-phase5-status`).
- **Tests:** step parser fixtures; executor state-machine transitions (warmup→rep→recovery→…→cooldown, auto-advance thresholds) — Swift Testing, run the whole scheme.

### Phase R2 — Post-run analysis that looks pro
- Populate `Split.avgHR / avgCadence / elevDeltaM` in `CardioMetrics.splits` (fields already exist).
- Add charts to `CardioSummaryView` (Swift Charts already in the project): **splits bar chart**, **pace-over-distance line**, **elevation profile**, **HR-zone distribution + HR line**. Monochrome bars, iridescent only on PR/best-split markers.
- Route replay animation reusing `RouteReplay.swift` geometry.
- Persist PRs as real records (extend `CardioAchievements`) for an all-time Performance surface.

### Phase R3 — Live HR + cadence
- **Cadence:** start `MotionService` from `CardioViewModel` at run start; feed live cadence into the hero metrics and per-split (removes the `// TODO (Phase 1)` in `CardioMetrics.swift`).
- **HR:** start a HealthKit workout session (or BLE HR) during runs; live BPM + current zone chip on `CardioTrackingView`; store samples for the R2 HR charts. Add HR-zone config (from max-HR we already estimate via Tanaka at onboarding).

### Phase R4 — Coach intelligence (surface what the engines already know)
- **Race predictor:** project finish time from `p5kEquivSPerKm` (Riegel) in the Athlete Model; show on Plan + the race session, update weekly. Label conservative, flat-course caveat like Runna.
- **Pace Insights:** after speed sessions, compare achieved vs prescribed (we have both), classify (On Point / Ahead / Review / Variable / Monitoring), recommend a pace-target shift the user approves — recompute paces via `PlanEngine.pace(_:p5k:)` with an updated P5k. This *is* the close of the open coaching loop.
- **Race countdown + periodization view:** surface the macrocycle from `PlanEngine` (weeks, deload markers, taper phase) as a timeline in `PlanView` with a race-day countdown.
- **Post-run RPE prompt** feeding `PlanCoaching` adaptation.

### Phase R5 — Depth & holistic
- VO2max estimate, CTL/ATL/Form fitness-freshness curve (Banister), GAP for hilly routes.
- Shoe mileage tracking, persisted all-time stats/achievements surface.
- Plan adjustment tray completeness (B-races, holidays, "not feeling 100%", drag-rearrange — partially present in `SessionDetailSheet`).
- LLM-narrated nutrition / race-week guidance (deterministic facts, narrated text, templated fallback — same pattern as `workout-analysis`).

---

## 5. Our taste (how we stay us, not a Runna clone)

- **Iridescence = prescription hit.** On-pace glows oil-slick; off-pace is monochrome. The rep ring, the "you're in the zone" moment, PR splits — earned accents only, never chrome.
- **Space Grotesk hero numerals, tabular figures** on every live/logged number (pace, distance, countdown).
- **Calm, not busy.** Runna crams the screen. One hero metric + step context; everything else a glance away. True to the light-canvas / near-black-ink system.
- **Hybrid is the headline.** The plan view shows runs *and* lifts as one adaptive week; the muscle map + route art coexist. No competitor does both credibly.
- **Athlete Model as the moat.** The predictor, pace insights, and coaching read all speak from long-term memory ("your tempo pace has dropped 8s/km over 6 weeks") — the private mirror, not a generic algorithm.

---

## 6. Recommended first move

**Phase R1 (Structured Workout Engine).** It's the highest-cost gap, it's Runna's core, and it's the most self-contained: a step model + an executor actor + a live overlay + audio cues, all layered on GPS capture we already trust. Everything else (charts, HR, predictor) is additive polish; this is the one that changes what the app *is* for a runner.
