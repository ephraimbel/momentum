# Plan Quality Audit — are our plans real, or bull crap?

*2026-07-10. Benchmarks the shipped plan pipeline (onboarding → PlanEngine → adaptation) against established training science (Daniels/VDOT, Pfitzinger, Hansons, Higdon, Seiler 80/20, Lydiard, Norwegian method) and the current app field (Runna, TrainAsONE, Garmin DSW, TrainerRoad). Supersedes the plan-methodology parts of COACHING-LOOP-AUDIT.md (whose P1 adaptation items have since shipped).*

## Verdict

**Not bull crap — but not yet a real coach.** The engine is honest, bounded, safety-first, and its *adaptation* loop (recovery easing, RPE response, injury protocol, bounded pace recalibration, ACWR cap) is already ahead of Runna and most consumer apps. Where it falls short of a real plan is **structure**: paces come from crude fixed offsets instead of the VDOT zones we already compute, quality sessions rotate instead of progress, there's no peak phase, and several onboarding answers we *promise* will shape the plan (injury history, age) never touch generation.

Grade by area:

| Area | Grade | Why |
|---|---|---|
| Onboarding inputs | B+ | Collects the right things; missing resting HR; several fields unused |
| Initial pace prescription | C | Fixed additive offsets, not VDOT zones; intervals at 5K pace |
| Periodization / structure | C+ | Geometric ramp + deload is sound; no peak phase, rotation-not-progression |
| Load safety | A− | ACWR 1.3 cap matches Gabbett sweet spot; upgrade path is EWMA |
| Adaptation loop (running) | B+ | Recovery/RPE/injury/missed-session all live, throttled ≤1/week |
| Strength progression | C− | Double-progression lives only in the session prefill (`StrengthSessionEngine.progressedTarget`, +2.5 kg on full top-of-range); the plan's own linear/percent schemes and RPE-creep deloads are never applied week-over-week |
| Honesty | A | LLM decides zero numbers; no fake praise; no-shame ≠ dishonest |

---

## 1. What the science says a real plan needs (research summary)

### Pace prescription — Daniels/VDOT is the standard
- VDOT from a recent race via the Daniels–Gilbert equations:
  - `VO2 = -4.60 + 0.182258·v + 0.000104·v²` (v in m/min)
  - `%max = 0.8 + 0.1894393·e^(-0.012778·t) + 0.2989558·e^(-0.1932605·t)` (t in min)
  - `VDOT = VO2 / %max`; invert for equivalent times/paces at any distance.
- Zones as %VO2max: **E 59–74%, M ~84%, T 86–88%, I 95–100%, R >100%**. Zones are *curvilinear* — the easy-pace gap from 5K pace is much larger for slow runners than fast ones, which fixed additive offsets can't express.
- Golden fixture: **VDOT 50** ≈ 20:16 5K → E 8:59/mi, M 7:58/mi, T 7:29/mi, I 6:40/mi, R 6:16/mi.
- I-work: reps of 3–5 min at 95–100% VO2max (faster than 5K pace for most), jog recoveries of similar duration, single rep capped ~5 min.

### Structure
- **Phases:** Base ≈25% of plan / Build ≈45% / Peak 1–2 wk / Taper. Plan lengths: 10K 12–16 wk, half 14–18 wk, marathon 18–24 wk.
- **Taper (Bosquet 2007 meta, 27 studies):** 2 weeks, exponential volume cut **41–60%**, keep intensity AND frequency → ~2–3% performance gain. By distance: 5K ~1 wk, half ~2 wk, marathon 2–3 wk, ultra 3–4 wk.
- **Microcycle:** long run ≤30% of weekly volume; max 2 quality sessions/wk for most (3 = Hansons aggressive ceiling); never two quality days back-to-back; step-back week every 3rd–4th week.
- **Intensity distribution is phase-dependent:** pyramidal in base (~70/20/10), shifting polarized (~80/0/20) approaching the race (Seiler; elite observational data).
- **Frequency by level:** beginners 3 days/wk (same VO2max gain as 5, fewer injuries); intermediate 4–5; returns plateau >40 mi/wk.
- **The 10% rule is not evidence-based** (Buist 2007 RCT, n=532: identical injury rates at 10% vs ~50% ramps). Ratio-based load management (ACWR) is the defensible model.

