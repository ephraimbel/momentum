# Running planner legacy exceptions

Status: observed baseline for WP1 plus Stage-B adapter disposition for WP2, 2026-09-01. These entries
document limitations in the shipping `PlanEngine`; they are not approvals, safety claims, or
contracts for the replacement planner.

The WP1 shadow evaluator validates the invariants the current value model can represent. Where the
legacy model cannot express an essential conflict or coaching state, it emits a typed
`LegacyPlanExceptionCode` instead of quietly treating the behavior as qualified. WP2 now carries
those exceptions into `SessionIntent`/`RunningDecisionTrace`, and its adapter rejects domain inputs
the old generator cannot honor. Live generation and persistence remain unchanged through WP2.

## Typed exceptions emitted by the evaluator

- `startReturnContinuityGateUnavailable`: `PlanInputs` can identify a new runner, but cannot represent
  completed continuity, during-run response, or next-day response. The legacy engine may therefore
  prescribe quality before the Release 1 start/return gate can be evaluated. WP2 now represents the
  state/policy/evidence requirement and marks the candidate `noProgressionGate`; WP4 must supply the
  actual start/return progression before that policy can qualify.
- `intervalPrescriptionIsUnstructured`: repetitions, recovery, target hierarchy, and fallback are
  encoded in one display string. WP2 preserves that normalized string inside the typed
  `SessionIntent` dose and marks it `unstructuredLegacyInterval`; WP4's shared execution prescription
  must replace it before phone/Watch execution equivalence can qualify.
- `strengthCalibrationUnused`: lift e1RM values are accepted in `CalibrationSeed` but do not change
  generated strength prescriptions. WP2 preserves the exact strength prescription and carries this
  legacy exception in its trace; a future runner-strength policy still needs its own reviewed rule.
- `automaticUnitUsesProcessLocale`: `.auto` distance rounding reads the process locale. A replay
  preserves its calendar, calendar locale, and time zone but cannot inject `Locale.current` into
  legacy rounding. Golden and qualification fixtures therefore use explicit metric or imperial units.
- `dayBudgetIsSilentlyClamped`: values outside one through seven are clamped. The new request boundary
  now returns `invalidAvailability` before policy execution.
- `podiumFloorIsNotATypedConflict`: a Podium request below its minimum supported frequency degrades
  without a structured explanation. WP2 returns `intensityRequiresMoreDays` with honest alternatives.
- `raceGoalMissingDistanceIsNotATypedConflict`: a race-distance goal without a positive distance
  falls through to a generic block. WP2 returns `missingRaceDistance`.
- `pastRaceDateIsClamped`: a past event is reduced to a one-week horizon. The replacement request
  boundary now returns `primaryEventInPast` and keeps the live plan untouched.
- `postRoundingReductionsCanBreakDistanceGrid`: the engine first snaps a run to the athlete's metric
  or imperial prescription grid, then re-applies its recent-to-usual load cap and down-week rule.
  Those reduction-only passes can leave an odd meter value. WP4 must render that limitation honestly
  or choose a lower valid grid point without rounding upward through the load ceiling; WP1 treats the
  drift as a named presentation/prescription limitation, while both dose constraints remain hard.

## Model boundaries not yet representable

The following cannot be evaluated as hard invariants from `GeneratedPlan` plus `PlanInputs`, so they
must not be inferred from a green WP1 run:

- Active restrictions are representable in WP2 but the legacy adapter rejects them because it cannot
  prove compliance. Symptom trajectory, return-to-run level, and clinical stop/escalation behavior
  remain unavailable to the legacy generator; historical injury area is still its only modifier.
- Fixed/unavailable dates and course/environment demands are representable and fail closed in WP2;
  the old generator still cannot schedule around them. Fixed long-run day, doubles consent, and
  per-day time budgets require the ordered scheduler.
- WP2 exactly computes completed-session carryover expectations and represents current-plan identity.
  Missed-session behavior, adaptation budgets, atomic persistence, rollback, and undo remain WP3/WP6
  work.
- WP2 provides typed goal, evidence/provenance, feasibility, conflict, and trace values, but the
  adapter's finish-time verdict remains the provisional legacy model—not prospective calibration.
- WP2 protects self-coached ownership at the pure adapter boundary. The live `PlanService`/coaching
  guards remain production authority until the WP3 command boundary exists.
- Structured workout steps and a shared phone/Watch execution prescription. Interval text is not
  sufficient to prove execution equivalence.
- Fueling rehearsal, route/terrain suitability, environmental adjustment, and meaningful
  performance-evidence comparability.

## Qualification interpretation

A green golden or seeded run means only that the shipping deterministic output is reproducible and
passes the invariants observable through the legacy schema. It does not mean the plan is Olympic
level, expert-approved, clinically safe for every athlete, or validated for trail, ultra, middle
distance, pregnancy/postpartum, rehabilitation, youth, elite/professional, or medically complex
populations. Those claims remain blocked by the governance, policy, evidence, and prospective gates
in `ELITE-RUNNING-SYSTEM.md`.
