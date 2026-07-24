# The Plan System — operating map

*2026-07-23. The one-page truth about how plans are generated, judged, and adapted. Companion to
`docs/PLAN-QUALITY-AUDIT.md` (the science pass) and PRD §9. If this file and the code disagree, fix
one of them the same day.*

## 1. Generation (`PlanEngine.generate` — pure, deterministic)

**Inputs** (`PlanInputs`, built by `PlanService.planInputs`): disciplines, goal, daysPerWeek,
race distance/date + goal time, experience, current weekly volume + longest run, intensity tier,
injury history, age (masters deload only — sex/weight are collected in onboarding but do NOT reach
the engine), session minutes, equipment, hybrid priority, preferred days, distance unit.

**Pipeline**: fitness seed (recent run via Riegel → entered time → experience default, as a 5K
pace) → day allocation (hybrid split) → macrocycle sizing from the race date (base ≈ 25% → build →
peak ≤2wk → taper 1–4wk by distance; ≤3wk runway = all-sharpening; race beyond 52wk = pure
foundation) → per-week volume `start × ramp^buildIndex`, ceilinged at the distance's readiness peak
(`PlanFeasibility.peakWeeklyVolumeM`, max 3.5× start) → session composition by day count (2+ long
run, 3+ quality, 4+ strides, 5+ second quality/medium-long/recovery texture) → ACWR governor
(≤1.3× trailing chronic) → race-day injection on the exact date → **clean prescriptions last**:
distances snap (race → canonical; runs → half-unit; long runs → whole units) AND paces snap
(easy-family → :15, quality/race → :05, in the athlete's display unit — `RunRounding.snapPace`,
2026-07-23). All paces come from Daniels/VDOT (`DanielsPaces`); storage stays SI.

**Intensity tiers** (`PlanIntensity`): ramp/deload-cadence/quality-bias =
gentle 1.05/3/0.85 · balanced 1.08/3/1.0 · aggressive 1.11/4/1.2 · **podium 1.12/4/1.4**.
Injury history caps ramp, cadence, AND quality bias at balanced regardless of tier. Masters (50+)
deload every 3rd week.

**Podium** (2026-07-23, the tier above Aggressive — train to WIN): gated on 5+ run days AND no
injury history (`podiumActive`), else it trains like Aggressive. Active: readiness peak ×1.2,
long-run caps 32→35 km (marathon+) / 20→22 km (half) under a 3.5 h time-on-feet cap, second
quality standard (volume gate 45→40 km/wk), one OPTIONAL ~3 km rest-day shakeout per training week
(never deload/taper/lead-in; skipping counts as rest). Feasibility never *recommends* podium.
Its selection card wears the iridescent border — the sanctioned exception to earned-only.

## 2. Honesty (`PlanFeasibility.assess` — the verdict before the plan)

Reads race distance, goal time, current fitness + volume, weeks available, experience, injury
history, **and daysPerWeek** (2026-07-23). Two needs computed: weeks-for-volume (safe build to the
distance's peak at balanced ramp, floored by per-distance minimums 4/5/8/12/16) and weeks-for-time
(Riegel prediction vs goal, per-week improvement rates with per-cycle caps). Verdict: onTrack /
tight (≥80% of needed) / tooShort / noRace.

**Frequency floor** (`minimumEffectiveDays`): 5K/10K 3 · half/marathon 4 · 50K 5. One day under →
verdict tightens, "add a day" is the first option. Two+ under → tooShort with its own copy ("N days
won't prepare a marathon") — maintenance, not preparation. Never blocking; the engine still builds
the asked-for week. The aggression recommendation follows the CALENDAR verdict only (a frequency
gap isn't closed by pushing harder on fewer days). Surfaces: onboarding intensity-step banner + an
inline note on the days picker, plan settings (live against the buffered days), coach feasibility.

## 3. Adaptation (bounded, throttled, explained)

All writes in `PlanCoaching`; only future open sessions; race day never touched. Three independent
≤1/week budgets: `lastAdaptedAt` (every load reshape — protective ease/rest from ACWR, effort-based
ease, strength deload, rebuild week after ≥3 misses, injury report/return, consented bump),
`lastRecalibratedAt` (pace sharpening: two qualifying runs within 14 days, ≤3%/update, races bypass
confirmation), `lastPaceEasedAt` (consented +2% easing; clears banked sharpening evidence).
Ordering after a save: autoAdapt FIRST, recalibrate only if nothing eased. Daily readiness ease
(2+ signals) and the overtraining tripwire (ACWR >1.5 + physiology, outranks the daily ease) live
in `RecoveryAdaptation`; the demanding tiers (`tightLeash`: aggressive + podium) react to milder
warnings and want 6.5 h sleep. Missed sessions roll forward as `.moved` — no failed state, ever.
No-race plans renew as 6-week blocks reassessed from actual logged volume (`renewBlock`).

## 4. Invariants that must never break

`PlanEngineInvariantTests` sweeps the whole input space (all tiers × distances × runways × days ×
injuries): plan length = runway, taper before every in-window race, ACWR fixed-point, exact day
budget (+1 only for podium's shakeout on training weeks), long runs under the (tier-aware) cap,
down weeks dip, quality never on deloads, injury steering in every phase, every stored pace
re-snaps to itself. `PodiumTierTests` pins the tier; `PaceSnappingTests` pins the grids;
`PlanFeasibilityTests` pins the honesty copy.
