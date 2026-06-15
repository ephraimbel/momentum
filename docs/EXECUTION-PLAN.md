# momentum — Execution Plan

> Companion to [`PRD.md`](PRD.md). The PRD says *what & why*; this says *what to build, in what order, and when it's done*. Section refs (§) point into the PRD. **Part II of the PRD is authoritative on any conflict.**

## Guiding sequence
Build the **two capture engines first** — they are the riskiest, most foundational pieces. Nothing visual matters until both feel excellent. Then layer the design system, the unified store, AI + plans, monetization, and polish. Defer Watch and social.

Each phase ends at a **gate**: a short list of objective, testable criteria. Don't start the next phase until the gate passes. Gates map to PRD §13.11 acceptance criteria.

---

## Phase 0 — Foundations & engine spikes (de-risk)
*Goal: prove the two engines are durable and accurate before building UI around them.*

### 0.1 Project scaffold
- [ ] Create Xcode project `Momentum`, **iOS 18.0 min target** (locked 2026-06-09 — native `MeshGradient`), SwiftUI lifecycle. Generated via XcodeGen (`project.yml`).
- [ ] Folder layout per §17 (App / DesignSystem / Models / Persistence / Engines / Features / Services / Resources).
- [ ] `Services` environment object with protocol stubs: `LocationService`, `MotionService`, `HealthService`, `PlanEngine`, `StrengthEngine`, `AIService`, `SyncService`, `PaywallService`, `NotificationService`, `PersistenceController`.
- [ ] Add deps (SPM): RevenueCat, Superwall, supabase-swift. No map/UI SDKs.
- [ ] Info.plist usage strings + Background Modes (location), HealthKit, Sign in with Apple capabilities (§8.11). Verbatim strings from §8.11.
- [ ] `Route` enum + RootView routing shell; 4 tabs (Today/Plan/History/You) as empty placeholders.

### 0.2 Data model (SwiftData)
- [ ] All `@Model` types + enums exactly per §8.7. `Workout` carries exactly one of `gps`/`strength`.
- [ ] `PersistenceController` with `ModelContainer` (singleton), `SchemaV1`, lightweight migration scaffold.
- [ ] **Recovery rule:** never delete `LocationSample` log or completed `SetEntry` on edit — mark, don't destroy.
- [ ] `Formatters` util (§19): pace, speed, distance, weight, duration, clock. All SI in, display out.

### 0.3 GPS tracking engine (`actor`) — §8.3
- [ ] State machine: `Idle → Acquiring → Tracking ⇄ AutoPaused/Paused/GPSLost → Saving → Summary` + `Recovered`.
- [ ] Accept-fix gate, min-movement gate, pace EMA (α=0.2), throttles (hero 1s, route 0.5s) — constants are authoritative.
- [ ] Auto-pause thresholds per discipline; elevation via `CMAltimeter`; cadence via `CMPedometer`.
- [ ] **Durability:** persist each accepted `LocationSample` immediately; checkpoint aggregates every 5s; cold-launch "Resume?" for unfinished workouts.
- [ ] Splits engine (§21): close one per display unit; partial final; recompute on trim.
- [ ] Cardio PR scan (§21): fastest contiguous 1k/5k/10k window + longestRun + longestDuration; ties keep earlier.

### 0.4 Strength session engine (`actor`) — §8.4 / §22
- [ ] Session model: ordered exercises → ordered sets; running duration timer.
- [ ] Set prefill precedence: plan target → last session same index → empty.
- [ ] Log-a-set: persist immediately, light haptic, auto-start rest timer.
- [ ] Rest timer via **scheduled local notification + haptic** (fires backgrounded). Default rest by category (compound 150s / isolation 75s / else 120s).
- [ ] Plate calculator (§22): descending greedy per-side; show remainder if unmakeable. kg/lb plate defaults.
- [ ] e1RM (Epley) tracking; PR detection (heaviest, best e1RM, rep-max, best set volume, best session volume).
- [ ] Supersets (shared `supersetGroup` interleave rest); units stored kg, display kg/lb.
- [ ] **Durability:** every set write persists; cold-launch "Resume?".

