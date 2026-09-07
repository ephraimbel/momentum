# Plan lifecycle, plan creation, plan management, and photo food logging

> Working document for the 2026-09 upgrade. Owner brief: creating, previewing, scheduling and
> switching plans should feel complete; adjusting training should be discoverable in Plan; the
> athlete should be able to photograph food, review an estimate and save a meal; Fuel should read as
> a polished daily tracker connected to running. Runna's plan organisation and Cal AI's logging
> ease are the references for STRUCTURE, never for copy, assets or screens. Keep this file current
> as the stages land; it is the hand-off across context resets.

Baseline at the start of the work: branch `feat/route-suggestion` at `ff1574e` (build 43 of 1.7.5),
clean tree, `build-for-testing` green, **2,104 unit tests in 238 suites passing** on a throwaway
iPhone 17 Pro simulator (UDID `270A0742-E41B-451B-B7D0-415248F2E706`, iOS 26.2). Codex's Sentry and
storage-recovery hardening (`a66d85a`) is in place and is not touched by this work. The native
Mapbox/Meta hang investigation stays open and unverified; nothing here claims it solved.

---

## 1. Findings (capability inventory, verified in the checkout)

### 1.1 Plan lifecycle

**Already implemented and usable**
- One deterministic generator (`PlanEngine.generate`, pure) fed by `PlanInputs`, which
  `PlanService.planInputs(from:startDate:)` builds from the profile. Goals: race, endurance,
  stay consistent, general fitness, leaner, build muscle, stronger. The structural fork is
  `raceDate != nil` (season to race day) vs open-ended six-week rolling blocks with a checkpoint.
- Honest feasibility (`PlanFeasibility.assess` → onTrack / tight / tooShort / noRace with
  `options` when too short), recommended days, intensity tiers.
- Adjustment through one surface: `PlanSettingsSheet` (`.adjust` buffers edits and rebuilds only on
  structural change, `.create` starts a new season). Coach actions (`CoachActions`, 24 intents)
  with preview lines, one-step `CoachUndo`, and the `lastAdaptedAt` one-structural-change-a-week
  latch shared by every adapter. Board-level edits: drag to move or swap, away days
  (`PlanWeekEdit`), push or pull the week, add a session, workout library, self-coached mode.
- Recovery and injury loops (`RecoveryAdaptation`, `InjuryResponse`), race projections and
  briefings, post-race continuation (`PlanService.completeRace`) and block renewal
  (`PlanService.renewBlock`), block reports.
- Replacement discipline: every rebuild goes through `PlanService.transactReplacement` (autosave
  off, one save, rollback on throw), clones this week's completed sessions onto the new plan and
  re-points the workout links, then deletes the old plan. `RunningPlanBackfill.repair` asserts plan
  and session id uniqueness on every launch.

**Implemented but hard to discover**
- "Adjust this plan", "Start a new plan", "Plan it myself", away days and week shifts all live
  behind the small slider glyph in the Plan masthead. Coach chat holds the missed-week, pause,
  injury and ease flows. Nothing on the Plan tab is organised by intent.

**Partially implemented**
- `PlanStore.commit` (idempotent, snapshot-checked, self-coached-protected) exists and is fully
  tested but production never calls it. The running-domain season sidecars carry a
  `draft | active | complete | archived` status, but only for the season, never for a plan the
  athlete can see.

**Missing**
- Any notion of more than one plan. The current plan is exactly `UserProfile.plan` (to-one,
  cascade delete). There is no draft, upcoming, completed or incomplete plan; no preview before
  activation; no scheduling; no way back to a previous plan. There is no `@Query<TrainingPlan>`
  anywhere, which is what makes the design below safe.
- A creation flow for an existing user that does not re-enter everything: `PlanSettingsSheet`
  in `.create` mode is one long form with no preview and it activates immediately.

