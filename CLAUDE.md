# momentum — project guide

> **Positioning source of truth: [`docs/ENDURANCE-FOCUS.md`](docs/ENDURANCE-FOCUS.md)** (2026-07 pivot — supersedes PRD §1).
> For architecture/specs, read [`docs/PRD.md`](docs/PRD.md) (v3.1); **Part II is authoritative** where it conflicts with Part I prose.
> The phased execution plan lives in [`docs/EXECUTION-PLAN.md`](docs/EXECUTION-PLAN.md).

## What this is
A premium **running-first adaptive endurance trainer** for iOS — *from your first 5K to your first ultra* (pivot 2026-07, see ENDURANCE-FOCUS.md). The moat is **honest + adaptive**: a deterministic plan engine wrapped in recovery-aware adaptation (HealthKit is the single wearable integration — Oura/Garmin/Whoop/Watch all arrive through it), an injury feedback loop with gated return, and truthful time-to-goal verdicts (`PlanFeasibility`). **Strength stays as a supporting pillar** (strength-for-runners), and other sports remain trackable — but running is the headline. Fueling, not dieting; never a diagnosis. Social exists as **honest presence** (opt-in, private-by-default; `docs/SOCIAL-LAYER.md`) — no feed/kudos mechanics.

One-liner: **keep moving.**

## Non-negotiable principles
- **Apple-native UI.** SwiftUI, iOS 18+, HealthKit; no third-party **UI** SDKs. **Maps are Mapbox** (decision 2026-06-16, overrides the original MapKit-only rule) — all map rendering uses the MapboxMaps SDK via `MapStyleOption`/`RouteMapView`/`HeatmapMapView` (`MBXAccessToken` pk-token in Info.plist; SDK download via a `~/.netrc` secret token, not committed). Allowed third-party deps: MapboxMaps, RevenueCat, Superwall, supabase-swift.
- **Monochrome + iridescent.** ~95% pure black/white. Iridescence is an *earned* accent — it appears ONLY on progress/achievement (rings, PRs, streaks, live route accent, rest-timer ring, plan reveal). If it's not marking progress, it's not there. Dark mode is the hero look (true black).
- **Offline-first, zero lost workouts.** SwiftData is the local source of truth; persist every GPS sample and every completed set as they occur; recover on cold launch.
- **No-shame coaching.** Never a red "failed" state; missed sessions move with a one-line rationale.
- **Deterministic plan engine, AI only narrates.** Loads/volumes/paces are rules-based and testable (§9). The LLM authors rationale text and bounded tweaks only — never computes raw numbers. No medical claims.
- **SI units stored everywhere** (m, s, m/s, kg, bpm); convert only at display time.