### 0.5 Engine test harness
- [ ] Unit tests with fixtures: e1RM, PR detection, plate calc, splits, streak, progression schemes.
- [ ] GPS smoothing tested against recorded traces; build a replay harness for a known loop.

**▶ Gate 0:** GPS distance within ±2% on a real route; force-quit mid-activity recovers full route; log-a-set < 3s; rest timer fires backgrounded; force-quit mid-lift resumes all sets; all engine fixture tests green.

**Phase 0 status — 2026-06-09 (engines + durability landed; 32 tests green, clean build):**
- ✅ Done & verified: project scaffold (XcodeGen, iOS 18, Info.plist/entitlements, 4-tab shell), full SwiftData model + enums + PersistenceController + library seed, design tokens + `IridescentView` + `Formatters`, deterministic core (`PlateCalculator`, `StrengthMath` e1RM/volume/repmax/weekly-sets, `CardioMetrics` splits + fastest-window, `StreakCalculator` 2-day grace, `GPSProcessor` accept-gate/distance/auto-pause), both engine actors over the pure cores.
- ✅ **Durability:** `@ModelActor` stores (`GPSWorkoutStore`/`StrengthWorkoutStore`) eagerly persist every sample/set; cold-launch recovery via `ActiveWorkoutMarker` + `WorkoutRecovery`. Verified by `DurabilityTests` (write → read back via separate context → recover → finish clears marker).
- ✅ **CoreLocation/CoreMotion wiring:** `LocationService` (iOS 17+ `CLLocationUpdate.liveUpdates` → `GPSProcessor.Fix` stream) + `MotionService` (`CMPedometer` cadence, `CMAltimeter` elevation), wired into `Services.live()`.
- ✅ **Replay harness:** `GPSReplayTests` drives a synthetic 1 km loop (+ noise injection) and asserts distance within ±2%.
- ⏳ Remaining for full Gate 0 (device-only): **real-route ±2% field validation** and a **force-quit UI recovery** test on a physical device; the view-model pump loop (`LocationService.fixes()` → `GPSTrackingEngine.ingest`) lands with the Cardio live screen in Phase 1; Live Activity + rest-timer notifications also Phase 1. Deferred external SPM deps (RevenueCat/Superwall/supabase-swift) stay out until their phases.

---

## Phase 1 — Design system + unified core loops
*Goal: the two live experiences and the post-workout moment feel premium.*

### 1.1 Design system — §5, §18
- [ ] Asset-catalog colors (light/dark) per §5.1; `Theme` tokens (space/radius/font/iridescent) per §18.
- [ ] `IridescentView`: `MeshGradient` (iOS 18+) / `AngularGradient` fallback (iOS 17); `intensity` + `static`(Reduce-Motion) modes.
- [ ] Motion tokens (§6.1) + `Haptics` helper. Shared components (§5.5): hero metric, metric tray, selection card, Today card, split row, PR badge, progress ring, oversized control, primer sheet, streak/heatmap.
- [ ] Strength components: exercise card, set row, rest-timer ring, plate calculator, superset group, muscle-map body diagram, exercise-search row, program/template card.

### 1.2 Cardio live screen — §4.3, §7.4
- [ ] Native MapKit live map (muted basemap + bright route), heading-aware eased camera, speed-coupled zoom.
- [ ] Map bloom on start (grayscale), route draw (throttled `MapPolyline`), breathing dot annotation w/ iridescent edge.
- [ ] Hero metric (discipline default, swappable), rolling tabular numbers, secondary tray, oversized pause/stop, GPS-strength glyph.
- [ ] All states (§4.3): acquiring weak/strong, tracking, auto-paused, manual pause, low battery, GPS lost, saving, error.
- [ ] Milestone haptics per km/mi; two-step stop → snapshot.