**Invariants and traps that shape the design**
- `TrainingPlan`, `PlannedSession`, `UserProfile` are released shapes frozen by
  `SchemaVersions.swift`; `RunningSchemaMigrationSpikeTests` opens an archived build-36 store to
  prove it. New per-plan data must be a scalar-keyed sidecar `@Model` under a new schema version
  with a lightweight stage (`PlanAthleteStateRecord` in V3 is the pattern). No property may be
  added to a released model.
- Completed sessions before the current calendar week are dropped from the plan on every rebuild
  (`PlanService.stagePersist`); the `Workout` rows are never touched. Workout history therefore
  survives any switch by construction; only the plan's own ledger of finished sessions moves.
- Plans are local only. `SyncService` pushes workouts, never plans; the Watch and widgets read the
  current plan through `PhoneWatchSync.push` and `WidgetBridge.publish`; notifications through
  `NotificationService.schedulePlannedReminders`. Plan Settings and the renewal card do not call
  those today and rely on the next Today bootstrap.
- `TodayView.bootstrapIfNeeded` (throttled, synchronous half) is the one place the app settles the
  plan against the calendar (`settleRaces`, `reconcileMissed`). It is the natural home for
  "an upcoming plan reached its start date".

### 1.2 Fuel and meal logging

**Already implemented and usable**
- `Meal` model with itemised `MealItem` blob, precise `nutritionData`, `source` tri-state
  (`pending | ai | manual`), `estimateAttempts` retry cap, health-score fields.
- The three-rung resolution ladder (history → staples → AI), dictation, barcode lane
  (`BarcodeScanView` → Open Food Facts → `BarcodeFood`), manual entry, daily totals, hydration,
  history with CSV export, `FuelGoalsSheet`, the nutrition report.
- `FuelEstimator` (text → `meal-estimate` Edge Function), `EstimateGate` (one bill per meal across
  the composer and Siri), `MealNutritionStore` (rollback on failed writes), attempt accounting that
  refunds calls that never left the device, a persisted 429 latch.
- Manual precedence is structural: `FuelEstimator.apply` refuses a manual meal, `Meal.isEstimable`
  refuses to fire for one, and `MealDetailSheet.save` flips to manual on any number change.
- Late-response safety: tasks are retained per meal id and cancelled on delete; the write is
  guarded on `!isDeleted && modelContext != nil` and on the gate token still owning the meal.
- Deterministic fueling: `FuelReadiness` (energy floor = 30 kcal/kg + the day's real burn, carbs by
  session tier, protein 1.4 g/kg, sodium and fluids floors), `FuelWeek`, `FuelTrends`,
  `HealthScore`, `PostWorkoutFuelCue`, `FuelTips`.

**Implemented but dormant**
- `Meal.photoData` (`@Attribute(.externalStorage)`) has been in every schema since V1 and is
  written nowhere. `CameraPicker` (system camera) and `ImageDownsampler.thumbnail` (ImageIO
  thumbnailing with an NSCache) exist for Social. `NSCameraUsageDescription` already names food.

**Missing**
- Any photo path: no capture entry in Fuel, no image field in the request, no vision content in
  either provider call, no server-side validation of the model's answer, no thumbnail rendering in
  the journal. The docs (`FUEL-FLOW.md`, the function header, `FuelEstimator`) record photo
  estimation as a deliberate 2026-07-16 removal. The owner's brief reopens it with explicit
  constraints (visibly approximate, quick correction, no confident non-food entries).
- Date navigation on the Fuel dashboard (today only; History is the only way back).
- Server-side response validation and structured logging in `meal-estimate`.

---

## 2. Product flows

### 2.1 Your plans (Plan tab → masthead menu → "Your plans"; also the empty state)
- **Current**: goal or race, dates, week N of M, sessions this week, progress bar. Actions: Manage
  plan, Preview.
- **Upcoming**: starts on a date; dates, duration, frequency; "Starts in N days". Actions: Edit,
  Preview, Move to drafts, Start now.
