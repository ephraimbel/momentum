# Momentum Running Rule and Evidence Registry

*Version 1.0 — 2026-09-01*

> Status: Gate 0 governance baseline. This registry describes the high-consequence rules and claims
> already present in the road-running product. It is not evidence that a plan improves outcomes, and
> it is not permission to market Momentum as Olympic-level or clinically validated.

## Authority and change control

The compiled deterministic engine remains the runtime source of numbers. This document records why a
rule exists, where it applies, and what must be reviewed with it. It cannot remotely change a dose.

Every entry must contain:

- A stable rule ID and semantic version.
- The owning code symbol and affected athlete-facing surfaces.
- Purpose, supported population, inputs/outputs, units, bounds, fallback, and rollback.
- Source class: published evidence, expert consensus, product doctrine, operational constraint, or
  provisional heuristic.
- Source, population limits, confidence, approval status, accountable roles, and next review date.
- Fixtures that exercise the behavior and the copy claims that depend on it.

Behavior changes create a new entry version and ruleset. Copy, fixtures, and the decision log change
in the same review. A citation supports only the claim it actually studied; it does not validate
Momentum's implementation or a population absent from that work.

Confidence uses four internal levels:

- **High:** consistent direct evidence in the supported population plus implementation and expert
  review. No current Momentum rule has earned this label for athlete outcomes.
- **Moderate:** relevant evidence with meaningful limitations; bounded use and expert review needed.
- **Low:** indirect, observational, contested, or population-limited evidence.
- **Operational:** product/engineering constraint chosen for predictability or conservatism, not a
  physiological truth.

Approval states are `locked-product`, `engineering-verified`, `expert-review-required`, `pilot-required`,
or `deprecated`. A role is not a named human. Named assignments remain mandatory in
[`RUNNING-DECISIONS.md`](RUNNING-DECISIONS.md) before expert qualification or athlete rollout.

## Registry v1

### RUN-HEALTH-BOUNDARY-001 v1

- **Status:** locked-product; engineering-verified.
- **Purpose:** keep Momentum's workout journal intentional while using Apple Health as a forward-only
  recovery-signal bridge.
- **Rule:** authorization may read current/future sleep, HRV, resting/walking HR, respiratory rate,
  wrist temperature, VO₂max, body mass, and steps. It may read workout time windows only to avoid
  counting known exercise as incidental movement. It never scans or imports workout history and never
  creates a Momentum `Workout`. A completed Momentum workout may be written outward with permission.
- **Code:** `HealthServing`, `HealthService`, `HealthSignalConnection`, onboarding Health step, and
  Settings Health connection.
- **Inputs/outputs:** Health authorization and supported scalar/trend signals; zero imported workout
  rows. SI storage where a value is retained.
- **Fallback:** without authorization, the plan works from Momentum workouts, explicit athlete input,
  RPE, and check-ins. No fake zero and no blocked plan.