### Adaptation
- **ACWR:** sweet spot **0.8–1.3**, >1.5 → 2–4× injury risk (Gabbett 2016; confirmed by 2025 meta of 22 cohorts). 7-day acute : 28-day chronic; **EWMA variant** beats naive rolling averages (mathematical-coupling critique).
- **HRV-guided training:** RCTs (Kiviniemi 2007/2010, Vesterinen 2016, Javaloyes 2019, Nuuttila 2017) — when 7-day rolling lnRMSSD is in the athlete's normal band, proceed; below band, swap to easy/rest. HRV-guided groups match or beat pre-planned with *fewer* hard sessions.
- **Pace bumps:** new race PR → recompute immediately; otherwise require **2–3 quality sessions finishing strong at target** before raising fitness ~1 VDOT point. Never off one great run. Refresh every 4–8 wk.
- **Missed training:** never cram; 1–2 days missed → resume where you are; longer gaps → restore only **50–75%** of lost volume over 4–6 wk; sick → skip, don't shift.
- **Return-to-run:** 5 phases (walk → walk/run → continuous easy → speed/hills → full); speed only at 50–60% of pre-injury mileage, normal training at 75–80%; structured RTR cuts re-injury up to 50%.
- **Masters (50+):** 4–5 days beats 6–7 at equal volume; hard/easy/easy spacing; deload every 3rd week; cut frequency, not intensity.

### What separates good apps from bad
- Runna's documented weaknesses: static templates (no auto week-to-week adaptation), over-positive feedback on failed sessions, intensity-heavy plans. Garmin DSW: physiologically adaptive but no race periodization. TrainAsONE: full-schedule recompute on every event (the bar for adaptivity). TrainerRoad: per-zone progression levels 1–10 — the cleanest performance-based difficulty model to port to running.
- Failure modes to encode as invariants: ramp beyond chronic load (ACWR >1.3), race-pace work off stale fitness, long run >30% of week, quality days adjacent, cramming missed volume, inflating failed workouts.

---

## 2. What we actually do (verified in code)

- **Paces:** P5k from Riegel on a benchmark / "by feel" table / HealthKit best effort (`BaselineEstimator`, conservative, 56-day window). Then **fixed additive offsets**: recovery +110, easy +80, long +90, tempo +20, intervals +0 s/km (`PlanEngine.pace`), with ad-hoc overrides vo2 = p5k−6, threshold = p5k+20.
- **Structure:** weeks = clamp(to race, 4–16); build = geometric ramp (gentle 1.05 / balanced 1.08 / aggressive 1.11 per wk); deload ×0.7 every 4th (5th aggressive) week; taper = fixed `[0.6, 0.45, 0.35]` for every distance; phases base/build/recovery/taper — **no peak**. Quality = `weekIndex % menu.count` rotation, not progression. Long-run caps by race distance are sensible (marathon min(32K, 0.76·race)).
- **Personalization that works:** current mileage + longest run seed week-1 volumes; calibration → paces; days/preferred days/session minutes → schedule; hybrid never puts a hard run after a heavy lower lift (unit-tested invariant).
- **Personalization that's fake:** injury history captured with copy promising "a safer ramp where you've been hurt" — `PlanInputs` has no injury field; generation never reads it. Age → only a Tanaka maxHR estimate; no masters spacing. Sex → strength suggestion only. Resting HR never asked → HR zones fall back to %max (the worst method — 85%max scatters athletes 87–116% of true threshold).
- **Safety/adaptation (live):** ACWR generation cap 1.3× trailing 4-wk avg; recovery easing needs ≥2 warning signals, today-only, 0.9×; tripwire ACWR>1.5 + body agreement → cutback week; RPE-gap easing; injury 3-tier protocol with gated return; pace recalibration bounded ≤3%/update, faster-only; everything throttled ≤1 structural change/week. LLM narrates only — verified, no numeric path.
- **Open loops:** strength progression is prefill-only — `progressedTarget` bumps the *suggested* weight at session time (double progression), but plan-level linear/percent schemes and RPE-creep deloads (PRD §9.2) never rewrite future prescriptions; "≥3 misses in 9 days → rebuild week at 70%" is in PRD §9.4 but unimplemented; no-race plans are a flat 4-week block; ultra unsupported (`RaceDistance` stops at marathon) despite "first 5K to first ultra" positioning.

---

## 3. Gap list, ranked by impact