- **Drafts**: never auto-start. Actions: Edit, Preview, Schedule, Start now, Delete.
- **Previous** (completed, incomplete): what it was, when, how much was done. Actions: Preview,
  Start again (copies the blueprint into a new draft).
- The primary Plan screen stays the current training week. Your plans is one tap away and never a
  new tab.

### 2.2 Create a plan (Your plans → Create plan; empty state → Build my plan)
Goal → date/distance/time → fitness and experience → availability → preferences → feasibility and
preview → save draft / schedule / start now. Every step opens on the athlete's known values.
Preview is computed off the main actor from the same generator the activation will use, cancelled
on any input change, and never touches the current plan.

### 2.3 Manage plan (Plan masthead → "Manage plan")
Four intents: My schedule · My training · Something changed · My goal. Each action shows what was
asked, the affected dates, before/after, one explanation, the feasibility effect, Apply / Cancel and
Undo where the existing `CoachUndo` supports it. Actions reuse `CoachActions` and `PlanCoaching`.

### 2.4 Photo food logging (Fuel composer → camera glyph → Take a photo / Choose a photo)
Capture → durable local draft (`Meal` with `photoData`, `source = pending`) → estimate → itemised
result with steppers → confirm. Offline drafts retry on appear through the existing bounded cap.

### 2.5 Fuel dashboard
Date strip → energy → carbs / protein / fat → training context line → Add food → meals with
photos → recents. Floors never ceilings, no over-budget state, unlogged never reads as zero.

---

## 3. Technical approach

### 3.1 Plan lifecycle storage: one current `TrainingPlan`, everything else on the shelf
The invariant every engine and test already assumes, "exactly one `TrainingPlan` row, reachable
only through `profile.plan`", is kept. Non-current plans do not exist as `TrainingPlan` rows.

New sidecar `PlanShelfRecord` (SchemaV5, lightweight stage; scalar keys, no relationships):
`id`, `profileID`, `statusRaw` (`draft | upcoming | completed | incomplete`), `name`, `createdAt`,
`updatedAt`, `scheduledStart`, `startedAt`, `endedAt`, `blueprintData`, `previewData`,
`snapshotData`, `sourcePlanID`, `version`.

- **Blueprint** (`PlanBlueprint`, Codable value type): everything the generator reads that belongs
  to the plan rather than the athlete's body: name, goal, race distance/date/goal time, days,
  preferred weekdays, session minutes, equipment, intensity, weekly ceiling, hybrid priority,
  strength split, declared weekly volume and longest run, experience. `PlanBlueprint(profile:)`
  reads the profile; `apply(to:)` writes it; `inputs(for:startDate:)` produces `PlanInputs`
  without mutating anything (the same mapping as `PlanService.planInputs`).
- **Preview** (`PlanPreview`, pure): built from a `GeneratedPlan` + inputs + feasibility: weeks,
  dates, runs and lifts per week, typical week, weekly time, peak week, longest run, phases,
  outlook. Cached on the record as `previewData` for the cards; recomputed on edit.
- **Previous plans** carry `snapshotData` in the `CoachUndo.Snapshot.PlanState` format (existing,
  tested encoder) so a completed or incomplete plan can be reviewed read-only with its sessions and
  completed-workout ids; the `Workout` rows stay in History untouched.

### 3.2 Lifecycle rules (`PlanLifecycle`, pure, tested)
- At most one current plan: `profile.plan`. A draft never activates on its own; only
  `PlanLifecycleService.activate` changes `profile.plan`, and only the Today bootstrap and the Plan
  tab call `activateDueUpcoming`.
- An upcoming plan whose `scheduledStart` is today or earlier activates on the next settle. It
  starts TODAY (the plan opens with a run the athlete can do today), the current plan is retired as
  `completed` when its own end date has passed, else `incomplete`, and the record is deleted in the
  same transaction as the swap, so a second launch, a retry, or a second sweep finds nothing due.
  Two due at once: the earliest scheduled start wins, the others return to drafts with a notice.