- **Source class:** product/privacy doctrine and architecture constraint.
- **Source:** project guide owner decision dated 2026-08-15 and
  [`ENDURANCE-FOCUS.md`](ENDURANCE-FOCUS.md#7-healthkit--wearables-recovery-input).
- **Confidence:** operational. Wearable accuracy is metric-specific; the
  [Apple Watch living systematic review](https://pmc.ncbi.nlm.nih.gov/articles/PMC12823594/) supports
  retaining uncertainty rather than treating connection as truth.
- **Copy contract:** “signals from the day you connect”; “never imports workout history.” Never say
  Garmin, Oura, Whoop, or Watch workouts appear in Momentum.
- **Fixtures:** `HealthSignalConnectionTests`; Health authorization/store-count regression.
- **Owners:** product, privacy, HealthKit engineering. Named humans pending.
- **Next review:** 2027-03-01 or before adding any Health read type.
- **Rollback:** remove the new read/connection path; never restore workout import.

### RUN-LOAD-CONTEXT-001 v1

- **Status:** engineering-verified; expert-review-required.
- **Purpose:** show how the last seven days compare with the recent 28-day weekly norm.
- **Rule:** the ratio is descriptive exposure context. It is not an injury probability, a personal
  safety limit, a “sweet spot,” physiological readiness, or permission to add training.
- **Code:** `ProgressInsights.acuteChronic`, `TrainingLoadContext`, `ProgressNarrator`, load detail,
  coach answers, and `AthleteModel`'s legacy-named load fields.
- **Inputs/outputs:** session-RPE load in arbitrary load units; dimensionless recent-to-usual ratio.
  With insufficient history the UI says it is learning rather than manufacturing certainty.
- **Fallback:** show raw weekly trend and ask how sessions feel; do not prescribe from the ratio.
- **Source class:** contested metric retained as descriptive context.
- **Source:** Impellizzeri et al.,
  [“Acute:Chronic Workload Ratio: Conceptual Issues and Fundamental Pitfalls”](https://pubmed.ncbi.nlm.nih.gov/32502973/),
  which does not support ACWR-based injury-reduction recommendations.
- **Confidence:** low for action; operational for the displayed comparison.
- **Population limits:** all athletes. The same limits apply at every level; elite status does not
  make the ratio causal.
- **Copy contract:** “last 7 days versus recent weekly norm,” plus explicit uncertainty. Prohibited:
  “injury risk,” “danger zone,” “safe band,” “cleared,” “earned more,” and “overtraining score.”
- **Fixtures:** `TrainingLoadContextTests`, `ProgressInsightsTests`, `AthleteNudgesTests`.
- **Owners:** sport science and running-engine engineering. Named humans pending.
- **Next review:** 2027-03-01 or on any formula/band change.
- **Rollback:** retain weekly bars; remove the ratio and all dependent copy.

### RUN-LOAD-GOVERNOR-001 v1

- **Status:** engineering-verified; expert-review-required.
- **Purpose:** prevent an engine defect or sparse self-report from producing an abrupt planned-volume
  jump.
- **Rule:** the legacy-named `ACWRGovernor` only reduces a planned week above 1.3 times its trailing
  four-week average. It never adds work. `1.3` is an internal operational limit, not an injury
  threshold or universal safe zone.
- **Code:** `ACWRGovernor.maxRatio`, final `PlanEngine` progression pass.
- **Inputs/outputs:** meters of prescribed endurance training by week; per-week scale factor in
  `(0, 1]`. Race distance is excluded from training volume.
- **Fallback:** unknown baseline seeds from the first planned week; final rounding is revalidated.
- **Source class:** provisional product heuristic / operational constraint.
- **Source:** [`ENDURANCE-FOCUS.md`](ENDURANCE-FOCUS.md#62-the-workload-progression-governor) and
  decision `RUN-DEC-003`. The ACWR critique above is the reason this value is not presented as
  physiological evidence.
- **Confidence:** operational.
- **Population limits:** current legacy road/endurance generator only. It is not validated for youth,
  pregnancy/postpartum, return from active injury, trail/ultra, or middle distance.
- **Copy contract:** the numeric limit is not a consumer promise. If surfaced in an explanation, call
  it a conservative app guardrail.
- **Fixtures:** `ACWRGovernorTests`, `PlanEngineInvariantTests`, generation matrix tests.
- **Owners:** running-engine engineering and sport science. Named humans pending.
- **Next review:** before WP4 road-policy qualification.
- **Rollback:** select the previous complete ruleset; current valid plan remains live.

### RUN-LOAD-ADAPT-001 v1

- **Status:** engineering-verified; expert-review-required.
- **Purpose:** prevent a descriptive load ratio from silently rewriting an athlete's week.
- **Rule:** a ratio alone cannot automatically mutate the plan. The legacy automatic load path also
  requires a recent planned non-race run to have landed harder than prescribed by explicit plan-fit
  or RPE. A load increase always requires athlete review/confirmation. Apple Health structural
  cutbacks require load plus an out-of-norm recovery signal.
- **Code:** `PlanCoaching.autoAdapt`, `PlanCoaching.proposeAdjustment`,
  `RecoveryAdaptation.tripwire`, `EffortAdaptation`.
- **Inputs/outputs:** load context plus subjective response or recovery trend; bounded ease/rest only,
  at most one structural change per seven days. Safety/injury responses may override the budget but
  never increase dose.
- **Fallback:** leave the live plan unchanged and explain the context.
- **Source class:** operational constraint informed by the limitations in RUN-LOAD-CONTEXT-001.
- **Confidence:** operational; outcome efficacy unvalidated.
- **Copy contract:** name both agreeing inputs. Never imply the ratio diagnosed fatigue or injury.
- **Fixtures:** `PlanCoachingTests.loadRatioAloneNeverMutatesThePlan`,
  `RecoveryAdaptationTests`, `EffortAdaptationTests`.
- **Owners:** sport science, product, running-engine engineering. Named humans pending.
- **Next review:** before unified adaptation coordinator WP6.
- **Rollback:** disable the automatic structural path; retain athlete-initiated ease and the current
  plan.

### RUN-TID-001 v1

- **Status:** expert-review-required.
- **Purpose:** keep most endurance work low intensity while tailoring quality to event, phase,
  experience, frequency, and response.
- **Rule:** 80/20 is a familiar reference, not a universal target. The engine may use pyramidal or
  polarized-looking distributions; it must not chase a fixed percentage at the cost of session
  purpose or athlete context.
- **Code:** `IntensityMix`, `PlanEngine` quality-density and session selection, intensity chart copy.
- **Inputs/outputs:** time-in-zone or session-intent distribution; quantification method must be named.
- **Fallback:** fewer quality exposures and effort-first easy running when evidence is sparse.
- **Source class:** published evidence with heterogeneous methods/populations.
- **Sources:** the runner-specific
  [2022 systematic review](https://pubmed.ncbi.nlm.nih.gov/34749417/) and the
  [2025 individual-participant network meta-analysis](https://pubmed.ncbi.nlm.nih.gov/39888556/).
- **Confidence:** moderate for “mostly low intensity”; low for any universal split or superiority
  claim across runner levels.
- **Population limits:** adult recreational through competitive middle/long-distance runners studied;
  not a youth, clinical return, sprint, or ultra prescription.
- **Copy contract:** “mostly easy” and “reference.” Never “the optimal 80/20 formula for everyone.”
- **Fixtures:** `IntensityMixTests`, policy/golden-season fixtures before live road-policy rollout.
- **Owners:** sport science and road-policy engineering. Named humans pending.
- **Next review:** before WP4 qualification and annually thereafter.
- **Rollback:** use the qualified previous policy/ruleset.

### RUN-RECOVERY-001 v1

- **Status:** engineering-verified; expert-review-required.
- **Purpose:** use noisy recovery signals conservatively without turning a score into clearance.
- **Rule:** one wearable deviation never lurches the plan. A same-day ease requires two independent
  warning signs; a structural load cutback requires high load context plus an out-of-norm recovery
  signal. Positive-looking signals never authorize extra work.
- **Code:** `RecoveryAdaptation`, `MorningReadiness`, `RecoveryModel`, Today and Health surfaces.
- **Inputs/outputs:** personal HRV/RHR trends, sleep, check-in, respiratory/wrist-temperature bands,
  and load context; bounded daily ease or structural reduction.
- **Fallback:** follow the plan with effort-first guidance and ask how the athlete feels. No signal is
  represented as zero.
- **Source class:** provisional multi-signal product model; wearable validation is metric-specific.
- **Sources:** [Apple Watch living systematic review](https://pmc.ncbi.nlm.nih.gov/articles/PMC12823594/)
  and internal conservative policy. No cited source validates Momentum's 0–100 score.
- **Confidence:** low for the composite score; operational for the two-signal/no-increase boundaries.
- **Copy contract:** bands describe context (“Low strain,” “Steady,” etc.). Never “cleared to train,”
  diagnosis, illness detection, or guaranteed recovery.
- **Fixtures:** `RecoveryAdaptationTests`, `RecoveryModelTests`, `MorningReadinessTests`, coach copy QA.
- **Owners:** sport science, clinical, HealthKit engineering. Named humans pending.
- **Next review:** before any public “readiness” efficacy claim and no later than 2027-03-01.
- **Rollback:** show component trends without the composite; preserve the plan.

### RUN-INJURY-001 v1

- **Status:** expert-review-required; clinical approval required before broadened support.
- **Purpose:** reduce aggravating training and route concerning symptoms to qualified care without
  diagnosing.
- **Rule:** prior injury history is a conservative planning modifier, not a prediction of present
  capacity. Active symptom reports use severity/function gates, only reduce/substitute work, and
  escalate concerning or persistent cases. Goal ambition never overrides the restriction.
- **Code:** `InjuryResponse`, onboarding injury question, `PlanEngine` history modifier.
- **Inputs/outputs:** athlete-selected area/severity and function; bounded substitution/ease/hold.
- **Fallback:** stop generated progression and recommend qualified assessment when the app cannot
  safely classify the situation.
- **Source class:** expert consensus plus conservative product policy.
- **Source:** [2016 Bern return-to-sport consensus](https://pubmed.ncbi.nlm.nih.gov/27226389/), which
  frames return as a multifactorial, collaborative risk-management continuum.
- **Confidence:** moderate for the multifactorial/clinician boundary; low for Momentum's area-specific
  substitution rules until clinical review and pilot.
- **Population limits:** Release 1 defaults to adults without an acute emergency; active
  return-from-injury is clinician-guided/conservative, not fully automated support.
- **Copy contract:** “train around this,” “reduce aggravating work,” and “see a qualified
  professional.” Never diagnosis, injury probability, prevention guarantee, or “safe to return.”
- **Fixtures:** `InjuryResponseTests`, plan invariants, clinical review scenarios.
- **Owners:** licensed clinical owner, sport science, product, engineering. Named humans pending.
- **Next review:** before WP4 expert review.
- **Rollback:** remove automatic substitutions and preserve stop/ease plus professional escalation.

### RUN-FEASIBILITY-001 v1

- **Status:** locked-product; expert-review-required for numeric calibration.
- **Purpose:** prevent a goal date or conversion pressure from silently forcing an implausible plan.
- **Rule:** feasibility is computed before generation from the athlete's current evidence, requested
  outcome, runway, and availability. An infeasible target returns honest alternatives; a harder tier
  does not turn an infeasible goal into a supported one.
- **Code:** `PlanFeasibility`, goal-first create/adjust flow, plan reveal and paywall context.
- **Inputs/outputs:** SI distance/time, date runway, current performance/load confidence, availability;
  verdict with limitations and alternatives.
- **Fallback:** completion/base-building target, later date, or shorter event. Never silently change
  the athlete's named goal.
- **Source class:** product doctrine plus provisional deterministic performance model.
- **Source:** [`ELITE-RUNNING-SYSTEM.md`](ELITE-RUNNING-SYSTEM.md#223-feasibility-language).
- **Confidence:** operational for honesty behavior; low-to-moderate for exact outcome ranges until
  prospective calibration.
- **Copy contract:** estimate/range and uncertainty, never guarantee, “safe finish time,” or outcome
  promise.
- **Fixtures:** `PlanFeasibilityTests`, plan-setting/reveal UI tests, future calibration corpus.
- **Owners:** product, sport science/statistics, road-policy engineering. Named humans pending.
- **Next review:** before WP7 funnel qualification.
- **Rollback:** show the conservative legacy verdict and keep the current plan.

### RUN-FUEL-001 v1

- **Status:** expert-review-required; dietitian approval required for event-specific doses.
- **Purpose:** fund training and recovery without dieting, deficit targets, or medical treatment.
- **Rule:** Fuel targets are floors tied to upcoming work. Momentum does not prescribe an aggressive
  calorie deficit, promise weight loss, or diagnose/treat REDs. Individual clinical/body-composition
  needs route to a registered dietitian.
- **Code:** `FuelReadiness`, `FuelingGuide`, Fuel UI, race/long-run coach answers.
- **Inputs/outputs:** training duration/type and athlete-entered food/fluids; supportive ranges in SI
  nutrition units where applicable.
- **Fallback:** familiar food, practice during training, and qualified individual guidance rather
  than a fabricated exact target.
- **Source class:** professional position/consensus plus product doctrine.
- **Sources:** [nutrition and athletic performance position statement](https://pubmed.ncbi.nlm.nih.gov/26920240/)
  and [2023 IOC REDs consensus](https://pubmed.ncbi.nlm.nih.gov/37752011/).
- **Confidence:** moderate for adequate-fueling principle; dose-specific entries remain unapproved
  until a sports dietitian reviews their populations, units, and contraindication copy.
- **Copy contract:** fueling, recovery, enough energy, and ranges. Never dieting, ceilings, disease
  diagnosis, guaranteed body composition, or “burn off” language.
- **Fixtures:** `FuelReadinessTests`, `FuelingGuideTests`, coach fueling QA; dietitian fixture review
  before marathon qualification.
- **Owners:** sports dietitian, product, fuel-engine engineering. Named humans pending.
- **Next review:** before road-marathon expert qualification.
- **Rollback:** retain meal logging and remove unapproved prescriptive ranges.

### RUN-STRENGTH-001 v1

- **Status:** expert-review-required.
- **Purpose:** support running with strength rather than turn Momentum into a bodybuilding plan.
- **Rule:** runner-strength sessions are progressive, recovery-spaced, and subordinate to the running
  goal. Copy says strength *can* support economy/performance; it does not promise injury prevention.
- **Code:** `PlanEngine` strength support, `HybridSequencing`, coach knowledge, strength UI.
- **Source class:** published systematic review plus product policy.
- **Source:** [2024 systematic review and meta-analysis](https://pubmed.ncbi.nlm.nih.gov/38165636/).
- **Confidence:** moderate for selected adult middle/long-distance runners; dose transfer to beginners,
  masters, and return-from-injury requires review.
- **Copy contract:** “can support,” never “prevents injury” or guaranteed economy improvement.
- **Fixtures:** hybrid sequencing and strength prescription suites; coach review before live new policy.
- **Owners:** running coach/strength specialist, sport science, engineering. Named humans pending.
- **Next review:** before WP4 qualification.
- **Rollback:** retain current qualified runner-supporting strength template.

## Compiled coverage and graduation

WP2's compiled `legacy-road-rules-v1` registry contains the ten claim-driving entries documented
above plus these fifteen planning/boundary entries:

- `RUN-PACE-CALIBRATION-001`, `RUN-RACE-PREDICTION-001`, `RUN-VOLUME-PROGRESSION-001`, and
  `RUN-PEAK-VOLUME-001` cover the legacy pace seed, extrapolation, weekly ramp, and peak destination.
- `RUN-LONG-DOSE-001`, `RUN-QUALITY-DOSE-001`, `RUN-DELOAD-001`, and `RUN-TAPER-001` cover session and
  macrocycle dose limits.
- `RUN-RETURN-001`, `RUN-SPACING-001`, and `RUN-SCHEDULE-001` cover the currently missing return gate,
  hard-day protection, and deterministic calendar placement.
- `RUN-ROUNDING-001`, `RUN-ENVIRONMENT-001`, `RUN-RACE-TERMINAL-001`, and
  `RUN-SELF-COACHED-001` cover final display-unit prescription, environment restraint, terminal-event
  behavior, and athlete ownership.

The detailed executable metadata—code symbol, units, bounds, fallback, source, population limits,
confidence, approval, owner roles, review dates, fixtures, and copy dependencies—lives in
`RunningRuleRegistry.legacyRoadV1`. `RunningRuleRegistryTests` fails on missing/duplicate IDs, invalid
bounds/units, missing source or owner role, missing/stale review metadata, inconsistent approval, or
traces that cite an unknown rule. Expert-sensitive numeric planning entries deliberately remain
`expertReviewRequired` with no approval date; registry completeness is not scientific approval.

No entry graduates to `pilot-required` or public outcome language until named experts complete the
rubric, material disagreements are resolved, and the exact supported population is recorded.
