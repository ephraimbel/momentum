# Momentum Elite Running System

*Reviewed execution specification — 2026-09-01*

> Objective: build the best adaptive running coach on iPhone and Apple Watch, from a first run to
> serious competition, without pretending that one formula can coach every runner or that software
> replaces an Olympic performance team.

> **How to read this document:** this is the target architecture and release contract, not a claim
> that every item is in the shipping app today. “Must” marks a release gate. “Should” marks a strong
> default that may change only through a recorded product/science decision. The current plan remains
> the production fallback until a new policy passes its migration, invariant, coach-review, and pilot
> gates.

## Executive decision

Momentum already has unusually strong foundations: a deterministic plan engine, goal feasibility,
real macrocycles, structured guided workouts, race-specific work, recovery and injury responses,
runner-focused strength, fueling, and a persistent Athlete Model. It is not starting from zero.

It is also **not yet an Olympic-grade coaching system**. The current `EliteCalibrationTests` prove
that world-class times can enter the pace pipeline and produce finite zones. They do not prove that
the resulting season, workout dose, adaptation, taper, terrain handling, or athlete monitoring is
appropriate for an elite runner. That distinction needs to remain visible in the product and in our
own decision-making.

The strategic direction is:

1. Make road running from beginner through competitive marathon genuinely coach-grade.
2. Replace the single fitness scalar with a confidence-aware athlete state.
3. Treat trail/ultra and middle-distance as separate coaching policies, not longer or shorter
   versions of the same road plan.
4. Validate plans with real coaches and athletes before using “elite-grade” as a claim.
5. Keep the product simple for a beginner while exposing professional depth only when it is useful.

“Elite-grade for a beginner” means elite-quality assessment, restraint, progression, explanation, and
monitoring—not elite mileage, intensity, or complexity. The quality standard can be shared; the dose
and session language must be specific to the runner in front of it.

The north star is not “the app with the most metrics.” It is:

> **Momentum makes the best next training decision it can, explains why, shows how certain it is,
> and changes as little as necessary.**

## Review verdict

The strategy is sound, but the first draft was not yet safe to hand directly to engineering. It
correctly identified the product direction; it did not fully specify persistence migration,
deterministic conflict resolution, low-confidence behavior, failure recovery, rollout controls, or
how the existing and new planners coexist. Those omissions are resolved in this revision.

The reviewed plan makes these decisions explicit:

- This is an incremental replacement of planning decisions, not a rewrite of workout capture,
  Health, Fuel, Progress, or the existing plan UI.
- `TrainingPlan` remains the active persisted plan during the migration. A new season model adds
  context above it without invalidating old stores or forcing an immediate regeneration.
- The new planner first reproduces current road-plan outputs as versioned golden fixtures. New
  personalization is added only after equivalence, not while architecture and coaching behavior are
  changing at the same time.
- A deterministic ordered scheduler replaces the vague “constraint solver” promise. Hard constraints
  are never traded for a score; soft preferences use a stable lexicographic order and stable tie-break.
- All automatic structural proposals compete inside one atomic adaptation transaction. Acute safety
  reductions can override the weekly change budget; performance increases cannot.
- Fitness calibration becomes bidirectional. A bad day never becomes a demotion, but repeated,
  comparable evidence must be allowed to ease stale targets as well as sharpen them.
- Shadow mode cannot write a plan, workout, profile, decision record, or analytics payload containing
  athlete health/performance values. The live plan changes only after a validated candidate is
  committed atomically.
- “Elite-grade” and “Olympic-level” remain prohibited marketing claims until the validation gates in
  this document are actually met.

This plan is **execution-ready** when the remaining owner decisions in §27 have names and dates. It is
not “perfect” in the sense of guaranteeing every athletic outcome; no honest coaching system can do
that. It is complete in the more useful sense: every known high-risk decision has an owner, fallback,
test, and release gate.

## 1. What Momentum has today

### Strong and worth preserving

- Goal-first plan creation and adjustment, including race time, race date, frequency, current
  volume, longest run, injury history, plan intensity, and an honest feasibility verdict.
- Deterministic `PlanEngine`, `PlanFeasibility`, `DanielsPaces`, `StructuredWorkout`,
  `RecoveryAdaptation`, `EffortAdaptation`, `SessionPaceReview`, `InjuryResponse`, and fueling/race
  engines with extensive fixture and invariant coverage.
- Base → build → peak → taper periodization, down weeks, race-specific workouts, time trials,
  structured live guidance, post-run feedback, pace recalibration, and bounded structural changes.
- A strong beginner experience: run/walk support, no-shame rescheduling, conservative calibration,
  and recovery/injury guardrails.
- A real competitive advantage in runner-specific strength sequencing and in explaining why a plan
  changed.
- Health as signals only. Momentum-recorded sessions and explicit athlete entries are the training
  evidence; Apple Health never creates a workout in Momentum.

### The ceiling of the current system

- Fitness is still anchored primarily to one 5K-equivalent pace. That is useful, but it does not
  describe threshold, speed reserve, durability, economy, heat response, downhill tolerance, or how
  an athlete responds to a training dose.
- Experience is only `new`, `some`, or `experienced`; those labels cannot distinguish training age,
  recent continuity, frequency tolerance, or event expertise.
- The primary season model is one goal race. Serious runners need A/B/C races, tune-ups, travel,
  post-race recovery, and more than one peak decision.
- The event model ends at a 50K. A mountain 50K, flat road 50K, 100-mile race, and 24-hour race are
  physiologically and operationally different products.
- Several prescriptions are still generalized rules: fixed warm-up/cool-down distances, universal
  recovery ladders, simple long-distance performance decay, fixed intensity-tier ramps, and a
  one-size masters adjustment at age 50.
- Terrain, descent load, technicality, heat, humidity, altitude, wind, treadmill calibration, and
  race-course demands do not yet shape the plan deeply enough.
- The Athlete Model learns useful behavior and trends, but those facts do not yet form a coherent,
  versioned physiological state that every planning decision consumes.
- There is no prospective evidence that the system improves outcomes or reduces interruptions in
  any defined population. Unit tests prove implementation behavior, not coaching effectiveness.

### Doctrine debt to clean up first

The live `HealthService` correctly enforces “signals only,” but older docs, comments, test names, and
some UI explanations still refer to Health workout imports. Those contradictions must be removed.
An elite product cannot have two internal truths about where its evidence comes from.