- Overlap: scheduling or starting a plan while the current plan still has open weeks after the
  proposed start asks for a decision, showing the current plan's name, its end date, how many weeks
  and sessions would be cut, and whether the goal race is cut. Choices: replace from that date,
  start after the current plan ends (a computed date), or keep it as a draft. Nothing is discarded
  silently; the retired plan lands in Previous.
- Rebuilds that are adjustments (Adjust this plan, coach changeDays, injuries, renewals) never
  shelve a copy. Shelving happens at explicit switch, at race completion, and at block renewal.

### 3.3 Activation transaction (`PlanLifecycleService.activate`)
Autosave off → snapshot the current plan into a shelf record (status by end date) →
`blueprint.apply(to: profile)` → `PlanConfigurationCommand.legacyUICommand(startsNewSeason: true)`
→ `PlanService.stageRebuild(startDate: today)` → `configuration.apply` →
`RunningPlanBackfill.prepareAfterLegacyPlanMutation` → delete the activated record → one save,
rollback on throw. After the save: `schedulePlannedReminders`, `WidgetBridge.publish`,
`PhoneWatchSync.scheduleRefresh`, an inbox notice routed to the plan.

### 3.4 Photo food logging
- Client: `MealPhoto` (pure: downsample to ≤1280 px, JPEG ≈0.72, strip everything but pixels by
  re-encoding through CGImage; never copies EXIF), `FuelEstimator.estimate(text:imageJPEG:…)` adds
  an `image` field (`{ mime, base64 }`) to the same request; text-only requests are unchanged.
  Capture entry in the composer (camera glyph → menu: Take a photo / Choose a photo), the draft row
  shows the thumbnail through `ImageDownsampler.thumbnail` (cached, never full resolution in the
  list), the detail sheet shows the photo above the items.
- Idempotency and late responses: the meal row is created once and every retry re-estimates that
  row (no second insert); `EstimateGate` tokens and the `isDeleted` guards already stop a late
  response from touching a deleted meal. A non-food or empty answer sets the meal to a plain
  "couldn't read this as a meal" line with the cap exhausted, so it never renders as confident
  nutrition and never re-bills on every visit.
- Retention: the photo lives only in the meal's external-storage blob; deleting the meal deletes
  the photo. Nothing is uploaded to Storage; the image rides the request body and is not logged.
- Server: `meal-estimate` accepts an optional `image` (validated: JPEG/PNG/WEBP, ≤ 4 MB decoded
  base64, ownership by the authenticated caller through the existing rate-limit RPC key), passes it
  as a vision content part to Gemini (`inline_data`) or Claude (`image` block), and now VALIDATES
  the model's answer server-side: item count ≤ 40, finite non-negative numbers within bounds,
  unknown micros preserved as null, `not_food` reason when nothing edible was recognised. Logging
  is structured, counts and provider only, never text or image bytes.

### 3.5 Fuel dashboard
`FuelView` grows a compact date strip (today ± history) and a redesigned top: energy hero with the
floor, three macro bars (carbs / protein / fat), the training context line, an "Add food" pill with
a menu (photo, barcode, describe, manual), meals with thumbnails, and recents. `FuelReadiness` is
unchanged; the readout for a past day is the same engine run over that day's meals and workouts.

---

## 4. Staged checklist

### Stage 1 — Plan home and lifecycle (landed)
- [x] Audit and this document.
- [x] `PlanShelfRecord` (SchemaV5 + lightweight stage), registry test, reset-store and wipe paths.
- [x] `PlanBlueprint`, `PlanPreview`, `PlanLifecycle` (pure) + `PlanLifecycleTests` (20 tests).
- [x] `PlanLifecycleService` (shelf CRUD, schedule/unschedule, activate, activateDueUpcoming,
      retire on race completion and renewal) + SwiftData tests.
