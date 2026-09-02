# Momentum Running Decision Log

*Append-only governance log — created 2026-09-01*

> A decision records product truth; it does not erase history. Amendments add a new entry referencing
> the prior ID. Every entry includes the date, status, accountable role, rationale, alternatives,
> affected rules/policies, and reversal condition. A role assignment is not a named human.

## Owner register

The following accountable roles are required before the indicated gate. Named humans are deliberately
not invented in code review and remain `TBD`:

- Product owner — named human TBD; required to close WP0.
- Sport-science authority — named human TBD; required before WP4 expert review.
- Clinical authority — named licensed human TBD; required before injury/return expert review.
- Sports-dietitian authority — named human TBD; required before marathon fueling qualification.
- Statistics/validation authority — named human TBD; required before athlete recruitment.
- Privacy/legal authority — named human TBD; required before research data or public efficacy claims.
- Running-engine engineering owner — named human TBD; required before WP2 registry qualification.

Until a name/date is recorded, the conservative defaults below stand and no approval claim may be
made. Engineering may build fixtures and shadow-only code; affected policies may not enter an athlete
pilot.

## Decisions

### RUN-DEC-001 — Running-first scope

- **Date/status:** 2026-09-01; locked product doctrine (reconfirms 2026-07 pivot).
- **Accountable roles:** product, engineering.
- **Decision:** running is the headline. Strength and Fuel support running. Release 1 policy work is
  road start/return, 5K/10K, half marathon, marathon, and general running fitness.
- **Rationale:** focus the assessment, plan engine, execution, adaptation, and product story on one
  athlete problem before extending event families.
- **Alternatives rejected:** one generic multi-sport/any-distance policy; stretching marathon logic
  into trail/ultra or shrinking it into 800 m logic.
- **Affected:** all RUN rules; `StartReturn`, road policies, funnel and paywall claims.
- **Reversal:** a separately governed family passes its own registry, fixtures, expert review, pilot,
  and claim gate.

### RUN-DEC-002 — Apple Health signals-only boundary

- **Date/status:** 2026-08-15; locked owner decision, reconciled 2026-09-01.
- **Accountable roles:** product, privacy, HealthKit engineering.
- **Decision:** Apple Health supplies permitted signals from connection onward and never imports or
  creates Momentum workouts. Workout time windows may only prevent incidental-activity double count.
  Completed Momentum workouts may write outward with permission.
- **Rationale:** preserve an intentional, usable journal and prevent mirrored/duplicated workout
  explosions.
- **Alternative rejected:** broad Health workout/history import.
- **Affected:** RUN-HEALTH-BOUNDARY-001, onboarding, Settings, baselines, sync and tests.
- **Reversal:** none through ordinary feature work. Any new ingestion model requires an explicit owner,
  privacy, migration, dedupe, scale, and product-positioning decision; it cannot regrow through
  `HealthService`.

### RUN-DEC-003 — Load ratios are context, not injury science

- **Date/status:** 2026-09-01; active.
- **Accountable roles:** sport science (approval pending), product, engineering.
- **Decision:** recent-to-usual load ratios may describe exposure change and bound an internal
  generator guardrail. They do not predict injury, establish a safe zone, clear training, or alone
  authorize automatic structural mutation.
- **Rationale:** the causal and statistical limitations do not support the older injury/sweet-spot
  language. The app can preserve useful context without false precision.
- **Alternatives rejected:** public ACWR target bands; deleting all weekly load context before a
  simpler trend replacement exists.
- **Affected:** RUN-LOAD-CONTEXT-001, RUN-LOAD-GOVERNOR-001, RUN-LOAD-ADAPT-001.
- **Reversal:** only a new evidence/implementation review can change the role; no remote threshold
  tuning.

### RUN-DEC-004 — Positive recovery signals never clear training

- **Date/status:** 2026-09-01; active provisional recovery doctrine.
- **Accountable roles:** sport science and clinical approval pending; engineering.
- **Decision:** wearable/check-in scores are context with visible confidence. One bad signal does not
  lurch the plan; positive-looking signals never authorize added dose or override athlete symptoms.
- **Rationale:** consumer signals are noisy and metric-specific. Conservative agreement can justify a
  reduction; absence of a warning is not proof of readiness.
- **Alternatives rejected:** “green means go,” one-number clearance, illness diagnosis.
- **Affected:** RUN-RECOVERY-001, Today/Health/coach copy.
- **Reversal:** after expert review and prospective calibration of a specific population and claim.

### RUN-DEC-005 — Plan identity starts with the athlete's name

