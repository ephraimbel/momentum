# Momentum Running Claims Inventory

*Version 1.0 — 2026-09-01*

> This is the release allow-list for athlete-facing claims. It covers in-app UI, coach templates and
> LLM constraints, notifications, paywall, App Store metadata, ads, support, screenshots, and sales
> material. A claim is not allowed merely because a competitor makes it or a test passes.

## Claim classes

### Allowed now

- **Running-first adaptive plan:** numbers come from deterministic rules; changes are bounded,
  throttled, and explained.
- **Goal-first and personalized:** plan name, goal/event, current starting point, availability,
  experience, recent Momentum training, explicit benchmarks, response, and constraints affect the
  plan. “Personalized” must name at least one real input near the claim.
- **From beginner through competitive road running:** current product scope is first run/5K through
  competitive marathon, subject to the supported-population limits in the decision log. This is not
  an elite-performance validation claim.
- **Strength for runners and fueling support:** strength stays subordinate to running; Fuel uses
  floors and performance support, not dieting.
- **Recovery-aware:** Apple Health trends and check-ins can conservatively ease work. Copy must say
  signals are context and accumulate from the day of connection.
- **Offline-first workout capture:** Momentum workouts are locally durable and do not require an LLM
  or server for core coaching.
- **Honest goal feasibility:** the app may describe a target as supported, tight, or unsupported and
  offer alternatives. Estimates are ranges, not promises.
- **No-shame adaptation:** missed sessions move, reduce, substitute, or drop with a rationale; there is
  no red failed state.

### Allowed only with the qualifier shown

- **“Elite-quality”** may describe the internal standard for assessment, restraint, explanation, or
  craft only when immediately qualified as a target—not validated elite coaching.
- **“From your first 5K to your first ultra”** is positioning/vision. Until trail/ultra policy passes
  its own gates, product/paywall copy must say ultra support is later or omit the endpoint.
- **“Wearable signals supported”** means signals written to Apple Health when available and permitted.
  It never means direct Garmin/Oura/Whoop/COROS workout import.
- **“Mostly easy” / “80/20”** may describe a familiar reference. It cannot be presented as a
  universal optimal split or a target every week must hit.
- **“Readiness”** may name a product surface, but the band and explanation must say training/recovery
  context and confidence. It cannot clear or cancel training from one score.
- **“Can improve/support”** requires the relevant registry entry and population limitation. Do not
  shorten it to a guarantee in a headline.
- **Goal-time prediction** must be “estimate,” “range,” or “current projection,” with source and
  confidence. A goal time remains the athlete's goal when unsupported, not a forced training pace.
- **Weight-loss motivation** may be acknowledged only as a reason for building a consistent running
  routine. Momentum does not prescribe a deficit, date, amount, or guaranteed body change.

### Prohibited until a future recorded gate explicitly changes this file

- “Olympic-level plan,” “Olympic coach in your pocket,” “elite-validated,” “professional-team
  replacement,” or equivalent superiority claim.
- “Clinically validated,” “coach approved,” “dietitian approved,” or named-review claims before the
  exact ruleset/population and completed review are recorded.
- Injury prevention/reduction, injury probability, “safe plan,” “danger zone,” “sweet spot,”
  “bulletproof,” or “won't get hurt.”
- Diagnosis or treatment claims, including illness detection, overtraining diagnosis, REDs diagnosis,
  or identifying the cause of pain from chat/signals.
- “Cleared to train,” “safe to push,” “earned more,” “recovered,” or “ready for quality” based on a
  score, load ratio, or wearable reading.
- A universal 10% rule, ACWR safe band, fixed 80/20 optimum, universal 1% treadmill correction, or
  exact heat slowdown/acclimation promise.
- “Apple Health imports your workouts,” “your Garmin runs appear automatically,” or any history
  backfill promise.
- Guaranteed race outcome, guaranteed pace improvement, guaranteed body composition/weight loss, or
  a date on which the athlete will achieve the goal.
- “AI writes your training plan” when describing the numeric plan. AI narrates; deterministic engines
  compute.
- Full trail/ultra, middle-distance, youth, pregnancy/postpartum, para/adaptive, or clinician-free
  return-from-injury support before that separately governed policy passes.

## Surface audit

The Gate 0 audit covers these active sources:

- Onboarding, plan create/adjust, reveal, paywall, Today, Plan, Progress/Health, Fuel, Profile, Settings,
  notifications, and coach cards/chat.
- `CoachKnowledge`, `CoachResponder`, `ProgressNarrator`, AI context/prompt builders, metric explainers,
  App Store metadata, current positioning and execution docs.
- Persisted legacy names such as `overreachThresholdACWR` are allowed for store compatibility only;
  comments, DTOs, and displayed copy use neutral current meaning.

Resolved in v1:

- Health connection copy now says forward-only signals and no workout history import.
- Load surfaces say recent-to-usual context and remove injury/safe-band language.
- 80/20 is a reference rather than a universal target.
- Positive recovery signals no longer say “cleared to train”; recovery bands use strain/context copy.
- Prior injury history is described as a conservative modifier, not a safer-plan guarantee.
- Coach knowledge removes causal pain diagnosis, injury-prevention promises, universal treadmill/heat
  corrections, and single-signal recovery prescriptions.
- The ACWR publication identifier is corrected to PMID 32502973.

Open review items are not approved claims:

- Every event-specific fueling dose needs sports-dietitian review.
- The 0–100 Morning Readiness formula needs sport-science/clinical review and prospective calibration;
  current use is a low-confidence context index.
- Race prediction and time-to-goal calibration need prospective error reporting by runner/event group.
- Area-specific prior-injury substitutions need clinical review.
- Public “coach-grade” wording waits for blind expert review; “Olympic-level” waits for the full
  validation and legal/product decision.

## Release check

Before a release that changes running logic or copy:

1. Search active code/docs/metadata for the prohibited concepts above, including synonyms rather than
   a single exact-string list.
2. Exercise templated/offline coach outputs for good, missing, and concerning signals.
3. Verify LLM system instructions prohibit changing numbers/verdicts and prohibit medical/clearance
   claims; test the deterministic fallback independently.
4. Match every numerical/categorical claim to a current registry entry and fixture.
5. Review paywall and ad variants separately; conversion copy gets no weaker evidence standard.
6. Record the ruleset/build, reviewer, decision, and rollback condition in the decision log.

Any contradiction blocks the release. Historical docs may retain old language only behind a clear
superseded banner and cannot be linked as current product truth.
