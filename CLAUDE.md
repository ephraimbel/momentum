# momentum — project guide

> **Read [`docs/PRD.md`](docs/PRD.md) first.** It is the single source of truth (v3.1).
> **Part II of the PRD is authoritative** wherever it conflicts with Part I prose.
> The phased execution plan lives in [`docs/EXECUTION-PLAN.md`](docs/EXECUTION-PLAN.md).

## What this is
A premium, AI-personalized, **multi-discipline** iOS fitness app — tracks **runs, rides, walks, and strength** in one place with an adaptive cross-discipline coach. Positioning: *"The Cal AI of fitness."* The wedge is the **hybrid athlete** (runs *and* lifts). **Social is deliberately deferred** — no feed/following/kudos at launch.

One-liner: **keep moving.**

## Non-negotiable principles
- **100% Apple-native.** SwiftUI, iOS 17+, MapKit, HealthKit. **No third-party map or UI SDKs.** Allowed third-party deps: RevenueCat, Superwall, supabase-swift.
- **Monochrome + iridescent.** ~95% pure black/white. Iridescence is an *earned* accent — it appears ONLY on progress/achievement (rings, PRs, streaks, live route accent, rest-timer ring, plan reveal). If it's not marking progress, it's not there. Dark mode is the hero look (true black).
- **Offline-first, zero lost workouts.** SwiftData is the local source of truth; persist every GPS sample and every completed set as they occur; recover on cold launch.
- **No-shame coaching.** Never a red "failed" state; missed sessions move with a one-line rationale.
- **Deterministic plan engine, AI only narrates.** Loads/volumes/paces are rules-based and testable (§9). The LLM authors rationale text and bounded tweaks only — never computes raw numbers. No medical claims.
- **SI units stored everywhere** (m, s, m/s, kg, bpm); convert only at display time.

## Stack & architecture
- SwiftUI + MVVM + Observation (`@Observable`); Swift Concurrency (`actor`s for engines, `@MainActor` for UI).
- **SwiftData** local store → **Supabase** (Postgres/Auth/Storage/Edge Functions) sync, owner-only RLS on every table.
- Two capture engines — `GPSTrackingEngine` (actor) and `StrengthSessionEngine` (actor) — feed one unified `Workout` model. Everything downstream is discipline-agnostic.
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
- GPS accept gate: `horizontalAccuracy ∈ (0,25m]`, newer timestamp, implied speed ≤ 12 m/s.
- Volume = Σ weightKg·reps over **working** sets only. Weekly sets/muscle: primary 1.0, secondary 0.5, trailing 7 days.
- Quality bars: GPS distance ±2%; log-a-set < 3s; cold-start-to-start < 2s; crash-free > 99.5%.

## Decisions made
- **Minimum deployment target: iOS 18.0** (locked 2026-06-09). We use `MeshGradient` natively for the true oil-slick iridescence — no `AngularGradient` fallback needed as primary. Build with Xcode 26.2.
- Project is generated via **XcodeGen** from `project.yml` — regenerate with `xcodegen generate`, don't hand-edit `.xcodeproj`.

## Open decisions (PRD §16 — confirm before they block)
exercise-library sourcing/licensing · recovery-model depth in v0 · display typeface · how much to tease social · name/trademark vetting.

## Workflow notes
- Build the riskiest things first: both engines (Phase 0) before anything else.
- After substantive changes, run the relevant fixture tests for the deterministic engines.