## Stack & architecture
- SwiftUI + MVVM + Observation (`@Observable`); Swift Concurrency (`actor`s for engines, `@MainActor` for UI).
- **SwiftData** local store → **Supabase** (Postgres/Auth/Storage/Edge Functions) sync, owner-only RLS on every table.
- Two capture engines — `GPSTrackingEngine` (actor) and `StrengthSessionEngine` (actor) — feed one unified `Workout` model. Everything downstream is discipline-agnostic.
- **The adaptive layer is ~20 pure, tested engines** in `Momentum/Engines/` (`PlanFeasibility`, `BaselineEstimator`, `ACWRGovernor`, `InjuryResponse`, `RecoveryAdaptation`, `HRZones`, `IntensityMix`, `FuelingGuide`, `RaceBriefing`, …) — every number deterministic and unit-testable; adaptation is bounded, throttled (one structural change/week), and explained in plain words.
- AI via server-side Supabase **Edge Functions** (`workout-analysis`, `plan-generate`, `plan-narrate`), `ANTHROPIC_API_KEY` in env, strict-JSON responses, templated fallback so the post-workout moment never blocks.
- Folder layout: see PRD §17. App / DesignSystem / Models / Persistence / Engines / Features/* / Services / Resources.

## Engineering conventions
- Naming: views `…View`, view models `…ViewModel`, services `…Service`.
- DI: constructor injection; services in a `Services` environment object. Only the SwiftData `ModelContainer` is a singleton.
- Tabular figures (`.monospacedDigit()`) mandatory on all live/logged numerals.
- Animate transforms (`opacity`/`scale`/`offset`) only — never layout. 60fps. Honor **Reduce Motion** (static iridescence + crossfades). No strobing/fast iridescence.
- Design tokens live in `Theme` (PRD §18). Iridescent: `MeshGradient` on iOS 18+, `AngularGradient` fallback on iOS 17.

## Key numbers to never get wrong (PRD §§19–22)
- e1RM (Epley): `weightKg · (1 + reps/30)`.
- Streak: 2-day grace (one slipped day forgiven); rest days count; never surface "streak lost."
- GPS accept gate: `horizontalAccuracy ∈ (0,25m]`, newer timestamp; speed check is **Doppler-first** — accept any position jump consistent with the device-reported speed (real movement at *any* pace, so the trace never freezes on a fast descent), reject jumps far exceeding it (spikes); a discipline hard cap is the backstop only when there's no valid Doppler speed.
- Volume = Σ weightKg·reps over **working** sets only. Weekly sets/muscle: primary 1.0, secondary 0.5, trailing 7 days.
- Quality bars: GPS distance ±2%; log-a-set < 3s; cold-start-to-start < 2s; crash-free > 99.5%.

## Decisions made
- **Design direction (2026-06-09): LIGHT/white is the hero aesthetic** (overrides the PRD's dark-hero §5.1). Clean white canvas, faint-gray cards, near-black ink, soft iridescent gradient accents. App forced to `.light` in `MomentumApp`. The in-app brand element is the **glowing `IridescentOrb`** — do NOT use the M mark in-app. The **app icon is a futuristic iridescent "M"** — two angular peaks (tall left, shorter right) in the brand oil-slick gradient on pure black — generated by `scripts/make_icon_m.py` (`python3 scripts/make_icon_m.py <out.png>`) → `Assets.xcassets/AppIcon.appiconset/icon-1024.png` (regenerate from the script; the earlier orb generator `scripts/make_icon.py` is kept but superseded). **Typography (2026-06-09): two bundled open-source faces (OFL), no longer SF Rounded** — **Space Grotesk** is the display face (`Font.display` → hero numbers, titles, wordmark; technical/strong, tabular figures) and **Inter** is the UI face (`Font.rounded` → all body/labels/buttons; clean neutral sans). Both live in `Momentum/Resources/Fonts/`, registered via `UIAppFonts` in `project.yml`. All type routes through the two helpers in `Typography.swift`, so the whole app re-types from that one file — to change faces, edit only the PostScript names in `BrandFont`. `Image(systemName:)` icons stay on `.system()`. (Static weight files were sliced from the variable fonts with `fontTools.varLib.instancer`.)
- **Tab layout (as of 2026-07-09): Today · Plan · Progress · Community · Profile** — the bar is full (5 is the iOS max). Today is map-centric — edge-to-edge map, floating glass header, deck of three thoughts (plan → Start → one utility line). **There is no History tab** — history is a segment inside Progress (Trends · History · You), with the personal heatmap as a look-back card at its top (a card, never a tab — decided 2026-06). **Community is the social feed** (`CommunityView`): strictly reverse-chronological, Following|Everyone scopes, one "respect" reaction, flat comments, multi-photo carousel — never algorithmic (docs/SOCIAL-LAYER.md, 2026-07-09 section). Profile is a TikTok-style grid of workout tiles. Plan is a date-badge planner with macrocycle phase chips.
- **Brand accents:** iridescence stays earned-only; **`Theme.purple` (#7C63F0)** is the Pro/marketing accent (paywall, puck, injury banner). In strength contexts the anatomical `MuscleMap` replaces the orb.
- `DemoSeed` (DEBUG + `--seed-demo` launch arg) seeds a profile + sample workouts at container init — for visual iteration only; never ships.
- **Minimum deployment target: iOS 18.0** (locked 2026-06-09). We use `MeshGradient` natively for the true oil-slick iridescence — no `AngularGradient` fallback needed as primary. Build with Xcode 26.2.
- Project is generated via **XcodeGen** from `project.yml` — regenerate with `xcodegen generate`, don't hand-edit `.xcodeproj`.

## Open decisions (PRD §16 — confirm before they block)
exercise-library sourcing/licensing · name/trademark vetting. *(Resolved: typeface → Space Grotesk + Inter; recovery-model depth → shipped as `RecoveryAdaptation` two-signal easing + tripwire; social → brought forward 2026-06-15 as honest presence, see docs/SOCIAL-LAYER.md.)*

## Workflow notes
- Build the riskiest things first: both engines (Phase 0) before anything else.
- After substantive changes, run the relevant fixture tests for the deterministic engines.
- **Tests are Swift Testing** (`@Test`/`#expect`), not XCTest — run the whole scheme; `-only-testing` with a wrong identifier silently runs 0 tests. Always `build-for-testing` then `test-without-building` so tests run the binary you just built.
- Verify UI by screenshot on the simulator via DEBUG launch-arg deep links (`--seed-demo`, `--onboarding-*`, `--injury-report`, `--zones-demo`, `--plan-detail-long`, …). With multiple booted sims, always target an explicit UDID — `booted` resolves arbitrarily.
