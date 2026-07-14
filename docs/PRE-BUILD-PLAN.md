# Momentum — Pre‑First‑Build Plan

> Working checklist toward the first TestFlight / App Store build. Goal: nothing crashes, every
> screen loads fast, the flagged flows work perfectly, content feels real. Created 2026‑07‑14.
> Legend: `[ ]` todo · `[~]` in progress · `[x]` done · **[S/M/L]** effort · **P0–P2** priority.

## Status — committed `a337000`, pushed to `origin/feat/route-suggestion` (build green)

## Workstream 1 — Community post cut‑off · P0 — ✅ done
Root cause (verified): the multi‑photo carousel's `.page` `TabView` stole the vertical scroll, so
content below the photo was unreachable ("cut off").
- [x] `PhotoCarousel` → native paging `ScrollView` (`.scrollTargetBehavior(.paging)` + page dots).
- [x] `.fit` mode — reading view shows the whole photo (not cropped). `PostDetailView` `bolt` → heart.
- [ ] UI test: multi‑photo fixture + swipe‑up footer assertion. **[S] — deferred (needs a photo fixture).**

## Workstream 2 — Load fast & responsive · P0 — ✅ #1–3 done
- [x] **#1** Post‑run charts/splits computed once into `@State` (`RunCharts`, `CardioSummaryView`).
- [x] **#2** Progress→History `LazyVStack` + off‑main downsampled thumbnails (`HistoryFeedThumb`).
- [x] **#3** Feed photo decode off‑main + downsampled via shared `ImageDownsampler`.
- [ ] **#4 [S]** Today strength‑home cache · **#5 [S]** Trends `intensityMix`/`trendMetrics` (in the
  other session's `ProgressView` lane) · **#6 [S]** `commentCount`/`lastKnownCoordinate`. — deferred nits.

## Workstream 3 — See profiles & their route maps · P1 — ✅ met
Profiles are viewable (verified); tapping any post opens the **real route map** (detail view).
- [x] **P7** Kept lightweight route **silhouettes** in visited grids (a grid of live Mapbox renders was
  heavy + unverifiable; the real map is one tap away). Decision, not a gap.
- [x] **P4** "No route recorded" placeholder for GPS runs with ≤1 coordinate.
- [ ] **P2** Own‑route privacy default · **P1** real‑athlete byline fallback · **P3/P6** nav/units. — nits.

## Workstream 4 — Community pfps · P1 — ✅ synthetic‑only (shipped)
- [x] 44 curated synthetic faces, deterministic + gender‑matched (`CommunityAvatars.swift`).
- [x] **Decision:** NOT adding real stock photos. Real identifiable people as fake‑account avatars is a
  right‑of‑publicity risk (flagged earlier) — not appropriate to ship. Synthetic faces sidestep it.

## Workstream 5 — Release readiness · P1 — audited
- [x] DemoSeed is `#if DEBUG` — seeded demo content never ships in Release.
- [x] No secrets committed (only `Secrets.xcconfig.example`; no sk‑tokens/API keys in source). Mapbox
  token in Info.plist is the public `pk` token (expected).
- [x] Version `0.1.0` / build `1`; bundle `com.momentum.app`; iOS 18 target.
- [ ] **Bump `MARKETING_VERSION` → `1.0.0` for a public release** (0.1.0 is fine for TestFlight beta).
- [ ] **User's Xcode steps (can't be done from CLI):** archive a Release build, distribution signing
  (App ID `com.momentum.app` in the Apple Developer account + provisioning), upload via Organizer /
  Transporter, complete App Store Connect metadata (screenshots, description, privacy nutrition label).
- [ ] Optional pre‑submit: full sim smoke walk of every tab; run the Swift Testing suite green.

## Coordination note
Shared branch `feat/route-suggestion` with a second Claude session (onboarding/identity, plan, coach,
auth). The `a337000` checkpoint bundles both sessions' work (all building green). Lanes: I own
Community / Summary / avatars; the other owns onboarding / plan / progress.