1. ~~**Adopt VDOT zones for prescription**~~ — **SHIPPED 2026-07-10** (`DanielsPaces` engine). All training paces now derive from Daniels–Gilbert VDOT zones: recovery/long/easy at 60/64/66% VO₂max, tempo at one-hour-race intensity (~88.8%), intervals at vVO₂max, marathon = predicted marathon race pace (now used by progression runs, E→M→T thirds). Re-derivation preserves rep intent (`PlanEngine.sessionPace`: "@ 5K" stays race pace, "@ threshold" stays T). Golden-fixture tested against Daniels' published VDOT-50 row; 488 tests pass.
2. ~~**Wire injury history into generation**~~ — **SHIPPED 2026-07-10.** `PlanInputs.injuryHistory` now flows from onboarding into `PlanEngine.generate`: ramp + deload cadence capped at balanced when any history exists; quality selection steers away from the aggravating stimulus (lower-leg/knee/IT → hill reps become tempo; hamstring/hip → sprint reps and strides become threshold cruise work); every swap carries a one-line session rationale. The onboarding promise ("a safer ramp where you've been hurt") is now literally true.
3. ~~**Real periodization**~~ — **SHIPPED 2026-07-10.** `PlanEngine.mesocycle` now periodizes base (≈25%) → build → peak (1–2 wks holding max volume) → taper. Taper is distance-specific (5K/10K 1 wk, half 2, marathon+ 3, capped at ¼ of plan) and **keeps intensity** per Bosquet: volume falls to 45–70% of the *peak* week (the old absolute multipliers crash-tapered long plans) while every taper week keeps one short race-pace touch at the goal distance's predicted pace. Quality is phase-aware — pyramidal base (tempo/hills/fartlek, no sharpening), build reps *grow* week over week (progression, not rotation), peak goes race-specific. `GeneratedWeek.phase` is the single source of truth (persistence stops re-deriving); `PlanPhase` gained `.peak`.
4. ~~**Finish the strength loop**~~ — **SHIPPED 2026-07-10.** The prefill now honors every PRD §9.2 scheme (`StrengthSessionEngine.plannedTarget`): *linear* adds load when target reps were hit, *percent* prescribes %1RM × the best e1RM shown last session (so load tracks the athlete's actual strength both up and down), *double* unchanged. And the autoregulated deload exists: two consecutive strength sessions at sustained near-max RPE (≥8.5 mean over ≥3 rated sets each) → the coming week's planned sets are cut ~40% with a no-shame note (`PlanCoaching.easeStrengthOnRPECreep`), sharing the ≤1-change/week gate.
5. **Upgrade ACWR to EWMA** — still open (coordinate: another session owns the in-flight `ProgressInsights` ACWR rework). ~~The "≥3 misses → rebuild at 70%" trigger~~ **SHIPPED 2026-07-10**: `reconcileMissed` now detects a real absence (≥3 past-due sessions) and restarts the coming week at ~70% with quality softened to easy — the 50–75% restore rule, never cramming; naturally idempotent.
6. ~~**Resting HR at onboarding**~~ — **SHIPPED 2026-07-10.** Both Health-consent moments in onboarding (the calibration import and the health step) now also read resting HR (`importedBodyMetrics`) and persist it at finish, so HR zones use **Karvonen from the very first plan** instead of the %-max fallback (body mass backfills too if skipped). Still open from this item: requiring 2–3 confirming quality sessions before pace bumps (currently single-run triggered, though bounded ≤3% and faster-only).
7. ~~**Masters adjustments**~~ — **SHIPPED 2026-07-10** (partial, the deterministic core): age ≥ 50 (from onboarding birth year via `PlanInputs.age`) → deload every 3rd week instead of the intensity default; intensity itself never reduced by age (the evidence favors more absorption weeks, not softer work). Day-count preference nudges stay a future onboarding-copy concern.
8. ~~**Ultra**~~ — **SHIPPED 2026-07-10**: `RaceDistance.fiftyK` (onboarding picker inherits it automatically), feasibility peak volumes 65/80/100 km/wk + 16-week minimum prep, 4-week taper (`taperMultipliers` gained the longer glide), long run capped at 32 km, threshold-emphasis quality throughout — the "first 5K to first ultra" positioning is now real. **Still open:** long-horizon no-race plans (general fitness remains a rolling 4-week block).

## 4. Onboarding: do we have everything?

Mostly yes. We capture goal, race + date + goal time, experience, current mileage + longest run, days + preferred days, session length, injury areas, age/sex/height/weight, intensity preference, and a real calibration path (benchmark / feel / HealthKit). That's more than Runna asks.

Missing or broken:
- **Resting HR** (ask, or read from HealthKit at onboarding) — unlocks Karvonen zones.
- **Injury history, age, sex are collected but don't shape the plan** — the gap is wiring, not questions.
- Nice-to-have later: recent-race *history* (enables critical-speed model once 2+ results exist), long-run-day preference (we approximate via preferred days), terrain/heat context.