- [x] Today bootstrap and Plan tab call `activateDueUpcoming`; activation propagates to
      reminders, the widget, the wrist and the inbox.
- [x] `YourPlansView` with cards and actions; masthead menu entry "Your plans"; empty-state entry.
- [x] Overlap decision sheet (`PlanOverlapSheet`) and the schedule picker (`PlanScheduleSheet`).
- [x] `--seed-plan-shelf`, `--plan-your-plans` recipes.

### Stage 2 — Plan creation and preview (landed)
- [x] `PlanBuilderFlow` (goal → target → where you are → your week → how to train → preview →
      start now / schedule / save draft). Four doors the engine tells apart: race (dated),
      get faster at a distance (rolling blocks shaped for it, checkpoint), start or return
      (stay consistent, gentle), build running fitness (general or farther and faster).
- [x] `PlanReviewView` + `PlanPreviewContent` (outlook, commitment, typical week, phases).
- [x] Debounced (350 ms), token-cancelled preview generation in a task; the preview is the real
      generator run on the blueprint. It runs on the main actor over already-fetched rows
      (engine work of milliseconds); a `@ModelActor` worker was not worth a second context.
- [x] Draft and upcoming edits reopen the builder on the record's blueprint. `--plan-builder`.

### Stage 3 — Manage plan (landed)
- [x] `ManagePlanView` (My schedule · My training · Something changed · My goal), backed by
      `PlanAdjustmentService` over `CoachActions` and `PlanCoaching`; `PlanAdjustmentServiceTests` (7).
- [x] `PlanProposalSheet`: request, what it touches, before/after (computed from the same
      generator), why, race outlook change, Apply / Cancel; receipt with Undo (`CoachUndo`).
- [x] Stale proposals recomputed on Apply (plan signature); throttles explained before the tap.
- [x] Downstream refresh through `schedulePlannedReminders`, `WidgetBridge`, `PhoneWatchSync`.
- [x] `--plan-manage` recipe.

### Stage 4 — Photo food logging (client and server code landed; live vision unverified)
- [x] `MealPhoto` (downsample to 1280 px, re-encode with no metadata, ≤ 2.5 MB) + `MealPhotoTests`.
- [x] `FuelEstimator` image request (`image { mime, base64 }`, omitted when absent), `rejected`
      outcome, `outcome(for:)`, `rejectionLine` + `FuelEstimatorTests`.
- [x] Composer camera glyph (Take a photo / Choose a photo), camera-denied fallback, journal row
      and history thumbnails through `MealPhotoView`, detail-sheet photo, photo-only titles.
- [x] `meal-estimate`: optional image, `validate.ts` request and response validation (bounded
      items and numbers, unknown micros null, `not_food` / `unreadable`), structured logs with
      counts only; `validate_test.ts` (9 Deno tests pass). NOT deployed.
- [x] Retry idempotency (one row, re-estimated), delete-then-late-response guards, manual
      precedence are exercised by the existing gate and by `FuelEstimatorTests`.
- [ ] Live verification against a deployed function with a real photo (needs deployment).

### Stage 5 — Fuel dashboard (landed)
- [x] Day strip (thirty days back, the name jumps to today); the whole page is judged for the
      selected day by the same engine (`dayNow` is the last minute of a past day, so its pacing
      reads as final); logging from the page lands on that day; History holds older days.
- [x] Energy hero shows "—" with no meals (unlogged is never "ate nothing"); three macro rings
      (carbs · protein · fat); sodium joined fluids on the quiet floors line; the readout strip
      keeps the training context ("FOR tomorrow's long session"); an Add food pill with every
      way in (describe, photo, library, barcode, numbers); journal rows with photo thumbnails;
      recents chips unchanged.
- [x] Empty-day card for today and for past days, no over-budget state anywhere.
- [ ] Light and dark screenshots on the simulator (below).

