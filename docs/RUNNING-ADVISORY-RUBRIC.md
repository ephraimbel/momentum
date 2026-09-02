# Momentum Running Advisory and Review Rubric

*Version 1.0 — 2026-09-01*

> This rubric defines who may approve training claims and how review is conducted. Creating the
> rubric is not expert approval. Named reviewers, qualifications, conflicts, scores, and resolutions
> must be recorded before a candidate policy reaches athletes.

## Required review group

- **Sport-science authority:** postgraduate training in sport/exercise physiology or biomechanics,
  demonstrated research-methods competence, and direct distance-running application. Owns evidence
  classification, population transfer, uncertainty, and review cadence.
- **Independent running coaches (minimum two per policy):** documented experience coaching the exact
  supported event/population. Across the panel, include beginner/return, recreational road, and
  competitive road expertise; marathon review requires marathon experience. A famous athlete without
  coaching/evidence competence does not satisfy this role.
- **Clinical authority:** currently licensed sports-medicine physician or physical therapist with
  running/return-to-sport practice. Owns symptom boundaries, escalation, and return restrictions—not
  performance programming outside their competence.
- **Sports dietitian:** registered dietitian with endurance-sport competence; a CSSD or relevant local
  equivalent is preferred. Owns fueling ranges, contraindication/escalation copy, and the boundary
  between general education and individual medical nutrition therapy.
- **Statistics/validation authority:** study-design and calibration expertise independent from growth.
  Owns prospective protocol, missing-data handling, subgroup reporting, and claim strength.
- **Privacy/legal authority:** owns consent, sensitive-data flow, public claim substantiation, and the
  boundary between product analytics and research.
- **Product owner:** owns supported population and UX trade-offs but cannot overrule a material
  clinical/safety objection.
- **Engineering owner:** owns deterministic implementation, fixtures, traceability, migration,
  rollback, and proof that reviewed behavior equals shipped behavior.

One person may cover two roles only when qualified for both; sport-science and independent coach
review cannot collapse to one opinion. Growth/marketing cannot own a safety, evidence, or restart
decision.

## Qualification and conflict record

Before seeing candidate output, every reviewer records:

- Name, role, current credentials/licensure and jurisdiction where relevant.
- Event/population experience, recent practice/research, and limits of competence.
- Compensation and any financial relationship with Momentum, competitors, coaching platforms,
  wearable companies, supplement brands, shoe brands, or cited authors/products.
- Personal coaching philosophy that could materially bias volume, intensity, strength, fueling, or
  return decisions.
- Whether they helped author the candidate rules. Authors may explain a rule but do not count as both
  independent reviewers.

A conflict does not automatically exclude a reviewer; it must be disclosed, and an unconflicted
reviewer must cover the same domain. Undisclosed material conflict invalidates that review round.

## Review packet

Use frozen, versioned packets. Each includes:

- Supported population and explicit exclusions.
- Athlete evidence with source, freshness, limitations, and confidence.
- Goal, availability, constraints, complete season, and exact execution prescriptions.
- Feasibility verdict and alternatives.
- Rule trace, relaxed preferences, fallback, and plan-adjustment scenarios.
- Legacy/candidate outputs in randomized order when blinding is possible.
- No growth metrics, conversion result, brand preference, or indication of which plan engineering
  wants to win.

At least 32 canonical road seasons are reviewed as specified in
[`ELITE-RUNNING-SYSTEM.md`](ELITE-RUNNING-SYSTEM.md#241-canonical-fixture-matrix), plus a frozen holdout
set and adversarial cases. Reviewers do not see aggregate peer scores before submitting their own.

## Five-point scoring anchors

Each dimension is scored from 1 to 5 and receives a short rationale plus implicated rule IDs:

- **1 — unacceptable:** material harm, infeasibility, or fundamental mismatch; cannot ship.
- **2 — major revision:** important dose/logic problem that copy cannot repair.
- **3 — acceptable with revision:** no immediate material objection, but a meaningful limitation or
  inconsistency must be resolved or the population narrowed.
- **4 — strong:** appropriate and explainable for the stated athlete with only minor improvements.
- **5 — exemplary:** unusually clear, restrained, specific, and robust; not a claim of outcome proof.

Required dimensions:

- Stimulus appropriateness and event specificity.
- Weekly/session dose and progression.
- Recovery spacing, cutback, taper, and post-race behavior.
- Goal feasibility and target calibration.
- Beginner/return restraint and clarity.
- Competitive-runner depth without unnecessary complexity.
- Strength sequencing and interference management.
- Fueling integration for relevant durations.
- Adaptation priority, stability, and reversibility.
- Injury/illness boundary and professional escalation.
- Explanation, uncertainty, and fallback quality.
- Execution equivalence across plan detail, phone, and Watch.

Reviewers separately flag `material safety`, `material feasibility`, `population mismatch`, `copy`,
`implementation`, or `preference disagreement`. A 5 in another dimension cannot average away a
material flag.

## Pass and disagreement rules

A policy/ruleset passes expert review only when:

- Median score is at least 4/5 in every required dimension.
- No safety or feasibility score is below 3.
- No unresolved material safety, clinical, privacy, or data-loss objection remains.
- Every scored behavior maps to the reviewed ruleset and passing fixtures.
- Material disagreement is resolved by a rule change, a wider uncertainty/fallback, or a narrower
  supported population—not by polishing copy around the same dose.

The product gate is not evidence of efficacy. It permits a controlled usability/decision pilot only.
Outcome language still requires a pre-registered prospective protocol and results.

## Clinical and fueling stop authority

- The clinical authority can stop injury/return rollout and defines what evidence is required to
  restart. Product/growth cannot waive the stop.
- The sports dietitian can block a dose/range or require an individual-care boundary. Removing the
  word “medical” while retaining an unsuitable prescription is not a resolution.
- Any plan-attributable serious safety concern, repeated hard-invariant escape, plan/workout loss, or
  systematic intent mismatch pauses the affected ruleset/cohort.

## Review record and expiry

The decision log stores packet/ruleset/build, reviewer identity, scores, flags, disagreements,
resolution, approval scope, date, next review, and reversal condition. Review expires on a material
rule/population change or the entry's review date, whichever comes first.

Named human assignments are currently outstanding. Until recorded, Momentum may continue engineering
and internal fixture work, but it cannot claim expert approval or pass WP0's human-governance exit.