- **Date/status:** 2026-09-01; locked UX/product decision.
- **Accountable roles:** product, iOS engineering.
- **Decision:** plan name is the first field in create and adjust, remains at the top, persists through
  automatic rebuilds inside the season, and is never automatically blanked after a race.
- **Rationale:** the goal/season is the organizing object the athlete is buying and pursuing, not a
  configuration footnote.
- **Alternative rejected:** name at the bottom or auto-generated name replacing athlete intent.
- **Affected:** `PlanSettingsSheet`, future `PlanDraft`, season model, WP7 UI tests.
- **Reversal:** explicit owner decision plus usability evidence; migration must preserve existing names.

### RUN-DEC-006 — Release 1 population default

- **Date/status:** 2026-09-01; conservative default pending named product/science/clinical approval.
- **Accountable roles:** product, sport science, clinical.
- **Decision:** public Release 1 support is limited to adults (18+) pursuing road running from
  start/return through marathon/general fitness. Active return-from-injury is conservative and
  clinician-guided rather than a claim of fully automated support. Youth, pregnancy/postpartum,
  para/adaptive full support, trail/ultra, and middle distance remain separately governed.
- **Rationale:** avoid transferring adult road rules into populations/event demands not yet designed
  or validated.
- **Alternatives rejected:** “any runner” as an unqualified shipping claim.
- **Affected:** all policy selection and public claims.
- **Reversal:** co-design, registry, accessibility/clinical review, fixtures, expert qualification,
  and pilot for the added population.

### RUN-DEC-007 — Automatic pace easing requires consent in Release 1

- **Date/status:** 2026-09-01; conservative default.
- **Accountable roles:** product and sport science approval pending; engineering.
- **Decision:** repeated comparable evidence may produce an easing proposal; the athlete confirms it.
  Acute protective same-day/session reductions remain separate. One poor race never automatically
  demotes fitness.
- **Rationale:** environmental, tactical, health, and measurement limitations make one result
  ambiguous; transparent consent prevents silent plan drift.
- **Alternative rejected:** fully automatic bidirectional recalibration in the first road release.
- **Affected:** calibration/adaptation WP5–WP6 and RUN-FEASIBILITY-001.
- **Reversal:** blind expert review plus replay/pilot evidence shows an automatic rule is stable and
  better understood.

### RUN-DEC-008 — Decision records remain local by default

- **Date/status:** 2026-09-01; privacy default.
- **Accountable roles:** privacy/backend decision pending; engineering.
- **Decision:** detailed plan decision/audit records stay local, participate in export/delete, and do
  not enter product analytics. Shadow mode writes no athlete plan/health values.
- **Rationale:** reproducibility does not require centralizing health-adjacent personal decisions.
- **Alternative rejected:** automatic cloud analytics upload of structured traces.
- **Affected:** WP3 persistence, WP8 shadow, analytics allow-list.
- **Reversal:** separately reviewed owner-only RLS/sync, consent, retention, export/delete, and threat
  model.

### RUN-DEC-009 — No Olympic/elite validation claim

- **Date/status:** 2026-09-01; locked until validation gates pass.
- **Accountable roles:** legal/product/advisory group; named humans pending.
- **Decision:** Momentum does not claim Olympic-level, elite-validated, clinically validated, or a
  replacement for a professional performance team. Beginner-to-competitive engineering support is
  distinct from validated athlete outcomes.
- **Rationale:** finite pace math and unit tests do not establish appropriate season design, dose,
  adaptation, or efficacy for elite athletes.
- **Alternative rejected:** using an advisor's reputation or competitor marketing as substantiation.
- **Affected:** RUNNING-CLAIMS-INVENTORY, paywall, App Store, ads, support.
- **Reversal:** named legal/product/advisory authority defines the exact claim; relevant policy passes
  expert review and prospective validation in that population; the claim is added to the allow-list.

## Pending decisions

These remain blocked on named owners; the conservative default in the corresponding decision applies:

- Reviewer names, compensation, and conflict disclosures.
- Exact public Release 1 population wording and clinical return boundary.
- Evidence-registry science approver and engineering approver.
- TestFlight/build cohort control and kill-switch ownership.
- Weather/course provider and privacy model for later policies.
- Prospective study design, consent, sample size, stop rules, and claim threshold.
- Device/capture positioning for Garmin/COROS-first athletes without violating Health doctrine.

To close WP0, replace each required `TBD` with a consenting named human, date, scope, and conflict
record. Until then, Gate 0 is technically implemented but human-governance incomplete.