### 1.3 Strength live screen — §4.4, §7.5
- [ ] Exercise list; add-exercise → library; set rows (set#, ghosted previous, weight, reps, RPE, ✓).
- [ ] One-tap log with prefill; auto rest-timer ring (iridescent, TimelineView, pulse at 0); set types; supersets; plate calc; inline edit/reorder/swap; notes.

### 1.4 Exercise library — §4.5, §13.7
- [ ] Seed curated catalog (~150–300 exercises) with muscles/equipment/tracking mode/rest/cues. Version it. (Resolve §16 licensing first.)
- [ ] Search/filter by name/muscle/equipment; recents/favorites; custom exercises (2 fields).

### 1.5 Unified store, history, summary, share
- [ ] Mixed monochrome activity feed grouped by week (route vs muscle-map thumbnails) — lazy/paginated for 1000+ items.
- [ ] Post-workout summary per type (§4.6): hero card, splits/muscle-map, PR sweep, edit (rename/note/trim/privacy). AI block stubbed (templated) until Phase 2.
- [ ] True-B/W route card via `MKMapSnapshotter` + `CIPhotoEffectMono` → `mapSnapshotData` (off main thread).
- [ ] Share cards v1 (§25): SwiftUI templates via `ImageRenderer` scale=3; Story/Square/Landscape; foil wordmark.

**▶ Gate 1:** Both live loops run start→finish→summary→share with correct metrics and all states designed; history scrolls jank-free at 1000+ items; Reduce Motion holds static iridescence; VoiceOver labels on set rows/rest timer/map.

**Phase 1 status — 2026-06-09 (Slice A: strength loop landed):**
- ✅ Shared components: `ProgressRing`/`RestTimerRing` (iridescent), `OversizedButton`, `HeroMetric`, `PRBadge` (sweep), `SelectionCard`.
- ✅ Exercise library picker (`ExerciseLibraryView` search/filter/select + `CustomExerciseSheet`).
- ✅ **Strength live loop end-to-end:** `StrengthViewModel` (bridges the engine actor + durable store) → `StrengthLiveView` (set rows w/ ghosted previous + one-tap ✓, auto rest-timer ring, plate calculator) → `StrengthSummaryView` (volume/sets/duration, PR badges via `StrengthPRs`, working-sets-by-muscle). Today `Start` → `ActivityChooserView` → strength live → summary.
- ✅ Verified: clean build, **34 tests green** (incl. `StrengthFlowTests` full-loop + prefill-from-last-session integration), app launches and renders the hero dark look.
- ✅ **Slice B: Cardio live loop** — engine exposes live route + snapshot; `CardioViewModel` pumps `LocationService.fixes()` → `GPSTrackingEngine.ingest`; `CardioLiveView` (muted MapKit map, bright route polyline, breathing iridescent dot, per-discipline hero metric, pause/auto-pause, two-step stop, GPS-strength glyph, acquiring overlay); `CardioSummaryView` (route map, distance/pace/elevation, per-unit splits). Run/ride/walk wired through Today → live → summary. Builds clean; app launches without regression; 34 tests green. Visual map verification + ±2% still need a device / location-sim tap-through (Gate-1 device item).
- ✅ **Slice C: History · Profile · Share** — summaries refactored into reusable `StrengthSummaryContent`/`CardioSummaryContent`; `HistoryView` (weekly-grouped mixed timeline, route-silhouette vs strength thumbnails) → `WorkoutDetailView`; `ProfileView` + `ProfileStats` (shame-free streak, consistency heatmap, lifetime totals, e1RM PR shelf, longest-run); `ShareCardView`/`ShareCardContent`/`ShareCardRenderer` (monochrome + one iridescent accent + foil wordmark, story/square via `ImageRenderer`@3×, `ShareLink`) reachable from every summary + detail. 36 tests green (added `ProfileStatsTests`); app launches clean.
- ✅ **Gate-1 loose ends closed:** VoiceOver pass (set rows/fields/log button, rest timer label+value, cardio map + GPS glyph, history rows as single elements, profile streak + heatmap summaries, hero metric combined; decorative iridescence/breathing-dot hidden); history scale hardened (route-silhouette point-capped at 120, List virtualization, `ScaleTests` aggregates 1000 workouts correctly).
- **Gate 1: met except one device-only item.** Both live loops run start→finish→summary→share; history present; Reduce-Motion + VoiceOver handled. The only thing that can't be closed in-sandbox is **live-map ±2% real-route validation** (needs a device). Deferred within Phase 1 (tracked, non-blocking): full **Dynamic Type** (fonts are fixed-size today), anatomical muscle-map diagram, supersets UI, RPE polish, inline set reorder/swap, true-B/W route snapshot, map "bloom" transition, weekday-aligned heatmap, PersonalRecord persistence.

---

## Phase 2 — AI + multi-discipline plans
*Goal: onboarding sells a plan; the coach adapts with no shame.*

### 2.1 Deterministic plan engine — §9
- [ ] Running: Riegel P5k, pace offsets, ≤10%/wk volume, 4th-week deload, taper, phases (§9.1).
- [ ] Strength: progression schemes (linear/double/percent/RPE), volume landmarks, split templates by days/week, exercise selection by equipment/goal, deload (§9.2).
- [ ] Hybrid scheduling & recovery (§9.3): space hard efforts, pair compatibly, align deloads — the no-competitor capability.
- [ ] Adaptation triggers (§9.4) deterministic; never a "failed" state. Fixture tests for all of the above.

### 2.2 Edge Functions + AI — §8.8
- [ ] `workout-analysis`, `plan-generate`, `plan-narrate` on Supabase; JWT auth; env keys; rate limit 60/day.
- [ ] Strict-JSON schema + system prompt (§8.8); **templated per-discipline fallback** renders within 4s, ≤55 words, no medical claims (prompt + post-filter).

### 2.3 Onboarding → plan reveal — §4.1, §7.1, §26
- [ ] Question sequence (one per screen, springy), answers → stored values (§26), optional calibration → seed p5k / lift e1RM.
- [ ] "Building your plan…" iridescent moment (do not skip) → unified plan reveal + glowing goal ring → projected outcome.
- [ ] Permission primers (custom screens before system prompts).

### 2.4 Plan surfaces — §4.7, §7.7
- [ ] Today card (any discipline) + pre-session brief; unified calendar (mixed disciplines); re-plan animates card to new day.
- [ ] Programs/templates shelf (running/strength/hybrid + user templates); Sunday weekly check-in (§24, generated locally).

**▶ Gate 2:** Onboarding ≤90s yields a valid unified plan; running volume never +>10% w/w; strength deload on schedule; hybrid never places hard interval run day-after heavy squats; AI returns valid JSON or fallback within 4s; missed sessions recompute deterministically.

**Phase 2 status — 2026-06-09 (complete; 55 tests, 14 suites green):**
- ✅ **PlanEngine** (`PlanEngine`/`PlanModels`/`PlanService`): Riegel paces, running ≤10%/wk + deload/taper macrocycle, strength splits + equipment-aware selection + progression schemes, hybrid recovery scheduler (no hard run after heavy lower). `PlanEngineTests` verify the §13.11 invariants across a sweep.
- ✅ **Onboarding → reveal** (`OnboardingViewModel`/`OnboardingFlow`/`BuildingPlanView`/`PlanRevealView`): cold open → question sequence (§26 mapping) → iridescent build beat → personalized week + goal ring → primer; gated on first launch. `OnboardingFlowTests` cover answers→plan.
- ✅ **Today + Plan + adaptation** (`PlanCoaching`/`TodayView`/`PlanView`): prescribed-session card w/ streak + week ring; rest day; from-plan start pre-loads strength targets; finish credits the plan; no-shame miss reconcile moves sessions. `PlanCoachingTests` cover crediting + adaptation.
- ✅ **AI layer** (`WorkoutReadTemplates`/`AIService`/`AIReadCard` + Edge Function source under `supabase/functions/`): deterministic ≤55-word, no-medical-claims, plan-aware read renders instantly (the §8.8 never-block guarantee); Pro-gated AI read card in both summaries; `workout-analysis`/`plan-narrate` committed for Phase-4 deploy (Opus 4.8, structured outputs, no `temperature`). `WorkoutReadTemplatesTests` enforce the word/claims bar.
- **Gate 2: met in-sandbox.** Plan validity, ≤10%/wk, deload, hybrid recovery, no-shame adaptation, and AI-or-fallback are all tested. The live Edge Function round-trip (vs. the always-present fallback) gets verified when deployed in Phase 3/4. Onboarding ≤90s is a UX target to confirm on device.

---

## Phase 3 — Monetization — §10
- [ ] RevenueCat entitlement `pro`, offering `default`, products `momentum_pro_monthly` / `momentum_pro_annual`.
- [ ] Superwall placements: `onboarding_complete`, `ai_read`, `full_plan`, `analytics_locked`, `history_locked`.
- [ ] Single `Feature` enum = source of truth for gating; gate exactly the §10 set (per §13.10 table).
- [ ] Honest billing: 7-day trial on annual, renewal date shown plainly, cancel ≤2 taps, renewal reminder.

**▶ Gate 3:** Pro gates exactly the defined set; cancel reachable ≤2 taps; renewal terms shown; Superwall A/B wired.

---

## Phase 4 — Polish + launch
- [x] Live Activity / Dynamic Island (§23) for cardio + strength; throttled updates; end on stop/recover.
- [x] HealthKit write all types (§8.6) + reads (HR, steps, resting HR, body mass); haptics pass.
- [x] Analytics surfaces (§4.8): working sets/muscle, e1RM curves, training-load read, pace/speed trends, consistency heatmap, PR shelves, streak.
- [x] Sync service (§8.9, §27): dirty-row push, last-write-wins scalars, never overwrite sample log/sets, route upload only when not private. *(code complete; CONFIG-PENDING live Supabase keys)*
- [x] Notifications (§24); analytics event taxonomy + crash/perf monitoring (§13.5); data export + account deletion (§13.3).
- [~] Accessibility audit (§13.4): VoiceOver, Reduce Motion, color-independent meaning, 44pt targets, contrast on iridescence. **Dynamic Type intentionally deferred** (product decision — fixed-size type).
- [ ] App Store craft: mono+iridescent screenshots across cardio + strength; field validation (±2% on real routes) before release. *(device-only)*

**▶ Gate 4 (launch):** All §13.11 acceptance criteria pass; crash-free >99.5% in test; private workouts never upload route geometry; offline workout syncs within one foreground cycle.

**Phase 4 status — 2026-06-15 (in-sandbox complete; 166 unit + 4 UI tests green, clean build):**
- ✅ **Live Activities (§23):** strength rest-timer + a new **cardio Live Activity** (lock-screen + Dynamic Island: distance, pace/speed, native count-up clock, route-tinted goal bar). Verified in-sim on a live run (compact island + lock-screen render).
- ✅ **HealthKit (§8.6):** `HealthService` writes completed workouts (`HKWorkoutBuilder`, per-type activity mapping, dedupe) and reads body mass + resting HR; verified live (Health app shows the saved run). `CalorieEstimator` (distance + MET) verified live.
- ✅ **Deeper analytics (§4.8):** e1RM curves (`ExerciseTrends`), pace/speed trends (`ProgressInsights`), training-load/ACWR read, working-sets-by-muscle, consistency heatmap, PR shelves, streak — Pro-gated where §10 requires.
- ✅ **Sync (§8.9/§27):** `SyncEngine`/`SyncService` upload-only dirty-row push on foreground; privacy filter omits route geometry on private workouts; raw `LocationSample`s never serialize. `SyncEngineTests` assert the private→nil-route contract. Live round trip is CONFIG-PENDING on Supabase keys.
- ✅ **Notifications + observability (§24/§13.5):** planned reminders, weekly check-in, no-shame streak nudge; the full §13.5 **analytics event taxonomy** (12 events, non-PII) + **north-star funnel** + **MetricKit** crash/perf monitor. Runtime-verified `workout_started` emits to the unified log. Data export + account deletion via `DataManager`.
- ✅ **Accessibility (§13.4):** VoiceOver across set rows, rest timer, cardio map/GPS glyph/goal bar, history, hero metric, streak, consistency heatmap (collapsed-to-summary), confidence pips; Reduce Motion holds static iridescence; iridescence never the sole signal. `testHeatmapExposesVoiceOverSummary` confirms the summary element at runtime. **Dynamic Type deferred by product decision** (fixed-size type).
- **Gate 4: met in-sandbox.** §13.11 GPS (±2% replay + **pace-continuity** ≤30 s/km @1s now unit-tested), strength (6/6 with fixtures), plan (≤10%/wk, deload, hybrid recovery, no-fail/missed-recompute), AI (≤4s-or-fallback, ≤55 words, no medical claims), monetization (exact gate set, cancel ≤2 taps, plain renewal), and sync/privacy are all tested. Crash-free monitoring is in place via MetricKit.
- ⏳ **Remaining for full Gate 4 (device-only / external):** real-route **±2% field validation**, the **50-run zero-loss** durability protocol, **onboarding ≤90s** wall-clock, and **App Store screenshots**; plus CONFIG-PENDING live keys (Supabase sync + server AI, RevenueCat/Superwall billing) and the Sign-in-with-Apple App ID capability.

---

## Phase 5 (v1+) — deferred
Apple Watch (cardio GPS via `HKWorkoutSession` + on-wrist strength logging) → voice coach → richer recovery/training-load → more disciplines (row/HIIT/yoga/swim) → **then** the opt-in social-lite layer. Never before the personal app is loved.

**Watch status — 2026-06-15 (Slices 1–3 landed; core verified on a watchOS 26.2 sim):**
- ✅ **Slice 1 — scaffold + home:** `MomentumWatch` watchOS target embedded in the iOS app, sharing only platform-agnostic phone code (`Enums`, `Formatters`). True-black brand home with a discipline picker (Run/Ride/Walk + Lift) over a `NavigationStack`. DEBUG deep link `--watch-screen=…` for deterministic sim verification (watch taps are unreliable in the sim).
- ✅ **Slice 2 — on-wrist cardio:** `HKWorkoutSession` + `HKLiveWorkoutBuilder` (HR, active energy, distance); live screen with HK-managed elapsed clock, discipline hero (pace/speed), HR (iridescent), energy, pause/end. HealthKit entitlement + `workout-processing` background mode + usage strings. `--watch-demo` feeds a synthetic session for sim verification.
- ✅ **Slice 3 — on-wrist strength:** weight/reps steppers (SI stored, unit-natural steps) + one-tap Log set → success haptic + iridescent rest countdown ring with Skip.
- ⏳ **Slice 4 — WatchConnectivity (paused):** two-way phone↔watch sync (send finished watch workouts → phone SwiftData/HealthKit/sync; receive planned targets). Deferred — `WCSession` needs a **paired phone+watch device** to verify the round-trip (not reliably testable on standalone sims). *Note: finished cardio already reaches the phone via HealthKit; strength is watch-only until Slice 4.*
- ⏳ **Device-only across all slices:** real HR/distance sensor capture, the success/rest haptics, and interactive taps need a physical Apple Watch.

**Voice coach status — 2026-06-15 (landed; Pro):** spoken cues during workouts (PRD §4.10). `CoachingCueBuilder` (pure, unit-tested) authors the text — milestone + split pace, rest complete, paused/resumed, goal reached (no medical claims). `VoiceCoachService` (AVSpeechSynthesizer) ducks music and reads them, gated behind `Feature.voiceCoach`; passed into the cardio loop + strength rest timer only when entitled. Verified: 171 unit + 4 UI green; runtime-confirmed the cue pipeline dispatches in-sim (`cue=Paused.` in the log). AVSpeech audio itself is device/speaker-only. **Next in the Phase 5 sequence:** richer recovery/training-load → more disciplines (row/HIIT/yoga/swim) → social-lite (last).

---

## Cross-cutting (every phase)
- **Tests** for deterministic engines against fixtures; UI tests for core loops; device matrix (small→Pro Max, iOS 17 & latest).
- **Performance budgets** (§13.1): 60fps live; cold-start <1.5s; snapshot/image work off main thread.
- **Privacy** (§13.3): private by default; owner-only RLS; no health-data-exfiltrating analytics; no ad SDKs.
- **North-star metric:** % of new users completing first workout *and* viewing the AI read within 24h. Instrument from Phase 2.

## Resolve early (PRD §16 — these gate decisions)
1. ✅ **DECIDED 2026-06-09: iOS 18.0 minimum** — native `MeshGradient`, no fallback as primary.
2. Exercise-library **sourcing/licensing** — blocks the §13.7 seed in Phase 1.
3. Recovery-model **depth** in v0 (rules-only vs early readiness score).
4. Display **typeface** (native SF vs licensed) — much of the brand.
5. How much to **tease social** (hidden vs "coming soon").
6. **Name/trademark** vetting (App Store + USPTO).