### Validation
- [x] `xcodegen generate`, `build-for-testing`, `test-without-building` on the whole
      `MomentumTests` target (UI tests skipped by target, never by suite id): **2,142 tests in
      242 suites, all passing** (baseline 2,104 in 238 + `PlanLifecycleTests` 20,
      `PlanAdjustmentServiceTests` 7, `MealPhotoTests` 4, `FuelEstimatorTests` 7).
      `deno test supabase/functions/meal-estimate`: 9 passing.
- [x] Screenshots on the shots simulator (`8561E2EB-F589-4F7C-B803-8FE694912FD7`): Your plans
      populated, the builder's first step and its preview, Manage plan, Fuel populated with photo
      meals and empty, light and dark. Files under the session scratchpad `shots/`.
- [x] Healthy cold launch and `--storage-unavailable` recovery screen unchanged.
- [ ] Not run this session: the `MomentumUITests` target (it needs a clean, uncontended
      simulator and is known to carry container-contamination failures; see memory notes).

---

## 5. Decisions and outstanding dependencies

- **Shelf, not multiple `TrainingPlan` rows** (see 3.1). Reversible later through the same
  blueprint format if a real multi-plan store is ever wanted.
- **Upcoming plans start today when they come due**, never backdated; the notice says which day
  they were scheduled for.
- **Photo estimation is reopened** by the owner's brief; the "never estimate from images" lines in
  `FUEL-FLOW.md`, the function header and `FuelEstimator` are amended to describe the new contract
  rather than deleted from history.
- **Meals stay local**; no Storage bucket, no meal table. Photos never leave the device except
  inside the estimate request body.
- **Deployment**: `meal-estimate` changes are prepared, tested locally, and NOT deployed. Exact
  commands are listed in §6 when the stage lands. Vision requires `GEMINI_API_KEY` or
  `ANTHROPIC_API_KEY` on the function, both already provisioned for text.
- **Real-device checks still owed**: camera capture on a physical iPhone (the simulator has no
  camera; the library path is what the simulator exercises), Watch refresh after activation.

## 6. Deployment, real-device checks, limitations

**Edge Function (prepared, NOT deployed).** From the repo root, once the owner authorises:
```bash
deno test supabase/functions/meal-estimate
supabase functions deploy meal-estimate
```
No new secrets: `GEMINI_API_KEY` and `ANTHROPIC_API_KEY` are already set for text. After deploy,
verify with a real photo through the app (`--debug-pro` is not needed on a Pro account) and read
the function log for `{"fn":"meal-estimate","outcome":"ok","hasImage":true,...}`. `deno check`
reports a pre-existing type error on `output_config` in the Anthropic SDK call (present at HEAD
before this work; the call runs at runtime and is unchanged).

**Schema.** V4 → V5 is a lightweight stage adding one sidecar table; existing stores migrate on
first launch with no data rewrite. `RunningSchemaMigrationSpikeTests` opens the archived build-36
store through V5.

**Real-device checks still owed.** Camera capture on a physical iPhone (the simulator has no
camera; the library path is what the simulator exercises); the Watch receiving a plan switch
(`PhoneWatchSync.scheduleRefresh` is called, the paired-device push is not exercisable here);
notification resync after an activation on device.

**Limitations, plainly.**
- Photo recognition is unverified live until the function is deployed; the client path was
  exercised against the validator and seeded meals only. Estimates from a photo are shown with the
  same "≈" treatment as text and confidence is capped by the prompt (0.4–0.7).
- Previous plans are snapshots (sessions and completed-workout ids), not live relationships; the
  review is read-only by design. Tune-up races do not carry into a shelved blueprint.
- The plan preview runs the engine on the main actor after a debounce (milliseconds per run).
- Manage plan's "My goal" rows open the existing complete Plan Settings form rather than a new
  race flow; the builder covers new plans.
- The composer's placeholder was shortened to make room for the camera glyph.

## 7. Progress log
- 2026-09-07 — audit complete, document written; Stages 1–5 landed; unit suite green at 2,142.