The ACWR implementation is a useful spike detector, but current copy sometimes presents fixed ratios
as an injury-risk zone or a universal “sweet spot.” Methodological work cautions against using ACWR
as an injury predictor or causal rule. Momentum should retain recent-versus-usual load context while
removing predictive injury language and false-precision thresholds. See
[Impellizzeri et al.](https://pubmed.ncbi.nlm.nih.gov/32502973/).

### Implementation hazards found in this review

- `PlanService.observedFitness` treats the greater of a recent longest run and the onboarding-declared
  longest run as current capacity, so an old peak can remain forever after a long interruption. Keep
  recent tolerance, historical achievement, and athlete declaration as separate evidence.
- Recent weekly volume is currently reduced to one heuristic average after dropping the lightest week.
  That protects against one quiet week but can overstate a real decline. Preserve the distribution,
  continuity, and reason/confidence instead of turning every gap into an outlier.
- Post-race recalibration currently moves only faster. The separate consented pace-ease path is useful,
  but the next state model must reconcile both directions from comparable evidence.
- Structural adaptation, sharpening, and pace easing use separate timestamps. Most paths share the
  structural gate, but independent entry points can still disagree. One proposal coordinator and
  transaction must own priority and budget.
- `PlanService.persist` deletes the existing plan before the replacement is saved. The new planner must
  validate in memory and prove candidate-first atomic replacement with failure injection.
- `SchemaV1` originally listed mutable top-level `@Model` types. The archived build-36 fixture exposed
  the resulting checksum failure as soon as `AppNotification` gained optional fields. V1 now owns a
  frozen version-scoped snapshot of that released entity, and the archived-store gate will reject any
  future shipped-model mutation that is not versioned deliberately. New sidecar entities remain the
  safest Release 1 migration.
- The current plan-name requirement is already correctly reflected in `PlanSettingsSheet` and
  `TrainingPlan.name`. Preserve it and add ordering/persistence tests rather than redesigning it again.

## 2. Define “any runner” as a product taxonomy

One engine should own shared safety and scheduling constraints. Separate event policies should own
the training logic.

### Family A — Start and return

- First run, first continuous 20–30 minutes, first 5K, and return after a long break.
- Primary variables: impact exposure, run/walk tolerance, consistency, soreness response, confidence,
  and enjoyment.
- Targets: time and effort before pace. No forced benchmark race.
- Required gate: no quality session until a minimum continuity and recovery pattern is established.

### Family B — Road endurance

- 5K, 10K, half marathon, marathon, and general running fitness.
- Primary variables: threshold/critical-speed proxy, aerobic volume tolerance, speed reserve,
  durability, long-run response, race-pace tolerance, and fueling rehearsal.
- This is the first complete product because it serves the broadest market and fits the strongest
  parts of the existing engine.

### Family C — Competitive road and long-distance track

- Competitive 5K/10K, cross-country, half marathon, and marathon.
- Adds doubles, tune-up races, individualized workout progression, advanced testing, altitude/heat
  camps, race tactics, taper response, and coach-visible detail.
- The existing “Podium” intensity selection keeps its current meaning until Release 2. Any future
  capability-gated performance mode ships behind a separate flag and migration; Gate 0 must not
  silently reinterpret an athlete's saved choice.

### Family D — Trail and ultra

- Trail races, mountain 50K, 50 mile, 100K, 100 mile, and time-based ultra events.
- Adds vertical load, downhill eccentric exposure, technicality, hike/run strategy, time-on-feet,
  back-to-back durability, aid-station and fueling rehearsal, mandatory gear, darkness, altitude,
  and course-specific pacing.
- Never generate these by extending marathon volume or by applying a generic race-time decay.

### Family E — Middle distance

- 800 m, 1500 m/mile, and 3000 m.
- Adds acceleration, maximal velocity, speed reserve, anaerobic capacity, neuromuscular work, track
  accuracy, long recoveries, and competition-round planning.
- This should be a later, distinct module. Calling a VDOT-scaled distance plan “800 m coaching” would
  be unsafe product theater.

### Athlete modifiers across every family

- Masters: use individual recovery and tissue-tolerance evidence, not an age-only downgrade.
- Female athlete health: symptom and cycle tracking may inform conversations and athlete-selected
  adjustments, but never prescribe universal phase-based training. Current elite-sport consensus
  finds insufficient high-quality evidence for universal phase-based training decisions; see the
  [2025 elite-athlete consensus](https://onlinelibrary.wiley.com/doi/10.1111/sms.70112).
- Injury/return: symptom-location and function gates, with explicit clinician escalation; no diagnosis.
  Return-to-sport decisions are multifactorial risk-management decisions, not a calendar alone; see
  the [Bern return-to-sport consensus](https://pubmed.ncbi.nlm.nih.gov/27226389/).
- Hybrid strength: runner-specific heavy strength, plyometrics, and interference-aware sequencing.
- Heat/altitude: environment-specific effort, acclimation, hydration, and arrival logic.
- Pregnancy/postpartum, acute illness, and diagnosed conditions: do not automate without a clinically
  governed module and appropriate professional clearance.
- Youth/adolescent runners: growth, maturation, school competition, safeguarding, and consent require
  a separately governed policy; do not treat them as small adults.
- Para/adaptive runners and wheelchair racers: co-design event, equipment, load, accessibility, and
  classification needs with qualified athletes/practitioners before claiming full support.

## 3. The athlete-state model Momentum needs

Replace “one estimated 5K pace plus a few profile fields” with a versioned, pure
`RunningAthleteState`. Every value carries its source, observation window, sample count,
last-updated date, and confidence. The state is reconstructed for a planning decision; it is not a
new database full of opaque physiological scores. Only compact snapshots and the evidence required
to explain a decision are persisted.

### Capacity

- Aerobic speed and race-equivalent curve.
- Critical-speed or threshold proxy for experienced runners, with uncertainty.
- Speed reserve for short-distance athletes.
- Easy-effort pace/HR/RPE relationship.
- Long-duration durability: how pace, HR, and RPE change late in steady runs.
- Efficiency trend from pace/HR/RPE under comparable conditions. Do not call this running economy:
  true economy is oxygen cost at a given submaximal speed and cannot be measured from consumer GPS.

### Tolerance

- Recent frequency, volume, duration, vertical gain/loss, and high-intensity exposure.
- Long-run fraction and longest recent continuous run.
- Days needed to feel normal after hard, long, downhill, and strength sessions.
- Response to progression: completed as intended, completed with high RPE, shortened, moved, or
  followed by excessive soreness/pain.
- Surface and footwear exposure where the athlete records it.

### Context

- Training age, recent continuity, event experience, schedule constraints, sleep/recovery signal
  availability, life stress, climate, altitude, treadmill/outdoor preference, and access to hills,
  track, trails, or strength equipment.
- Health signals are trend evidence, not truth. Consumer-wearable validation varies substantially by
  metric; confidence must be metric-specific rather than one “connected” badge. See the
  [Apple Watch living systematic review](https://pmc.ncbi.nlm.nih.gov/articles/PMC12823594/).

### Response profile

- Which session doses reliably land at the intended RPE.
- Which taper shapes have previously produced good race-day readiness.
- Whether increased frequency or longer individual sessions are better tolerated.
- Environment response: personal pace/RPE shift in heat, humidity, altitude, and hills.
- Adherence response: the schedule the athlete can actually execute.

This state is deterministic and reconstructable. AI may explain it, ask for missing evidence, and
narrate a bounded decision; it never calculates the state.

## 4. Build a real season and goal model

Introduce a `RunningSeason` above `TrainingPlan` without removing the current plan relationship:

- One primary outcome: finish, finish strong, target time, placement, qualify, build base, or return.
- Optional motivation: health, consistency, confidence, stress, or body composition. Motivation shapes
  explanation and sustainable commitment; it does not become an unsupported performance/weight-loss
  promise.
- Multiple events with A/B/C priority, date, distance, surface, vertical profile, expected climate,
  altitude, and course technicality.
- Availability changes: travel, holidays, work peaks, and planned breaks.
- Block objectives and exit criteria, not only start/end dates.
- A stable goal contract: changing the goal is an explicit re-plan with an honest before/after
  explanation.

The race date should not be the only clock. Each phase has minimum and maximum duration plus explicit
exit evidence. A phase may hold only inside that bounded window. If a fixed event date arrives before
the athlete is ready, `PlanFeasibility` changes the promised outcome or recommends a later event; it
does not keep extending the block or hide the conflict by increasing intensity.

## 5. Replace templates with policy modules and session intent

Every planned session needs a first-class `SessionIntent`:

- Primary stimulus and why it exists in this block.
- Dose: work duration/distance, recovery, intensity domain, and total mechanical exposure.
- Target hierarchy: effort, pace, HR, power when available, grade, or a combination.
- Success range, not a single perfect number.
- Valid substitutions that preserve the stimulus.
- Progression level and evidence required to advance.
- Expected recovery cost and hard-session classification.

The shared planner should schedule intents under hard constraints. Event policies should choose and
progress them:

- `StartReturnPolicy`
- `Road5K10KPolicy`
- `HalfMarathonPolicy`
- `MarathonPolicy`
- `TrailUltraPolicy`
- `MiddleDistancePolicy` later

The plan generator becomes an ordered deterministic scheduler with a decision trace:

1. Protect fixed life and safety constraints.
2. Preserve the block's primary stimulus.
3. Avoid conflicting hard, long, downhill, and lower-body strength loads.
4. Meet an event-policy dose range.
5. Prefer the athlete's proven schedule and response profile.
6. Add variety only after the above are satisfied.

This prevents “variety” from becoming random workouts and prevents personalization from becoming
unstable plan churn. Hard constraints are Boolean gates, never weights. Soft preferences are applied
lexicographically in the order above, and ties resolve by stable intent ID then calendar offset. If
the schedule is infeasible, the planner relaxes preferences, then optional dose, then the outcome
promise—never a safety constraint.

## 6. Calibrate without turning onboarding into a laboratory

### At plan creation

Keep the goal and plan name at the top. Ask only what changes the first two weeks:

- Goal, event, date, and course type.
- Recent Momentum-recorded performance or an explicit user-entered race/test.
- Current weekly frequency, volume/time, longest run, and weeks of continuity.
- Availability and preferred long-run day.
- Pain/injury status, recent interruption, and strength background.
- For trail: recent vertical, technical terrain, and hiking experience.

Health remains signals-only. Do not quietly reconstruct training history from Health workouts.

### During the first block

- Beginner: learn from easy talk-test sessions and run/walk completion.
- Road runner: use an optional controlled field test, a recent Momentum-recorded race, or a
  user-entered result that remains labeled self-reported.
- Experienced runner: offer a multi-effort critical-speed protocol or manually entered lab/coach
  values. Critical speed is useful but protocols vary, so the app must preserve method and uncertainty;
  see the [field-test systematic review](https://pmc.ncbi.nlm.nih.gov/articles/PMC11933073/).
- Marathon/ultra: add a steady long-run durability check and fueling rehearsal; a short race result
  alone cannot establish long-duration readiness.

### Continuously

Update only when the evidence is comparable:

- Normalize for grade and known environment.
- Compare intended versus achieved reps, RPE, completion, HR response, and late-session drift.
- Require repeated evidence for pace increases; one exceptional day creates a hypothesis, not a new
  athlete identity.
- Allow a strong race result to update the performance curve immediately while retaining uncertainty
  outside the raced duration. A difficult race is not automatically a fitness loss, but it is new
  evidence; if it agrees with repeated comparable sessions that targets are stale, Momentum must be
  able to ease them. “No shame” means neutral language, not a permanently faster-only model.

## 7. Use the right target for the workout

- Easy/recovery: talk test and RPE first, HR as a guardrail when trustworthy, pace as context.
- Threshold/steady: pace or critical-speed proxy plus RPE; HR is supporting evidence after its lag.
- VO2/repetition: pace/time and execution quality; do not steer short reps by HR.
- Hills/trail: effort, grade, and time; flat-equivalent pace is a review tool, not a command.
- Long runs: effort plus durability and fueling objectives; pace may change with terrain and climate.
- Heat/altitude: preserve the physiological intent and relax pace. Heat consensus supports planned
  acclimation and individualized strategies rather than pretending sea-level pace is portable; see
  the [IOC heat consensus](https://pmc.ncbi.nlm.nih.gov/articles/PMC9811094/).

This target hierarchy is already reflected in parts of the workout library. It needs to become a
single rule consumed by plan generation, live guidance, review, and adaptation.

## 8. Replace “injury prediction” with a multi-dimensional load ledger

Keep workload monitoring, but stop asking one ratio to do the job of a coach.

Track separately:

- Internal load: session duration × athlete RPE, with missing-RPE confidence clearly lower.
- External load: running duration/distance, high-intensity time, ascent, descent, surface, and
  strength/plyometric exposure.
- Concentration: hard-day adjacency, long-run fraction, weekly monotony, and repeated downhill or
  speed exposure.
- Change: recent versus personally established load across more than one time scale.
- Response: soreness, pain, low energy, plan-fit answer, completion quality, and recovery time.

Use this ledger for conservative decisions and explanations. Do not display a probability of injury,
a red danger score, or a universal safe band. The app can say “this is a larger change than you have
handled recently” without claiming it knows whether the athlete will be injured. The structure follows
the distinction between internal/external load and athlete response described in the
[training-load monitoring consensus](https://pubmed.ncbi.nlm.nih.gov/28463642/), while deliberately
avoiding a single predictive ratio.

## 9. The adaptation contract

Momentum should adapt on four clocks:

### During a session

- Adjust cues and acceptable range for GPS quality, grade, heat, and rep type.
- Never silently change the session's physiological objective.

### After a session

- Record how the prescribed dose landed.
- Update calibration evidence and the response profile.
- Offer a protective next-session change when a clear mismatch exists.

### Weekly

- Make at most one automatic structural change per rolling seven days, with hysteresis so a good day
  does not immediately reverse a previous ease.
- Rebalance missed work; never cram it.
- Re-evaluate frequency, long-run dose, and hard-session progression.

### At block boundaries

- Compare objective exit criteria, adherence, athlete confidence, and the calendar.
- Advance, hold, repeat, or redirect the block.
- Update the feasibility verdict and race promise.

Every material decision persists a `PlanDecisionRecord`: inputs used, confidence, constraints, rule
version, old prescription, new prescription, and athlete-facing explanation. That gives support,
testing, and future research an auditable answer to “why did my plan change?”

All proposals are arbitrated in this order:

1. Active pain/injury and clinician-directed restrictions.
2. Acute illness or severe recovery concern.
3. Excessive response to recent load.
4. Schedule feasibility and missed work.
5. Fitness/pace calibration.
6. Preference and variety.

The highest-priority accepted proposal suppresses incompatible lower-priority proposals. A temporary
same-day execution downgrade is reversible and may happen independently of the structural budget.
An acute safety reduction is never blocked because the plan adapted recently. Increases, workout
progressions, and schedule optimization are blocked when the budget is spent. Every structural change
is an atomic `AdaptationTransaction`: evaluate → propose → validate → persist plan and decision record
together, or persist nothing. The existing `lastAdaptedAt`, `lastRecalibratedAt`, and
`lastPaceEasedAt` gates remain compatibility fields until this transaction owns all three paths.

## 10. The premium athlete experience

The app should feel simple, not simplistic.

### Plan creation and adjustment

The page hierarchy should stay:

1. Plan name at the top.
2. Goal and event.
3. Current starting point and confidence.
4. Honest feasibility verdict.
5. Availability and training preferences.
6. Recommended training commitment.
7. Preview of what will materially change.

### Plan reveal and paywall

Sell the decision quality, not a pile of features. Before purchase, show:

- “Your goal” and the exact outcome Momentum is building toward.
- “Where you are now” with data source and confidence.
- An honest goal verdict and any trade-off.
- The phase blueprint and why it fits the athlete.
- A real first week with session purposes.
- The adaptation promise: what Momentum watches, how often it can change the plan, and what it will
  never do automatically.

### Progressive disclosure

- Beginner mode: today, how it should feel, why it matters, and one next action.
- Performance mode: zones, stimulus dose, response trends, season calendar, prediction interval, and
  decision history.
- Both modes use the same engine. “Advanced” is more visibility and optional calibration, not a
  riskier default plan.

## 11. Safety and performance governance

Elite-grade is an operating model, not a visual style.

Create an external advisory group with at minimum:

- A high-performance distance coach with national/international athletes.
- A beginner/return-to-run coach.
- A trail/ultra coach.
- An exercise physiologist or sport scientist.
- A sports physical therapist or sports-medicine physician.
- A sports dietitian with endurance and REDs experience.
- A female-athlete health specialist.

All health-facing copy and logic needs ownership, evidence date, review date, and a clear boundary
between training guidance and clinical assessment. The IOC REDs consensus supports multidisciplinary
clinical assessment; Momentum should surface fueling/health concerns and recommend qualified help,
not diagnose REDs. See the [2023 IOC REDs consensus](https://doi.org/10.1136/bjsports-2023-106994).

Runner strength remains a core pillar. Evidence supports heavy, plyometric, and combined strength
approaches for improving running economy, while the exact response varies; see the
[2024 systematic review and meta-analysis](https://pubmed.ncbi.nlm.nih.gov/38165636/). The plan must
progress strength by training age and protect key running sessions rather than prescribe generic
high-rep circuits.

Subjective athlete feedback stays first-class. A systematic review found subjective measures more
sensitive and consistent than many commonly used objective measures for tracking training response;
wearable signals should complement, not overrule, what the runner reports. See
[Saw et al.](https://pubmed.ncbi.nlm.nih.gov/26423706/).

## 12. Validation system

### Layer 1 — deterministic correctness

- Property tests across every event policy, experience state, schedule, goal, surface, intensity,
  injury modifier, climate, and race runway.
- Invariants for hard-day spacing, total dose, taper, long-run share, fueling practice, return gates,
  confidence, and no Health workout import.
- Versioned golden fixtures for representative athletes.

### Layer 2 — replay and simulation

- Re-run historical Momentum training through new rule versions without changing user data.
- Compare proposed versus actual sessions, adaptations, race predictions, and interruptions.
- Use shadow mode: compute the new plan beside the live plan and inspect disagreement before release.
- Build adversarial personas: inconsistent beginner, high-mileage athlete, masters returner, heat wave,
  hilly marathon, ultra novice, sparse signals, misleading fast workout, and repeated missed days.

### Layer 3 — expert review

- Blind coach review of complete seasons, not isolated weeks.
- Require reviewers to score appropriateness of stimulus, progression, recovery, specificity,
  feasibility, and explanation.
- Any systematic disagreement becomes a policy or uncertainty change, not merely copy polish.

### Layer 4 — prospective athlete validation

- Pilot separately by athlete family; do not pool beginners and competitive runners into one success
  number.
- Measure adherence, session-intent match, pain/injury interruption, excessive fatigue, fitness/race
  change, prediction calibration, adaptation stability, and athlete trust.
- Predefine pass/fail thresholds before looking at outcomes.
- Do not claim injury reduction or elite effectiveness without a study designed to support it.

## 13. Release sequence and gates

### Gate 0 — Truth and governance

Deliver before new plan complexity:

- Remove stale Health-import doctrine from code comments, tests, and active planning docs.
- Rename ACWR-facing concepts to load balance/context and remove injury-prediction claims.
- Establish an evidence registry and decision-record schema.
- Define supported athlete/event scope in product copy.
- Recruit the advisory group and approve the plan-review rubric.

Exit gate: every surfaced training/health claim has an owner, source, and confidence boundary.

### Release 1 — Coach-grade road core

- `RunningAthleteState` v1 and `RunningSeason` with one A race plus tune-ups.
- Beginner/return, 5K/10K, half, and marathon policy modules.
- Session intent, target hierarchy, progression level, and deterministic decision trace.
- Comparable-condition calibration and durability measures.
- Revised load ledger and weekly/block adaptation cadence.
- Goal-first plan creation/reveal with the plan name at the top.
- Evaluation harness and shadow-mode plan comparison.

Exit gate: coach-reviewed golden plans pass across beginner through competitive marathon personas;
no unsupported “elite” claim.

### Release 2 — Performance system

- Multi-race A/B/C season planning.
- Optional critical-speed/multi-effort calibration, speed reserve, and advanced field-test workflows.
- Individual taper response, doubles, tune-up races, advanced strength/plyometrics, and performance
  mode UI.
- Weather/course normalization and race-day execution plans.

Exit gate: prospective competitive-road pilot meets predefined safety, adherence, calibration, and
performance criteria.

### Release 3 — Trail and ultra

- Course representation with vertical, technicality, altitude, aid stations, darkness, and climate.
- Uphill/downhill load, hiking, back-to-backs, time-on-feet, fueling/gut training, gear, and crew plan.
- Separate race feasibility and prediction models with wide uncertainty.

Exit gate: trail/ultra coach approval plus event-specific field pilot. Until then, the product should
say it supports 50K preparation only where the existing policy is appropriate—not “every ultra.”

### Release 4 — Elite and middle-distance validation

- Separate 800 m–3000 m policy, track execution, speed reserve, and competition-round logic.
- Coach/team review mode, manual overrides with audit trail, and shared season decisions.
- Elite cohort validation and independent methodology review.

Exit gate: only here can “elite-grade” become an evidence-backed public claim. “Olympic-level” should
require direct high-performance practitioner ownership and documented use at that level.

## 14. What not to build

- No universal “80/20” enforcement. Elite-distance literature consistently shows most running at low
  intensity, but the exact distribution varies by event, phase, and measurement method; see
  [Casado et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC8975965/) and the
  [running TID systematic review](https://pubmed.ncbi.nlm.nih.gov/34749417/).
- No universal 10% weekly rule, 180-step cadence target, or one ideal running form.
- No injury probability score and no red “danger” label.
- No automatic plan escalation from one strong session or one wearable score.
- No menstrual-phase “cycle syncing” prescriptions.
- No 100-mile plan built from marathon formulas.
- No extra onboarding questions that do not change the first block.
- No AI-generated loads, paces, or return-to-run clearance.
- No Apple Health workout import. If Momentum-recorded execution is a barrier for Garmin/COROS-only
  elites, that is an explicit platform-scope decision, not a loophole to rebuild the deleted importer.

## 15. Self-critique of this plan

### It is intentionally narrower than “best running app ever” sounds

A credible first release should dominate road coaching rather than superficially cover every running
event. This may feel less ambitious, but it prevents one generic engine from being marketed as expert
across incompatible disciplines.

### The athlete-state model can become complexity theater

More variables do not guarantee better decisions. Every new field must prove that it changes a plan or
its confidence. If it does not, it should stay in analytics rather than the planning state.

### Personalization can destabilize a plan

An app that reacts daily feels intelligent in a demo and exhausting in real life. Hysteresis, change
budgets, block-level decisions, and transparent “we are holding” states are as important as adaptation.

### The available evidence is incomplete

Many endurance studies use small, male-heavy, already-trained samples. Taper and intensity findings are
population averages, not universal prescriptions. For example, a recent taper meta-analysis supports
maintaining intensity/frequency while reducing volume, but also notes limited RCTs and individual
variation; see the
[2023 taper meta-analysis](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0282838).

### Product constraints limit “any runner”

Under the current Apple-first, Health-signals-only doctrine, a runner must execute or log training in
Momentum for the adaptive system to see it. That is coherent and privacy-safe, but it limits adoption
among athletes committed to Garmin, COROS, or coach-controlled ecosystems. The roadmap should measure
that constraint honestly rather than claim universal support.

### Validation is the longest pole

Shipping deterministic modules is faster than proving that their decisions are good. If schedule
pressure removes coach review, shadow mode, and prospective pilots, the result may look elite without
being elite. Validation is therefore a release dependency, not a final polish phase.

## 16. The first implementation slice

Do not start with a hundred new workouts. Start with the decision substrate:

1. Complete Gate 0 and reconcile doctrine.
2. Define `RunningAthleteState`, `RunningSeason`, `SessionIntent`, and `PlanDecisionRecord` as pure value
   models with no UI dependency.
3. Build the replay/shadow evaluation harness before changing live generation.
4. Extract current 5K/10K, half, and marathon behavior into explicit policy modules while preserving
   current outputs as golden fixtures.
5. Add only the state dimensions needed to improve a defined fixture, one at a time.
6. Review the first full road-season matrix with external coaches before exposing it to users.

That sequence gives Momentum a safe migration path: the current plan system keeps working while the new
coach is proven beside it.

## 17. Scope, dependencies, and non-goals

### In scope for the road-core program

- Plan creation, plan adjustment, feasibility, generation, adaptation, plan reveal, paywall preview,
  plan explanation, and post-race continuation.
- Beginner/return, general fitness, 5K, 10K, half marathon, and marathon policies.
- Runner-supporting strength and fueling objectives where they affect scheduling or session intent.
- Momentum-recorded workouts, athlete-entered facts, and Health recovery signals from connection
  onward.
- iPhone and Watch execution of the same persisted session intent.
- Local auditability, privacy-safe aggregate product analytics, and a shadow evaluation harness.

### Explicit non-goals for Release 1

- Replacing GPS capture, strength capture, Fuel, Progress, the Coach chat, or the current five-tab
  information architecture.
- Importing workouts from Health or rebuilding a hidden vendor importer.
- Building a general-purpose mathematical optimizer, ML training pipeline, or LLM plan generator.
- Shipping 800 m–3000 m, trail beyond the currently supportable 50K cases, 50-mile/100K/100-mile, or
  clinically governed pregnancy/postpartum programming under the road policy.
- Claiming complete youth/adolescent or para/adaptive coaching before those modules are co-designed and
  validated.
- Team dashboards, coach accounts, or remote manual plan editing.
- Claiming prevention, diagnosis, Olympic-level coaching, or guaranteed race outcomes.

### Live integration points that must remain working

- `Momentum/Engines/PlanEngine.swift` and `PlanModels.swift`: current pure generation contract.
- `Momentum/Persistence/PlanService.swift`: current input adapter and replace-on-rebuild persistence.
- `Momentum/Models/UserProfile.swift`, `TrainingPlan.swift`, and `AthleteModel.swift`: shipped data.
- `Momentum/Persistence/SchemaVersions.swift`: the only legal path for schema evolution.
- `Momentum/Features/Plan/PlanSettingsSheet.swift`: create/adjust funnel; plan name stays first.
- `Momentum/Features/Onboarding/*`: onboarding uses the same plan draft and preview contract.
- `Momentum/Features/Paywall/PaywallView.swift`: personalized goal promise and entitlement handoff.
- `Momentum/Engines/PlanCoaching.swift`, `RecoveryAdaptation.swift`, `EffortAdaptation.swift`, and
  `InjuryResponse.swift`: currently independent adaptation entry points that must converge safely.
- `Momentum/Services/Analytics.swift`: reviewed, non-PII event taxonomy.
- Existing self-coached plans: never generated, recalibrated, or structurally adapted by the coach.

## 18. Concrete domain contracts

The engine layer uses immutable Swift value types. SwiftData models are persistence records only.
Views do not construct engine types directly; a single adapter snapshots the store into a planning
request and maps a validated result back.

### 18.1 Evidence and confidence

The in-memory contract is conceptually:

```swift
struct Evidence<Value: Sendable>: Sendable {
    let value: Value
    let source: EvidenceSource
    let observedAt: Date
    let window: DateInterval?
    let sampleCount: Int
    let confidence: EvidenceConfidence
    let limitations: Set<EvidenceLimitation>
}

enum EvidenceSource: String, Sendable {
    case momentumWorkout, athleteEntry, fieldTest, raceResult
    case healthSignal, derived
}

enum EvidenceConfidence: String, Sendable {
    case unknown, low, moderate, high
}
```

Confidence is categorical and reasoned, not a decorative 0–100 score. Each dimension owns its own
freshness rule: a morning recovery signal may expire in a day, recent volume in weeks, and an event
result only when newer comparable evidence supersedes it. Confidence never rises merely because
Health is connected. Health signals cannot count as completed training exposure.

`EvidenceLimitation` includes at least `stale`, `smallSample`, `selfReported`, `poorGPS`, `missingRPE`,
`missingEnvironment`, `nonComparableConditions`, `partialSession`, and `outsideObservedDuration`.
Unknown is a valid state; the engine must not manufacture a midpoint to avoid showing uncertainty.

### 18.2 Planning request and athlete state

`PlanningRequest` contains:

- Stable request ID, planner/ruleset version, generated-at time, calendar/time zone, and display unit.
- Goal contract and season events.
- Availability, fixed dates, preferred days, session-time ceiling, equipment, and athlete overrides.
- `RunningAthleteState` and its evidence summary.
- Existing plan snapshot when adjusting, so the engine can minimize churn and produce a diff.
- Active safety restrictions and self-coached state.

`RunningAthleteState` v1 contains only state that changes a road-core decision:

- Current running frequency, weekly distance/time distribution, continuity, and longest recent run.
- Current performance curve with observed-duration bounds; optional threshold proxy and uncertainty.
- Easy-effort pace/HR/RPE trend under comparable conditions.
- Long-run durability and completion evidence when sufficient.
- Tolerance by session class: easy, quality, long, downhill, and lower-body strength.
- Typical recovery interval, schedule adherence pattern, and recent response flags.
- Environment/surface evidence only where known.

It deliberately does not contain a universal readiness score, injury probability, “running economy,”
or inferred menstrual phase. A field cannot enter the state until a rule consumes it and a fixture
demonstrates how behavior changes with it.

`RunningAthleteStateBuilder` reads bounded windows of Momentum workouts plus existing compact
`AthleteModel`/`FitnessSnapshot` facts; it does not walk an unbounded relationship on the main actor.
The planning snapshot may accept already-available recovery bands, but it never queries Health from
inside a pure policy and never blocks season generation on a live Health read. A bad night may adjust
today's execution; it does not rewrite the whole season baseline.

### 18.3 Season and event records

`RunningSeasonRecord` is a new SwiftData sidecar model with primitive/defaulted fields:

- `id`, `name`, `createdAt`, `updatedAt`, `statusRaw`, `primaryOutcomeRaw`, and `version`.
- A stable `profileID` and optional active-plan identifier; deleting/replacing a `TrainingPlan` must
  not delete the season.
- Events are new records keyed by `seasonID`. Release 1 may manage them explicitly instead of adding
  relationships to a shipped model class.

The athlete's plan name is the active season name and mirrors into `TrainingPlan.name` for current UI
compatibility. Base/build/recovery are phase labels, not silent renames. Rebuilds inside the season
preserve the name. Post-race recovery remains in the named season; when it ends, Momentum prompts for
the next goal/name rather than automatically creating an unnamed rolling plan.

`RunningEventRecord` stores `id`, `name`, `date`, `distanceM`, `durationS` for time-based events,
`priorityRaw`, `surfaceRaw`, optional ascent/descent meters, altitude band, technicality band, climate
band, and status. It stores SI values and raw strings with safe unknown fallbacks. Course/location
coordinates are not required for Release 1.

Release 1 prefers new sidecar records keyed by the existing stable UUIDs over adding properties or
relationships to shipped V1 model classes: `RunningSeasonRecord.profileID`,
`PlanMetadataRecord.planID/seasonID/plannerVersion/rulesetID`, and event `seasonID`. The existing
`UserProfile.plan`, race fields, goal fields, plan name, `TrainingPlan.sessions`, and their model
definitions remain intact. Direct relationships are allowed only after the version-scoped migration
spike in §21 proves the released V1 schema is actually frozen.

### 18.4 Session intent

`SessionIntent` is part of the generated value plan. In Release 1 it is persisted as a
`PlannedSessionIntentRecord` sidecar keyed by `plannedSessionID`, using primitive/defaulted fields:

- Stable intent ID and intent version.
- `stimulusRaw`, `sessionClassRaw`, `progressionLevel`, and `hardClassRaw`.
- Primary target hierarchy and allowed fallback targets.
- Work dose, recovery dose, success range, and expected recovery-cost band.
- Valid substitution IDs and minimum evidence to progress.
- Athlete-facing purpose and internal rule IDs.

Existing `runType`, distance, duration, pace, interval text, rationale, and strength targets continue
to render older plans. The persistence adapter creates/deletes sidecars in the same transaction as
their sessions and removes orphans in an idempotent maintenance pass. New surfaces prefer intent data
when present and fall back to current fields when absent. Live guidance reads the same target
hierarchy; it must not independently reinterpret the session from its display text.

### 18.5 Decision record

`PlanDecisionRecord` is a local SwiftData audit record owned by the athlete/season, not by the
replaceable current plan. It stores:

- Decision ID, request ID, plan/season IDs, date, trigger, status, planner version, and ruleset ID.
- Old/new plan digests and a compact structured diff.
- Applied rule IDs, hard constraints, relaxed preferences, confidence bands, and limitation codes.
- Athlete-facing headline/detail plus whether the athlete accepted, declined, or undid it.
- No route, raw Health sample, exact location, free-form medical note, or third-party analytics ID.

For reproducibility it also stores a versioned, compact normalized-input payload containing the exact
plan-critical aggregates used—such as current volume distribution, performance estimate, availability,
and evidence bands—but never raw sensor samples, GPS points, or unrestricted text. The semantic digest
detects corruption; the payload allows local replay. These tiny records are retained until the athlete
deletes their data unless a separately reviewed retention policy replaces that default.

Records remain local until an owner-only RLS sync design is separately reviewed. They are included in
the user's export and deletion path. Product analytics receive only coarse event categories; the audit
record itself is never sent through `app_events`.

### 18.6 Rule and evidence registry

Every numerical or categorical training rule has one registry entry:

- Stable `ruleID` and semantic version.
- Owning policy and code symbol.
- Purpose, supported population, input/output units, bounds, and fallback.
- Source type: published evidence, expert consensus, internal operational constraint, or provisional
  product heuristic.
- Source link/citation, population limitations, evidence confidence, owner, approval date, next review
  date, and deprecation status.
- Fixtures that exercise the rule and product copy that depends on it.

A heuristic may ship, but it must be labeled a heuristic internally and bounded conservatively. A
source does not automatically validate the implementation or population. A rule cannot be silently
edited: behavior changes require a new ruleset version and shadow comparison.

The runtime source of truth is a typed, compiled `RunningRuleRegistry`; a document or remote JSON may
describe it but cannot override dose/safety values. The rollout service may select only a complete,
already-shipped and already-qualified ruleset ID. It cannot tune numbers remotely. A build test fails
for duplicate/missing rule IDs, invalid units/bounds, missing owner/source/review date, or a trace rule
that is absent from the registry.

## 19. Deterministic planner and policy behavior

### 19.1 Policy interface

Each event policy implements the same pure contract:

```swift
protocol RunningPolicy: Sendable {
    var id: RunningPolicyID { get }
    var version: Int { get }
    func feasibility(for request: PlanningRequest) -> FeasibilityResult
    func blockMap(for request: PlanningRequest) -> [BlockIntent]
    func weeklyDose(for context: PolicyWeekContext) -> WeeklyDoseEnvelope
    func sessionIntents(for context: PolicyWeekContext) -> [SessionIntent]
    func exitDecision(for context: BlockExitContext) -> BlockExitDecision
}
```

Policies choose training content and progression. Shared code owns evidence normalization, calendar
math, hard safety restrictions, scheduling, target derivation, rounding, invariant validation,
decision traces, persistence, and rollback. A policy cannot directly mutate SwiftData or read Health.

### 19.2 Generation pipeline

One request always runs these passes in this order:

1. **Snapshot:** read SwiftData once and form an immutable `PlanningRequest` on the main actor.
2. **Normalize:** resolve units, local-day boundaries, time zone, duplicates, source priority,
   evidence freshness, and unknown values. Preserve raw evidence for the trace.
3. **Select policy:** map the explicit goal/event to a supported policy. Unsupported combinations
   return a typed conflict; they never fall through to the nearest distance template.
4. **Assess feasibility:** calculate current outcome range, required commitment, runway, and conflicts
   before generating sessions.
5. **Map blocks:** place bounded base/build/specific/taper/recovery objectives around fixed events.
6. **Build dose envelopes:** establish weekly distance/time, frequency, long exposure, intensity,
   strength, and recovery ranges before choosing workouts.
7. **Create intents:** select the smallest set of session intents that satisfies the block objective.
8. **Schedule:** place fixed events first, then hard/long/strength constraints, then preferences using
   deterministic tie-breaks. Do not use random selection or unordered fetch order.
9. **Calibrate targets:** derive target ranges from evidence appropriate to each intent; attach
   limitations and fallbacks.
10. **Guard load and response:** evaluate mechanical exposure, concentration, progression, active
    restrictions, and recovery spacing. A guard may reduce or reject; it cannot add dose.
11. **Snap for display:** round distance/pace only after calculations, in the athlete's display unit,
    while storing SI. Recalculate totals from snapped prescriptions.
12. **Validate:** run all hard invariants again on the final snapped plan. Validation returns either a
    complete candidate or typed errors—never a partially valid plan.
13. **Explain:** create a deterministic structured trace; templated copy renders from it. The LLM may
    rewrite within bounded meaning but cannot alter numbers, verdict, confidence, or rule IDs.
14. **Commit:** only the persistence adapter may atomically swap a validated candidate into the live
    relationship and append its decision record.

The same normalized request, ruleset, policy version, calendar, and catalog produces equal semantic
output. Generated UUIDs, timestamps, and narrative text are excluded from the semantic digest or are
injected deterministically in tests.

### 19.3 Hard constraints

At minimum, the final plan must satisfy:

- One explicit primary outcome and no sessions after a terminal A race unless they belong to an
  explicit recovery/next block.
- Race/tune-up dates and athlete-declared unavailable days are fixed.
- Frequency never exceeds the athlete's chosen day budget; doubles require explicit capability and
  consent.
- Start/return athletes receive no quality intent until their policy's continuity/response gate.
- Hard-run, long-run, downhill, plyometric, and hard lower-body strength adjacency follows the rule
  registry and active safety restrictions.
- Weekly and session dose remain inside the accepted envelope after unit rounding and substitutions.
- Taper and post-race recovery cannot be displaced by make-up work.
- Missed sessions are moved, reduced, substituted, or dropped; never stacked to preserve a paper total.
- Active injury/return restrictions override goal pace, performance mode, and event ambition.
- A candidate with missing essential inputs yields a conflict/fallback, not `NaN`, infinity, zero pace,
  negative duration, or an empty unexplained week.
- Self-coached plans are read-only to automatic generation/adaptation.

### 19.4 Soft preferences and infeasibility

After hard constraints, the scheduler prefers, in order:

1. The athlete's explicit days and long-run day.
2. The schedule they have actually executed consistently.
3. Minimal movement from the current plan when adjusting.
4. Even recovery spacing and preferred session-duration fit.
5. Equipment, surface, terrain, and time-of-day access.
6. Variety among equivalent intents.

If no schedule exists, the engine returns `PlanningConflict` with the exact violated constraints and
ordered resolutions. The UI can offer “add one day,” “reduce the target,” “move the event,” or “build
base first.” It must not silently add a day, compress recovery, remove the main stimulus, or promise
the original outcome.

### 19.5 Road-core policy minimums

These define product behavior, not unsourced fixed percentages. Exact dose bounds live in the rule
registry and require fixtures plus coach approval.

**StartReturnPolicy**

- Time/effort and run-walk before pace; frequency/impact tolerance before workout sophistication.
- Progress only after repeated completion with acceptable during/next-day response.
- Hold or regress one progression level after symptoms or repeated excessive response; escalate when
  symptoms meet the clinical boundary.
- A first 5K may be a completion outcome without requiring a maximal test.

**Road5K10KPolicy**

- Aerobic consistency, threshold development, economical speed exposure, event-specific work, and
  enough long running for the athlete's level.
- One or two quality exposures only when continuity, frequency, and recovery history support them.
- Short repetitions use pace/execution quality; easy work never becomes a disguised pace test.

**HalfMarathonPolicy**

- Aerobic volume tolerance, threshold/steady duration, long-run durability, and progressive
  event-pace exposure.
- Fueling practice appears when session duration makes it relevant; no dieting language.
- A fast short-race estimate cannot substitute for evidence that the athlete can sustain the long
  exposure.

**MarathonPolicy**

- Long-run and cumulative durability, marathon-specific work, fueling/gut rehearsal, recovery, and
  taper are explicit block objectives.
- Goal-pace volume is constrained by current capacity and total load; infeasible target pace remains
  a goal label, not a forced prescription.
- Peak work cannot be “made up” inside taper. Inadequate preparation changes the race-day outcome
  guidance rather than creating a last-minute fitness cram.

General fitness without a race uses the road policy substrate but a renewable base/development block,
no fake race date, and a user-selected outcome such as consistency, endurance, or first continuous
run. Weight-loss goals are translated into sustainable running/fueling support; the plan does not set
an aggressive calorie deficit, predict a date/amount of weight loss, or promise a body-mass result.
Athlete-facing copy says the plan supports that motivation by building a consistent running routine;
Fuel keeps floors and performance support. Strength/build-muscle motivations remain runner-supporting
inside this product rather than silently turning the road planner into a bodybuilding system.

### 19.6 Evidence comparison rules

Evidence may update a state dimension only when the comparison is meaningful:

- GPS pace requires acceptable trace quality and a non-paused execution window.
- HR comparisons require sufficient samples and known sensor reliability; wrist HR is supporting
  evidence, not a steering target for short repetitions.
- RPE may stand alone for session response, but absent RPE cannot be imputed from pace.
- Grade/environment normalization applies only when inputs are known and the rule is validated. If
  weather, altitude, wind, surface, or treadmill calibration is unknown, confidence widens instead.
- A partial, interrupted, paced, trail, heat-affected, or untapered effort retains those limitations.
- Performance evidence updates most strongly near the observed duration. Extrapolation uncertainty
  grows as target duration moves away from it.
- Personal trends require the same intent class and sufficiently comparable conditions; otherwise the
  observations remain separate evidence rather than a forced trend line.

The first version uses explicit bands and reason codes. It does not fit an athlete-specific statistical
model until the replay corpus demonstrates enough samples, stability, and actionable improvement to
justify one.

### 19.7 One execution prescription across phone and Watch

A pure `ExecutionPrescriptionBuilder` converts `SessionIntent` plus the persisted legacy fields into
one versioned payload consumed by Today, session detail, iPhone live tracking, Watch, post-run review,
and substitutions. Those surfaces may format differently; they may not derive different targets.

- Payload carries stable plan/session/intent IDs, schema version, target hierarchy/ranges, reps and
  recovery, fallback target, and athlete-facing purpose.
- Existing distance/duration/pace/interval fields remain populated so an older or temporarily stale
  Watch payload can execute the safe legacy prescription.
- Unknown payload fields are ignored and unknown versions fall back to the legacy fields; never crash
  or block a run.
- Phone↔Watch completion is idempotent by session/workout ID and cannot create two workouts or mark two
  sessions complete.
- GPS/HR loss on Watch selects the intent's explicit effort/time fallback. It does not manufacture
  pace/HR evidence for later calibration.
- A mid-session execution adjustment changes the allowed range/cues only within the intent contract;
  a structural plan change waits until the workout finishes.

Extend `StructuredWorkoutBuilder+Session.swift`, live-coach fixtures, Watch payload tests, and
phone/Watch version-skew tests before any new intent becomes live.

## 20. Adaptation and failure-state specification

### 20.1 Adaptation transaction

All automatic and user-approved plan changes enter one coordinator. The coordinator:

1. Takes an immutable snapshot of the live plan, relevant completed workouts, state, and rule version.
2. Collects proposals from injury, illness/recovery, load-response, missed-session, calibration,
   schedule, and preference rules.
3. Deduplicates proposals by affected session/stimulus.
4. Resolves them using the priority in §9 and selects the smallest sufficient change.
5. Applies the change to an in-memory candidate.
6. Validates the entire affected horizon, not only the next session.
7. Commits candidate, timestamps, and `PlanDecisionRecord` in one `ModelContext` save.
8. Exposes a bounded undo when reversing is still safe. Undo itself is a recorded transaction.

There are three distinct budgets:

- **Execution adjustment:** same-day pace/effort range or quality-to-easy downgrade; reversible and
  not a structural rewrite.
- **Automatic structural transaction:** at most one per rolling seven days in normal conditions.
- **Safety override:** may reduce/stop work regardless of the normal budget. It is idempotent and can
  never increase dose. A previous performance change cannot block it.

A user explicitly changing goal, event, availability, or plan settings starts a deliberate re-plan,
not an automatic adaptation. The UI shows the diff and asks for confirmation. The change budget is
reset only as part of the new plan transaction; it is not an escape hatch for hidden daily churn.

### 20.2 Bidirectional calibration

- Sharpening requires either a qualifying race or repeated comparable high-quality evidence, stays
  bounded per update, and cannot co-occur with a protective ease in the same transaction.
- Easing may be athlete-approved after a single clear target mismatch, or automatically proposed only
  after repeated comparable mismatch. Automatic easing ships after coach review; until then it is a
  transparent suggestion.
- One bad race does not automatically slow training because heat, illness, terrain, fueling, tactics,
  or an off day may explain it. It opens a review and combines with prior evidence.
- Post-race recovery is decided independently of whether the performance estimate moved faster or
  slower. Completion of the event does not erase the evidence or rename the plan until the transition
  transaction succeeds.
- The new post-race transaction keeps the completed season/name through recovery, marks the event
  complete, preserves the result, and prompts for the next named goal after recovery. It never blanks
  `TrainingPlan.name` automatically.
- The existing `PlanService.completeRace` faster-only branch remains unchanged until this replacement
  has fixtures for good race, bad race, DNF, unlogged race, wrong-distance GPS, hot race, trail race,
  and delayed app reopen.

### 20.3 Required fallback matrix

Each fallback has three explicit parts: engine behavior, athlete experience, and a forbidden failure.

- **No Momentum run history:** use explicit starting-point answers and a conservative policy default
  with low confidence; say “we’ll learn from your first two weeks”; never pretend Health supplied
  training history.
- **One active week only:** keep it as an observation rather than established weekly load; show the
  declared baseline and observation separately; never seed a whole season from one week.
- **Missing RPE:** use external execution evidence with lower response confidence and offer an optional
  one-tap follow-up; never infer effort from pace.
- **Missing/unreliable HR:** use the intent's talk-test/RPE/pace hierarchy and let the session work
  normally; never block the run or invent HR zones.
- **Poor/missing GPS:** preserve completion if recorded but exclude pace calibration and explain why;
  never recalibrate from a spike or frozen trace.
- **Treadmill:** use time, RPE, and athlete-confirmed distance/calibration with treadmill-specific
  target fallbacks; never treat belt/display pace as GPS truth.
- **Weather unavailable:** do not normalize heat/wind and widen the target range with effort-first
  copy; never apply guessed conditions.
- **Unknown trail/vertical:** use road policy only when the course is road-compatible; otherwise ask
  for course demands or offer base support; never call the result course-specific.
- **Several missed sessions:** drop/re-sequence work, re-check feasibility, and give one calm rationale;
  never cram mileage or stack hard days.
- **Active pain/injury:** apply the gated injury/return path and escalation boundary with neutral
  “training around this” language; never diagnose or let the goal override safety.
- **Acute illness concern:** make a conservative same-day stop/ease decision and recommend qualified
  care when indicated; never label a disease from wearable signals.
- **Goal becomes infeasible:** preserve safety and offer date/outcome/commitment choices with an
  explicit revised verdict; never secretly raise intensity.
- **Plan validation failure:** keep the current plan untouched and use the legacy fallback only when
  supported; never persist a partial candidate.
- **App terminates during re-plan:** keep the old plan live until atomic commit and resume the draft;
  never delete first and generate second.
- **Offline:** generate/adapt locally and queue only allowed analytics/sync work; never require the
  server or an LLM for core coaching.
- **Entitlement/paywall failure:** keep the existing plan/draft and offer pricing retry or dismiss;
  never lose the old plan or block workout logging.
- **Self-coached plan:** observe without generated changes and keep the athlete in control; never
  recalibrate or rewrite their targets.

This fallback matrix is an acceptance-test source. Each item requires at least one engine test and,
where it has a visible state, one UI test or simulator screenshot fixture.

## 21. Persistence migration, compatibility, and rollback

The current `PlanService.persist` deletes the old plan before inserting the new one. That is acceptable
for a validated legacy rebuild, but it is too risky as the boundary for a new planner. The migration is
staged as follows.

### Stage A — freeze and observe; no schema change

- Capture semantic golden fixtures for current beginner, 5K, 10K, half, marathon, general fitness,
  strength-support, self-coached, post-race, injury, missed-week, and pace-easing behaviors.
- Add a pure semantic plan digest and validator around current `GeneratedPlan`.
- Record no new athlete data. Shadow results are memory-only in production and file/fixture output in
  development tests.

### Stage B — pure contracts; still no live behavior change

- Add `Momentum/Engines/Running/` value models, policies, rule registry, trace, validator, and replay
  harness.
- Implement a `LegacyRoadPolicyAdapter` that reproduces current generated outputs.
- Run both planners in tests; production continues to call `PlanEngine` only.

### Stage C — versioned additive store migration

- Start with a migration spike before editing any shipped `@Model`. The current `SchemaV1.models`
  points to mutable top-level model types; that list alone does not preserve the old property layout
  after those classes change. Apple's schema-migration pattern encapsulates the model definitions for
  every released version. Follow and verify that pattern before relying on V1→V2 diffs; see
  [Apple's SwiftData schema guidance](https://developer.apple.com/videos/play/wwdc2023/10195/).
- Preferred Release 1 path: leave shipped V1 model classes unchanged and declare `SchemaV2` as the V1
  model list plus new sidecar entities. Append the explicit lightweight stage to
  `MomentumMigrationPlan`.
- Change the production container and `PersistenceController.models` test/previews seam to the latest
  schema only after V2 is declared; keep `MomentumMigrationPlan.schemas` ordered V1 then V2. Add a
  test that every intended persisted model appears exactly once in the latest schema.
- If direct fields/relationships on existing models are necessary, first create immutable
  version-scoped V1/V2 model definitions (and latest-model aliases/adapters), then prove the migration
  with a store written by the previous shipping binary. Do not infer safety from an in-memory store.
- Do not rename, retype, or delete V1 plan/profile/session fields in this program.
- Test a committed archived V1 store, not only an in-memory container. Verify all model counts,
  workout IDs, GPS sample counts, plan name, completed links, photos, Athlete Model notes, and current
  plan prescriptions after opening with V2.
- Treat any unexpected quarantine as a release blocker. The recoverable quarantine path is a last
  resort, not an accepted migration strategy.

### Stage D — lazy, idempotent season backfill

- On first plan read, an adapter may construct one active season sidecar from the existing
  profile/plan IDs, goal, name, race date/distance/time, and block start.
- Backfill never regenerates sessions, changes a goal, clears a race, or writes a decision record that
  implies a coaching change.
- Mark the backfill version. Re-running it yields the same IDs/values and no duplicate events.
- Keep legacy goal fields synchronized through one `PlanConfigurationCommand`; views may not write both
  models independently.

### Stage E — candidate-first persistence

- Generate and validate the complete candidate in memory.
- Commit through one throwing `PlanStore` operation keyed by unique request ID. Fetch the profile by ID
  in the store's context, disable autosave for the operation, and do not suspend/yield while mutating.
- In that transaction, detach the documented completed sessions, insert the candidate plan, point
  `profile.plan` directly from old to new (never through `nil`), persist metadata/intent sidecars and
  the decision record, then delete the superseded plan and its sidecars.
- Save exactly once. Do not use `try?` on the candidate path. If save fails, call rollback, return a
  typed error, and retain the old plan. A repeated request ID returns the previously committed result
  instead of generating duplicate sidecars/decisions.
- Preserve plan name unless the athlete explicitly changed it. Preserve completed work and linked
  workouts exactly; new intent IDs apply only to newly generated open sessions.
- Prove main-context refresh/observation after the store save; the UI must not hold a stale old plan or
  briefly render no plan. A real-store failure-injection test, not API assumptions, decides whether the
  final implementation uses the main context or a dedicated `@ModelActor` context.

### Stage F — shadow and gated live cohorts

- Shadow mode reads the same immutable request but cannot access a writable `ModelContext`.
- Compare semantic digests and classified differences; never log raw plan, exact pace, goal time,
  Health values, or schedule to analytics.
- Enable a policy only for its reviewed event family. Unsupported/flag-off requests use the current
  planner without mutating new season meaning.

### Rollback contract

- Ship a `PlannerRolloutPolicy` with bundled-safe default `.legacy` and a cached allow-listed remote
  value when rollout infrastructure exists. Network failure uses the last safe value; a fresh install
  never opts into an experimental planner by accident.
- A kill switch changes which generator handles the next request; it does not delete V2 data or
  rewrite an already valid plan.
- Every V2-rendered plan remains readable by the current plan UI through legacy fields.
- Rolling back live generation must not require a down-migration. Breaking-field cleanup waits for a
  later schema after adoption and export/restore testing.
- The support runbook includes engine/ruleset identification, decision-record export, flag rollback,
  and store-quarantine recovery.

### Sync boundary

Release 1 does not require cloud sync of seasons/decision records. If added, it requires separate
Supabase migrations, owner-only RLS tests, idempotent upserts, deletion/export coverage, and conflict
resolution that never merges two different generated plans session-by-session. The local SwiftData
plan remains authoritative. `app_events` is not a substitute for personal-data sync.

## 22. Plan creation, adjustment, reveal, and paywall UX

Plan creation and adjustment use one `PlanDraft` and one feasibility/preview service. Onboarding is a
presentation of that flow, not a separate planning implementation.

### 22.1 Screen hierarchy and state machine

The creation/adjustment page order is fixed:

1. **Plan name** — first visible editable field, above goal. Existing name is prefilled on adjustment;
   new plan is blank with an optional goal-derived suggestion that the athlete can accept.
2. **Goal** — outcome, event family, distance/duration, date, and finish/placement/qualifying intent.
3. **Where you are now** — current frequency, volume/time, longest run, performance evidence, source,
   freshness, and confidence. Athlete entry and Momentum-observed facts stay visibly distinct.
4. **Feasibility** — on track, possible with trade-offs, or build-first/revise-goal. No red failure.
5. **Availability** — days, fixed unavailable dates, long-run day, session-time constraints.
6. **Preferences/modifiers** — strength, surface/access, intensity preference, recent interruption,
   and relevant injury status.
7. **Recommended commitment** — what the goal reasonably asks from the athlete and which input would
   need to change when it does not fit.
8. **Preview/diff** — phases, representative first week, material changes, uncertainty, and reason.

The state machine is:

`editing → checking → previewReady → awaitingConfirmation → building → reveal → committed`

with explicit `unsupported`, `needsInput`, `validationFailed`, `paywallPending`, and `cancelled`
branches. Going back preserves the draft. Cancelling or dismissing preserves the existing live plan.
Only `committed` changes `profile.plan`.

### 22.2 Input behavior

- Every field explains why Momentum needs it when the reason is not obvious.
- Required fields are goal-dependent. A general-fitness plan does not ask for a race date; a trail
  goal asks course demands only when that policy is available.
- Name is never overwritten during recalculation, rebuild, race completion, or paywall dismissal.
- Current baseline is evidence, not a difficulty slider. An athlete can correct an inaccurate input,
  but the UI preserves source/provenance and does not let preference masquerade as observed fitness.
- Goal time defaults, if offered, are labeled suggestions and never silently saved as the athlete's
  target.
- A body-composition motivation does not ask for a deadline/target mass in the core plan funnel or
  convert a safe training plan into a calorie prescription. Any entered body-mass data remains
  optional personal context with the existing Fuel/privacy boundaries.
- A low-confidence baseline produces a conservative two-week learning block and a clear calibration
  option; it does not add a long questionnaire by default.
- Changing a material input recomputes feasibility after a short debounce or explicit Continue, not
  on every wheel tick with visible plan churn.

### 22.3 Feasibility language

Every verdict contains:

- The outcome being evaluated.
- What evidence Momentum used and what is missing.
- The primary constraint: runway, recent volume/tolerance, availability, event demands, or confidence.
- The recommended path and at most three actionable alternatives.
- The consequence of each alternative in plain language.

The verdict never says “impossible” from sparse data. It can say Momentum cannot responsibly prescribe
that outcome from the available evidence. Goal pace may remain visible as the athlete's ambition while
training prescriptions use the evidence-capped range.

### 22.4 Adjustment diff

Before replacing an existing plan, show a semantic diff:

- Goal/event/date and plan-name changes.
- Days/week or long-run-day changes.
- Block/phase change.
- Weekly volume/time direction and range, not noisy per-meter deltas.
- Sessions added, removed, moved, or changed in stimulus.
- Pace/effort target direction and reason.
- What is deliberately unchanged.

The athlete can confirm, go back, or cancel. For a user-requested change, there is no hidden automatic
commit. A pure cosmetic name edit may save immediately because it does not regenerate the plan.

### 22.5 Reveal and paywall boundary

The reveal proves decision quality before asking for payment:

- Their named goal and exact event/outcome.
- A calm “starting from” summary with source/confidence.
- The feasibility verdict and trade-off.
- Phase blueprint and first-week session purposes.
- One example of how Momentum will respond to a missed/recovery day.
- Clear boundaries: numbers are deterministic; AI explains; Health supplies signals only.

The candidate plan may be generated in memory for preview. It is not committed before entitlement and
confirmation. Closing the paywall leaves the old plan or draft unchanged. Pricing/network failure does
not block workout logging or access to an already-owned plan. The paywall never implies the athlete
will hit a time, lose weight, avoid injury, or receive Olympic coaching.

Conversion work may test layout, copy, sequencing, or how much validated preview is shown. It may not
A/B test safety constraints, inflate feasibility, conceal uncertainty, or assign more aggressive
training to improve conversion. Conversion is a business metric; plan validity and athlete trust are
release gates.

### 22.6 Accessibility and visual QA

- VoiceOver announces section, value, units, confidence, selected state, and consequence—not color.
- Dynamic Type through accessibility sizes keeps plan name, goal, verdict, and primary action visible
  without clipping; dense charts/detail may move to a secondary view.
- Every numeral uses tabular figures. Distance/time units are explicit and stored SI.
- Reduce Motion uses crossfades/static iridescence. Plan reveal iridescence remains earned-only.
- Light/dark screenshots cover create, adjust, low-confidence, infeasible, preview diff, paywall,
  validation error, and successful reveal on at least one small and one large iPhone.
- UI tests assert the plan-name field appears before the goal section in both create and adjust modes.

## 23. Privacy, analytics, and research data

Three data planes stay separate:

- **Personal training data:** SwiftData source of truth; workouts, plan, season, evidence, and local
  decision records. Covered by export/delete and future owner-only sync only.
- **Product analytics:** existing write-only `app_events` path with coarse allow-listed parameters.
- **Research/validation dataset:** opt-in, separately consented, de-identified export with a written
  protocol; never inferred from ordinary analytics consent.

Suggested analytics events are coarse enums/counts only:

- `plan_flow_started(mode, has_existing_plan)`
- `plan_goal_selected(goal_family)`
- `plan_baseline_viewed(confidence_band, source_category)`
- `plan_feasibility_viewed(verdict)`
- `plan_preview_viewed(policy_id, horizon_band)`
- `plan_diff_viewed(change_category_count)`
- `plan_build_result(planner_version, policy_id, result_category)`
- `plan_change_response(change_kind, response)`

Do not send plan name, race name/date, exact distance/time/pace, weekly volume, injury area, check-in,
Health value, location, workout ID, decision text, or free text. `goal_family` is a broad enum; target
time and event identity are not analytics dimensions. Existing paywall events remain the conversion
source of truth and are joined only by the random install ID already used by the sink.

Analytics schema changes require parameter-length tests, offline queue tests, 4xx drop/5xx retry tests,
and review that Sentry receives no newly sensitive breadcrumbs. Shadow comparison reports only planner
version, policy, and difference category/count; detailed diffs stay local to development or an
explicitly consented research export.

## 24. Verification plan and non-negotiable release gates

### 24.1 Canonical fixture matrix

Maintain at least 32 human-readable full-season golden personas for Release 1: eight each for
start/return, 5K/10K, half marathon, and marathon. Across them, cover:

- First-time runner, returning runner, recreational continuous runner, experienced competitor, and
  masters athlete without using age as the only recovery signal.
- One through seven available days, short/long session windows, fixed long-run day, travel week, and
  an impossible schedule.
- No history, one active week, stable history, rising history, recent break, inconsistent history,
  and high volume relative to the selected goal.
- No finish target, realistic target, tight target, and clearly unsupported target.
- Short, adequate, and long runway; date crossing DST; year boundary; leap day; locale/week-start
  differences; metric and imperial display.
- No injury, historical modifier, active mild report, active severe report, and return progression.
- Run only, one/two runner-strength days, equipment limits, and hard lower-body sequencing.
- No Health connection, sparse signals, stable signals, conflicting signals, and missing subjective
  feedback—without any Health workout rows.
- Good GPS, poor GPS, treadmill, heat/environment unknown, and hilly course where normalization is or
  is not available.
- Missed easy run, missed quality run, repeated misses, pause/resume, goal edit, race completion,
  DNF/unlogged race, and self-coached plan.

Each fixture states inputs, evidence confidence, expected feasibility, policy, block objectives,
weekly/session bounds, hard invariants, permitted output ranges, expected trace rules, and athlete copy
intent. It should not golden-test every rounded meter if a safe range is the actual contract.

### 24.2 Automated test layers

**Pure unit/property tests**

- Same normalized request/ruleset produces the same semantic digest across repeated runs.
- At least 10,000 seeded adversarial combinations per live policy run through the invariant validator
  in CI/release qualification with zero hard violations.
- No invalid number, overflow, negative duration/distance, unknown enum crash, impossible date, or
  unsorted/duplicate session identity.
- Policy monotonicity where it is a real contract: reducing availability cannot increase prescribed
  frequency; adding an active restriction cannot increase dose; lower evidence confidence cannot make
  a target more aggressive.
- Unit-rounding pass is revalidated and remains inside dose/spacing constraints.
- Unsupported event combinations return typed conflicts, never a neighboring policy.
- AI/templating tests prove narrative cannot alter numeric decisions.

**Integration tests**

- `PlanConfigurationCommand` dual-write compatibility and idempotent season backfill.
- Candidate-first commit, save failure, cancel, undo, race completion, and completed-session carryover.
- All adaptation producers route through the coordinator; lower-priority/increase proposals are
  suppressed correctly; safety override is not blocked by the weekly budget.
- Self-coached plans remain byte-equivalent after every automatic trigger.
- Health authorization and new Health signals create zero `Workout` rows.
- Offline generation and cold-launch recovery preserve current plan and all logged workouts.
- Export/delete includes/removes new personal records; analytics never contains them.

**Migration tests**

- Open a committed archived V1 store with V2, then compare model counts, stable IDs, core field values,
  relationship integrity, GPS samples, photos, plan name, completed links, and Athlete Model memory.
- Reopen after migration, repeat backfill, simulate interrupted launch, export, delete, and account
  switch.
- Expected result: zero quarantine events and zero lost/cross-account data in the qualification suite.

**UI and accessibility tests**

- Create and adjust flows prove plan name is above goal, current baseline/source is shown, verdict
  updates, back preserves the draft, cancel preserves the live plan, and confirm produces the shown
  semantic diff.
- Paywall close, purchase failure, successful entitlement, restore purchase, and offline pricing states
  preserve the plan contract.
- VoiceOver order/labels, Dynamic Type, Reduce Motion, light/dark, small/large phones, keyboard focus,
  and long localized strings.
- Simulator screenshots use explicit UDIDs and the DEBUG deep-link/seed fixtures; visual approval is
  attached to the change.

Run the generated Xcode project with the repository-prescribed sequence: regenerate with XcodeGen when
needed, run `build-for-testing`, then `test-without-building` on the same explicit simulator and
DerivedData. Run the whole Swift Testing scheme because an incorrect `-only-testing` identifier can
silently execute zero tests. Focused tests are an iteration aid, never the final gate.

### 24.3 Software release thresholds

A planner/ruleset version cannot enter athlete beta unless all are true:

- Whole scheme passes from a fresh build; zero skipped critical planner/migration tests.
- Zero hard invariant violations in golden and seeded property suites.
- Zero archived-store migration quarantines, plan/workout losses, or relationship corruptions.
- Zero writes from shadow mode and zero automatic mutations of self-coached plans.
- Zero known P0/P1 defects and no unresolved security/privacy finding in the changed data path.
- Candidate generation p95 is at or below 250 ms on the oldest supported reference iPhone for the
  longest Release 1 horizon, measured outside DEBUG; UI stays responsive because planning runs off the
  main actor after its immutable snapshot.
- Existing quality bars remain: cold start to workout start under two seconds, workout durability,
  crash-free above 99.5%, and GPS acceptance behavior unchanged.
- Analytics allow-list review confirms no exact performance, health, event, location, name, or free
  text left the device.

### 24.4 Expert-review protocol

- Two independent appropriately qualified running coaches review every canonical season for the
  policy they know; a sports-medicine/physical-therapy reviewer additionally reviews return/injury
  behavior, and a dietitian reviews marathon fueling claims.
- Reviewers receive the athlete evidence/confidence, goal, complete season, selected decision traces,
  and adjustment scenarios without being told whether the plan is legacy or candidate when a blind
  comparison is possible.
- They score stimulus appropriateness, progression, recovery, specificity, feasibility, strength/fuel
  integration, explanation, and uncertainty on a defined five-point rubric.
- A policy passes only with median at least 4/5 on every dimension, no score below 3 on safety or
  feasibility, and no unresolved material safety objection. Numerical thresholds are a product gate,
  not proof of coaching efficacy.
- Disagreements are logged by persona/rule. Resolution may change a rule, narrow the supported
  population, widen uncertainty, or keep legacy behavior. Copy polish alone cannot close a dose or
  safety disagreement.

### 24.5 Prospective validation

Use two stages and do not overclaim either:

1. **Usability/decision pilot:** small cohorts in each supported family test comprehension, plan fit,
   execution, feedback burden, and adaptation trust. This identifies defects; it cannot establish
   injury reduction or performance efficacy.
2. **Outcome pilot:** a statistician/sport scientist defines population, comparison, sample size,
   duration, primary outcome, harms, missing-data handling, and stopping rules before enrollment.

Pre-register the pass/fail thresholds before seeing outcome data. At minimum measure retention in the
prescribed family, completed-intent match, excessive-response frequency, pain/injury interruptions,
adaptation proposal/accept/undo/churn, feasibility calibration, fitness/race outcome with uncertainty,
and trust/comprehension. Report beginner, recreational, competitive, masters, and sex/gender data
separately where sample size permits; do not hide a weak subgroup inside a pooled average.

The pilot stops or pauses enrollment for a plan-attributable serious safety concern, repeated hard
invariant escape, unexpected plan deletion/data loss, or systematic expert/athlete report that an
intent is being misprescribed. The advisory/clinical owner, not growth, decides restart after review.

## 25. Rollout and incident runbook

### 25.1 Cohort sequence

Planner status is one of `legacy`, `shadow`, `candidatePreview`, or `live`; there is no ambiguous
Boolean. Advance one policy at a time:

1. **Developer fixtures:** new code reachable only from tests/DEBUG deep links.
2. **Internal shadow:** candidate computes locally beside legacy; no persistence, user copy, or
   candidate-driven analytics.
3. **Advisory review build:** named fixtures and manually inspectable traces; still no live mutation.
4. **Staff/TestFlight candidate preview:** candidate UI/diff is visible, but confirmation uses legacy
   unless an explicit tester flag enables live commit.
5. **Opt-in athlete pilot:** separately consented, one supported family, explicit fallback.
6. **Small production cohort:** cached allow-listed rollout, monitored by planner/ruleset/policy.
7. **Progressive expansion:** only after a full adaptation window and review of migration, stability,
   support, and safety signals—not solely conversion.
8. **Default live for that policy:** legacy remains available for rollback through at least one full
   app release and all older stored plans remain readable.

Do not roll out multiple new policies or a new persistence schema and new adaptation behavior to the
same first cohort. Schema compatibility lands first, then shadow, then one policy, then adaptation.

### 25.2 Automatic pause/rollback triggers

Immediately stop expansion and set affected policy to legacy on:

- Any confirmed new-planner plan/workout deletion, broken completed-workout link, or migration
  quarantine above the established baseline.
- Any hard invariant escape into a committed plan.
- Any Health-sourced `Workout` creation.
- Candidate writes in shadow mode or an automatic change to a self-coached plan.
- A safety/privacy/security incident, sensitive analytics payload, or cross-account record exposure.
- Crash/hang regression that threatens the existing >99.5% crash-free bar or workout-start path.
- Repeated structural adaptation inside seven days without an allowed safety/user-initiated reason.
- A clinician/advisory escalation judged plausibly caused by a policy rule.

Conversion decline alone does not auto-roll back a safe planner; it triggers UX analysis. Conversion
gain never overrides a safety or truth trigger.

### 25.3 Incident response

For each incident:

1. Freeze the policy/ruleset cohort and preserve the exact build/flag state.
2. Identify planner version, ruleset, policy, semantic digest, and local decision record with athlete
   consent; do not ask for a route or full Health export by default.
3. Reproduce from a sanitized fixture or exported request.
4. Classify as migration, persistence, policy, scheduler, calibration, adaptation, rendering, or copy.
5. Roll back generation when needed; leave the athlete's valid current plan intact.
6. Add the case to regression fixtures, change/version the responsible rule, re-run all lower gates,
   and document the athlete-facing remediation.

Monitor at cohort start and after days 1, 3, 7, and 14: build results, validation fallbacks, migration
events, crash/hang, support categories, adaptation rate/undo, self-coached mutations, and coarse funnel
health. Longer athlete-outcome review follows the prospective protocol, not a growth dashboard.

## 26. Executable work breakdown

Each work package ends in a reviewable change with its own fixtures. Do not combine schema migration,
policy behavior, and the purchase funnel into one release.

### WP0 — Truth and governance

**Work:** inventory active Health-import and ACWR/injury-prediction language; establish rule/evidence
registry format; assign science, clinical, product, privacy, and engineering owners; finalize supported
Release 1 populations and claim language.

**Deliverables:** doctrine audit, evidence registry v1, copy/claim inventory, advisory rubric, decision
log, and a test proving Health authorization/history creates no workouts.

**Exit:** Gate 0 in §13 and no contradictory active source-of-truth documentation.

**Status — 2026-09-01:** technical slice implemented. The doctrine/copy audit, registry format and
initial high-consequence entries, claim inventory, advisory rubric, decision log, Health zero-import
connection boundary, and focused fixtures live in
[`RUNNING-EVIDENCE-REGISTRY.md`](RUNNING-EVIDENCE-REGISTRY.md),
[`RUNNING-CLAIMS-INVENTORY.md`](RUNNING-CLAIMS-INVENTORY.md),
[`RUNNING-ADVISORY-RUBRIC.md`](RUNNING-ADVISORY-RUBRIC.md), and
[`RUNNING-DECISIONS.md`](RUNNING-DECISIONS.md). Human governance remains incomplete: the required
science, clinical, dietitian, statistics/privacy, product, and engineering roles do not yet have
recorded named owners. Do not label Gate 0 fully passed or claim expert approval until that register
is complete.

### WP1 — Semantic baseline and evaluator

**Work:** add semantic plan digest, invariant validator wrapper, current-output golden fixtures,
adversarial request generator, replay format, and classified plan diff.

**Likely files:** new `Momentum/Engines/Running/Evaluation/*`; fixtures/tests in
`MomentumTests/RunningPlanner*`; adapter around `PlanModels.swift`.

**Exit:** current planner passes the applicable invariants; known legacy exceptions are documented
rather than silently blessed. Shadow evaluator proves it cannot mutate the store.

**Status — 2026-09-01:** technical slice implemented. `PlanSemanticSnapshot` provides a versioned,
narrative-free SHA-256 digest; `PlanSemanticDiffer` classifies local-only changes; and
`LegacyPlanReplay` preserves the exact normalized request, calendar configuration, semantic catalog
order, and calibration inputs without athlete identity, raw Health, route, or unrestricted text.
Thirty-two named full-season baselines cover eight start/return, eight 5K/10K, eight half-marathon,
and eight marathon personas. The fixed seed `0x4D4F4D454E54554D` drives 10,000 supported road-running
requests through generation, digesting, and the invariant validator with zero hard violations.

The sweep found and fixed one defect in the production fallback: post-rounding load capping could
make a labeled deload equal to or larger than the preceding loading week. The correction is
reduction-only—it cannot add dose, intensity, sessions, or persistence writes—and did not change any
of the 32 locked baseline digests. The shadow API accepts and returns values only; store-isolation
coverage proves it inserts or deletes no `TrainingPlan`/`PlannedSession` rows and leaves sentinel
stored fields unchanged. Remaining model limitations are explicitly
listed in [`RUNNING-LEGACY-EXCEPTIONS.md`](RUNNING-LEGACY-EXCEPTIONS.md). This is software
qualification, not coach/clinical approval and not permission to make “elite-grade” or
“Olympic-level” claims.

### WP2 — Pure domain and legacy policy adapter

**Work:** implement evidence/state/request/season-value/intent/trace contracts, policy protocol,
registry lookup, and `LegacyRoadPolicyAdapter` without changing live generation.

**Exit:** legacy adapter matches semantic golden outputs, including name, goal race pace, rounded units,
strength support, completed carryover expectations, and self-coached behavior.

**Status — 2026-09-01:** technical slice implemented; production routing remains unchanged.
`RunningEvidence`, `RunningAthleteState`, `RunningSeason`, `PlanningRequest`, `SessionIntent`, and
`RunningDecisionTrace` are immutable, Sendable value contracts. Evidence carries provenance,
observation window, sample count, categorical confidence, and explicit limitations; Health signals
cannot represent completed training exposure. The policy protocol separates feasibility, block map,
weekly dose, session intent, and block-exit decisions. The compiled `legacy-road-rules-v1` registry
contains all 25 required rule IDs and fails validation for duplicate/missing IDs, invalid units or
bounds, missing source/owner/review/fixture metadata, invalid approval state, or trace references to
unknown rules.

`LegacyRoadPolicyAdapter` is a value-only Stage-B bridge around the shipping generator. Across all 32
reviewed personas it preserves the exact `GeneratedPlan`, semantic digest, goal-race pace, metric or
imperial rounding, runner-strength exercise order/prescription, and stable athlete plan name. It also
mirrors the shipping eight-week race/current-week completed-session carryover rule and protects a
self-coached plan from shadow or automatic replacement; only an explicit athlete request may build a
coached candidate. Because the temporary request contains both domain values and legacy values, the
adapter now fails closed when goal/event/date, availability, unit, equipment, intensity, volume, or
strength preferences disagree. Fixed-date/course demands and active restrictions return typed
conflicts instead of being silently ignored. Expert-sensitive numeric rules remain explicitly
`expertReviewRequired`, and known legacy limitations stay attached to the trace. No production file
calls this adapter; `PlanService` still calls `PlanEngine` directly. This is software equivalence and
contract qualification, not coach/clinical approval or permission to claim elite/Olympic coaching.

### WP3 — Schema V2 and safe persistence boundary

**Work:** run the version-scoped schema spike; add `RunningSeasonRecord`, `RunningEventRecord`,
`PlanMetadataRecord`, `PlannedSessionIntentRecord`, and `PlanDecisionRecord` sidecars; implement V2
migration, archived-store fixture, idempotent backfill/orphan cleanup, `PlanConfigurationCommand`, and
candidate-first atomic commit.

**Likely files:** `Momentum/Models/RunningSeason.swift`, `PlanDecisionRecord.swift`,
`PlanMetadataRecord.swift`, `PlannedSessionIntentRecord.swift`, `SchemaVersions.swift`, and a new
persistence adapter beside `PlanService.swift`. Do not change `UserProfile.swift`, `TrainingPlan.swift`,
or `PlannedSession` persistence shape unless the version-scoped migration path passes first.

Also update every explicit model registry/lifecycle: `PersistenceController.models`, in-memory test
containers, `DataManager` export/delete/account-switch paths and export schema version, `DemoSeed`
cleanup, previews, and orphan maintenance. Extend `DataManagementTests`, migration fixtures,
`CoachUndoTests`, `PlanRenewalTests`, and `SelfCoachedPlanTests` before live use.

**Exit:** all migration/persistence gates in §24 pass; production behavior is still legacy.

**Status — 2026-09-02:** technical slice implemented; production plan generation remains legacy.
Schema V2 adds the five scalar-ID sidecars without adding relationships into the released training
graph. A first migration attempt against a real build-36 store correctly failed with Core Data's
“unknown model version” error: concurrent optional navigation fields had changed the live
`AppNotification` type and therefore the supposed V1 checksum. `SchemaV1.AppNotification` now freezes
the exact released storage shape while V2 uses the live type. The checked-in immutable store was
exported by Momentum 1.6.0 build 36 at commit `8af1a7463a36eb9e356716ef4528168685a1136a`;
its provenance and SHA-256 live beside the fixture.

The archived-store test now proves exact IDs and counts for the profile, plan, completed session,
linked workout, GPS detail/samples, photo, Athlete Model/memory, and pre-field notification; nil
defaults for V2 notification fields; zero initial sidecars; rollback after an injected interrupted
backfill; close/reopen after migration and repair; a single deterministic backfill; and a second
no-op repair. A separate registry test requires every production model exactly once. Export, both
delete paths, DemoSeed cleanup, and schema-versioned JSON include the new records.

`PlanConfigurationCommand` is the one compatibility dual-write boundary for profile goal fields,
the live plan header, season, and events. It preserves non-primary events, archives superseded season
state, and clears backfill ownership after an explicit athlete edit. `PlanStore` builds and validates
the full candidate before mutation, rejects stale/shadow/unsupported input, preserves completed
session/workout identity through the old plan's cascade deletion, switches the profile directly to
the new plan, writes metadata/intents/a committed decision, saves exactly once, rolls back on injected
SQLite failure, and replays a request ID idempotently. It is intentionally not wired to live
generation before WP4–WP8 qualification; the legacy UI path immediately reconciles its sidecars.

Verification from one fresh `build-for-testing` binary on explicit iPhone 17 Pro Max simulator
`5DCE1B79-C938-4F4E-8A23-908E3497D05A`: 1,828 unit tests discovered, 1,827 passed, one non-critical
dynamic helper skipped, zero failures; all 12 focused persistence tests passed; and all three
Guest-entry/onboarding plus both plan create/adjust UI tests passed together. The attempted full
163-case UI target also exposed a pre-existing cross-process Health-sheet walker that could spend
hours probing absent elements; its action order is now fixed and the formerly wedged end-to-end walk
passes in 40.8 seconds under a 180-second budget. A clean release-wide UI target is still a later
Release 1 gate, not evidence of coach/clinical approval and not permission for elite/Olympic claims.

### WP4 — Road policies and ordered scheduler

**Work:** extract StartReturn, 5K10K, Half, and Marathon policies; implement ordered scheduling,
typed conflicts, dose envelopes, target hierarchy, final rounding/revalidation, structured trace, and
the shared phone/Watch `ExecutionPrescription` with version fallback.

**Exit:** 32 golden seasons and seeded property matrix pass; expert review build can show every rule
and relaxed preference. Policies remain shadow-only.

**Status — 2026-09-02:** engineering qualification implemented; policies remain shadow-only and
`PlanService` still uses the released generator. `RoadPolicyRouter` now selects explicit
Start/Return, 5K/10K, half-marathon, or marathon semantics and fails closed for unsupported surface
or distance. Each policy owns its block objectives, progression evidence, purpose copy, and target
hierarchy. Start/Return replaces faster work with effort-first run/walk until completed-training
continuity and acceptable easy-session response open the gate; Health recovery signals cannot open
that training-exposure gate.

`OrderedRunningScheduler` exhaustively compares hard-valid seven-day placements, then applies the
documented lexicographic order: explicit athlete days, training-supported adherence, existing-plan
continuity, recovery spacing, duration fit, and stable movement. Availability, fixed commitments,
active restrictions, terminal-event ordering, and no hard run the day after hard lower-body strength
produce typed conflicts instead of hidden compromises. Optional easy-dose removal ranks comparable
execution duration rather than mixing metres with seconds. Final sessions are snapped once in the
athlete's display unit and pass a second invariant gate before a candidate is returned.

The version-1 `ExecutionPrescription` is shared source between phone and Watch, validates typed
targets/steps before use, tolerates unknown JSON fields, and falls back to the exact legacy payload
for missing, malformed, unsupported, or invalid structured data. Phone sync sends the versioned
contract beside legacy keys during migration; Watch resolves it through one safe boundary. Every
shadow session must produce one valid prescription. The candidate exposes applied rules, hard
constraints, relaxed preferences, evidence limitations, adjustments, and legacy exceptions in a
structured trace; a reviewer UI and named human review remain WP8 work.

Verification from one rebuilt binary on explicit iPhone 17 Pro Max simulator
`5DCE1B79-C938-4F4E-8A23-908E3497D05A`: all 32 frozen golden seasons, the 512-seed scheduler matrix,
the 128-case full-season shadow matrix with 16 deterministic replays, and all execution fallback
tests pass. The full unit target discovered 1,849 tests: 1,848 passed, one non-critical dynamic helper
skipped, and zero failed. This is deterministic software qualification—not sport-science, clinical,
pilot, or elite/Olympic approval—and it does not authorize production policy activation or marketing
claims.

### WP5 — RunningAthleteState v1

**Work:** build snapshot adapter from Momentum workouts, explicit entries, current `AthleteModel`, and
Health recovery signals; implement freshness/comparability/limitation logic; name the efficiency trend
honestly; remove planner dependence on predictive ACWR thresholds.

**Exit:** every state field changes a documented fixture or is removed; no Health workout history is
read; low-confidence/failure matrix passes.

### WP6 — Unified adaptation coordinator

**Work:** route `PlanCoaching`, `RecoveryAdaptation`, `EffortAdaptation`, pace review/recalibration,
missed work, injury response, and user-initiated replans through proposal/transaction interfaces while
preserving current UI behavior behind legacy mode.

**Exit:** priority, budget, safety override, atomicity, undo, bidirectional calibration, and no-churn
tests pass. Current independent timestamp fields remain mirrored until all readers migrate.

### WP7 — Goal-first funnel and premium reveal

**Work:** consolidate onboarding and Plan Settings around `PlanDraft`; implement required hierarchy,
confidence card, feasibility alternatives, semantic diff, in-memory preview, paywall boundary, failure
states, and accessibility.

**Exit:** plan name is first in create/adjust; cancel/paywall failure cannot change live plan; all UI,
snapshot, entitlement, and analytics privacy tests pass.

### WP8 — Shadow, expert review, and correction loop

**Work:** run candidate across fixtures and opted-in sanitized replays; classify disagreements; conduct
blind coach/clinical/dietitian review; version rules and repeat qualification.

**Exit:** §24 expert thresholds pass with no unresolved material safety issue; policy is approved only
for its stated population.

### WP9 — Athlete pilot and progressive release

**Work:** ethics/privacy/consent review, pilot protocol, support playbook, rollout policy/kill switch,
cohort monitoring, stop rules, and post-pilot decision.

**Exit:** prospective gate for that policy passes. If it does not, narrow scope, revise, or keep legacy;
do not relabel a failed gate as “learning” and ship broadly.

### WP10 — Performance, trail/ultra, and middle distance

These begin only from the validated substrate and remain separate programs with their own registries,
fixtures, coaches, pilots, and claims. They are not backlog items inside the road policy.

## 27. Red-team critique, locked decisions, and owner decisions

### What could still make this plan fail

**Complexity may outrun benefit.** A versioned athlete state, season, policies, intents, traces, and
transactions are only justified if they make better or safer decisions. The evaluator must compare
each new dimension against a simpler baseline. If removing a field does not change coach review,
calibration, stability, or athlete outcomes, remove it.

**Determinism can become rigid.** Reproducibility is necessary, but rules may still be wrong for an
individual. The solution is explicit uncertainty, athlete feedback, safe overrides, and versioned
policy review—not an LLM escape hatch or hidden randomness.

**Expert review can encode preference as science.** Coaches legitimately differ. Blind review,
multiple disciplines, documented disagreements, evidence labels, and narrow population claims prevent
one advisor's style from becoming universal truth. Expert consensus does not replace athlete data.

**Two sources of truth can diverge during migration.** `UserProfile` goal fields and the new season
must only be written through one command and continuously checked by an invariant. If dual-write drift
appears, pause new UI rollout; do not add more adapters.

**“Candidate-first” is not automatically atomic.** SwiftData save/relationship/cascade behavior must
be proven with failure-injection tests using a real store. Until it is, retain the current persistence
path and do not claim the old plan is protected.

**Local-only audit records limit remote support.** That is the correct privacy default. Support begins
with user-approved export; cloud sync requires a separate RLS design. Convenience does not justify
putting health-adjacent decision detail into product analytics.

**A longer funnel may reduce conversion.** Every question must change feasibility or the first two
weeks. Progressive disclosure and goal-derived defaults should keep the required path short. If a
field does not change a decision, remove it even if it makes the app look sophisticated.

**Performance athletes may reject the capture boundary.** Garmin/COROS/coach-platform athletes whose
training is not recorded or explicitly logged in Momentum will have low-confidence state. Keep this
limitation prominent. Revisit product positioning or a separate, explicitly approved ingestion model
rather than violating the Health-signals-only rule by stealth.

**Validation can be gamed.** Golden fixtures can overfit, coach scores can improve after revealing the
candidate, and pilot dropouts can disappear from results. Freeze holdout/adversarial cases, blind where
possible, pre-register pilot analysis, report missingness, and require rule version changes for fixes.

**Elite marketing can get ahead of evidence.** Product copy, App Store metadata, ads, onboarding, and
sales material all belong to the same claim inventory. Passing unit tests or hiring an elite coach
does not itself validate an Olympic-level system.

### Locked product/engineering decisions

- Running is the headline; strength and fueling support running.
- Numbers remain deterministic and unit-tested; AI narrates only.
- Health supplies signals from connection onward and never imports/creates workouts.
- SwiftData remains the local source of truth; plan creation/adaptation works offline.
- The plan name is the first field in create and adjust, survives every automatic rebuild within its
  season, and is never automatically blanked.
- Current plan remains live until a complete candidate validates and commits.
- Safety restrictions outrank performance, schedule, preference, and conversion.
- No injury probability, diagnosis, universal menstrual-phase plan, hidden goal inflation, or shame.
- Road core is validated before trail/ultra, middle distance, or public elite claims.

### Decisions that require named owners before they block

1. **Advisory group and conflicts** — Product owner names/compensates reviewers and discloses conflicts
   before WP4 expert review.
2. **Release 1 supported populations** — Product + science + clinical owners explicitly decide age
   floor and whether active return-from-injury is fully supported or only routed to a
   conservative/clinician-guided path before public copy is written. Youth and para/adaptive full
   support remain excluded until separately co-designed.
3. **Evidence registry authority** — One science owner approves rule sources and review cadence; one
   engineering owner approves implementation/fixtures before WP4.
4. **Automatic pace easing** — Science/product decide whether Release 1 only proposes easing or may
   automatically apply after repeated evidence; default is proposal + consent.
5. **Planner rollout control** — Engineering/security choose TestFlight/build cohorts first and a
   minimal cached allow-listed remote control before production cohort rollout.
6. **Season/decision cloud sync** — Privacy/backend decide whether this is needed. Default for Release 1
   is local-only.
7. **Weather/course data** — Product chooses a provider and privacy model before Release 2. Release 1
   uses known/manual environment bands and effort-first fallbacks.
8. **Prospective protocol** — Sport science/statistics, clinical, privacy, and product approve outcome,
   sample size, stopping rules, consent, and claims before recruiting athletes.
9. **Device/capture positioning** — Product decides how explicitly to market the Momentum-recorded
   evidence requirement to Garmin/COROS-first runners; Health workout import remains prohibited.
10. **Elite/Olympic claim authority** — Legal/product/advisory group define evidence needed for any
    future claim. Default is no such claim.

An owner decision is recorded with date, rationale, alternatives, affected rule/policy, and reversal
condition. Silence means the conservative default above, not permission to improvise.

## 28. Definition of done

A work package is not done when code compiles. It is done only when:

- Its scope, supported population, non-goals, and behavior are documented.
- Pure logic has unit/property fixtures and visible behavior has UI/accessibility verification.
- Old-store migration, offline, failure, cancel, and rollback paths are tested where relevant.
- Rule/evidence registry and athlete-facing copy are updated together.
- Privacy review covers persistence, analytics, Sentry, export, delete, and any sync.
- Plan/session numbers remain SI internally and final unit rounding is revalidated.
- Performance is measured on the oldest supported reference device and meets its budget.
- The full Swift Testing scheme passes from the exact build being released.
- Required coach/clinical/dietitian review is recorded and material disagreements are resolved.
- Analytics and support can identify planner/ruleset/policy without receiving sensitive plan data.
- Rollout flag, fallback, stop signals, and incident owner are live before athlete exposure.
- Documentation and marketing accurately describe what shipped—not the future roadmap.

Release 1 is complete only when road-core policies pass §§24–25, plan creation/adjustment meets §22,
the current plan can be safely migrated/rolled back, and prospective validation supports the specific
claims being made. The system can be excellent for beginners and competitive road runners at that
point. It is not yet proof of Olympic-level, ultra, or middle-distance coaching.

## 29. Documentation reconciliation checklist

Update documentation only when the corresponding implementation lands; do not rewrite history ahead
of the code. The implementation PR must search and reconcile:

- `docs/ENDURANCE-FOCUS.md`, then PRD Part II and `docs/EXECUTION-PLAN.md`.
- Active Health descriptions/comments/test names that imply workout import.
- ACWR “sweet spot,” danger-zone, injury-prediction, and learned-overreach language in UI, AI context,
  `AthleteModel`, nudges, tests, and planning docs.
- Plan data model, lifecycle, race completion, renewal, self-coached, undo, and sync/export docs.
- Onboarding/Plan Settings/paywall funnel steps and analytics views grouped by app build.
- Supported event distances, trail/50K language, Podium/performance-mode language, and public claims.
- Privacy policy/App Privacy answers if personal decision records ever leave the device.

For every reconciliation, preserve the historical decision in version control and state the effective
build/ruleset. A stale active document is a release defect because it can reintroduce behavior that the
shipping code deliberately removed.

## Market bar, not product truth

Current official product documentation shows the competitive baseline: Garmin adapts day-to-day from
performance and health metrics and supports 6–52-week plans; Runna markets plans from beginner through
elite and up to 50K; Stryd now offers power-based adaptive planning; TrainingPeaks offers season-level
periodization. Momentum should not try to win by checking the same boxes. It should win on honest goal
feasibility, auditable adaptation, runner-specific strength/fueling, calm execution, and a plan that
admits uncertainty.

- [Garmin running plans](https://support.garmin.com/en-US/?faq=IkvWNeIoSd48GIYCjkhlo7)
- [Runna training plans](https://www.runna.com/training/training-plans)
- [Stryd adaptive training](https://help.stryd.com/en/articles/12580285-stryd-adaptive-training-how-to)
- [TrainingPeaks annual plan
  methods](https://help.trainingpeaks.com/hc/en-us/articles/224662768-Annual-Training-Plan-Methodologies)
