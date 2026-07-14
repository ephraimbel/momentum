# Momentum — Pre‑First‑Build Plan

> Working checklist toward the first TestFlight build. Goal: nothing crashes, every screen loads
> fast, the flagged flows work perfectly, content feels real. Created 2026‑07‑14.
> Legend: `[ ]` todo · `[~]` in progress · `[x]` done · **[S/M/L]** effort · **P0–P2** priority.

## Workstream 1 — Community post cut‑off · P0
Root cause (verified): the multi‑photo carousel's `.page` `TabView` steals the vertical scroll in
`PostDetailView`, so content below the photo (caption, Momentum read, like/comment footer) can't be
reached → "cut off". Only the multi‑photo branch keeps hit‑testing on. Secondary: tall photos are
hard‑cropped to a fixed 260pt band.

- [x] Replaced `.page` TabView in `PhotoCarousel.swift` with a native paging `ScrollView`
  (`.scrollTargetBehavior(.paging)` + page dots) so it cooperates with the vertical parent. Shared →
  feed + reading view + workout photos. **Built green.**
- [x] Added `.fit` content mode; `PostDetailView` shows the whole photo (not the cropped band). Also
  fixed a leftover `bolt` → heart in `PostDetailView`'s footer (verified on device shot).
- [ ] UI test: seed a multi‑photo post fixture, open detail, swipe up, assert footer reachable
  (`CommunityFeedUITests.swift:107` has no scroll assertion). **[S] — deferred (needs a photo fixture).**

## Workstream 2 — Load fast & responsive · P0
List/grid/feed/aggregate surfaces are already cached. Remaining hot spots:
- [x] **#1 [HIGH,M]** Run summary/detail charts re‑walked all GPS samples 2–3×/render → now computed
  once into `@State` via `.task` (`RunCharts.swift` + `CardioSummaryView.swift`). **Built green.**
- [x] **#2 [HIGH,M]** Progress→History → `LazyVStack` (mine) + cached thumbnails (`HistoryFeedThumb`,
  co‑written with the parallel session; I moved it to off‑main + downsampled via `ImageDownsampler`).
- [x] **#3 [S–M]** Feed photo decode moved off‑main + downsampled once, via shared `ImageDownsampler`
  (`PhotoCarousel.swift`).
- [ ] **#4 [S]** Today strength‑home re‑filters workouts + MuscleActivation every body eval
  (`Today/TodayView.swift`). Cache into `@State`.
- [ ] **#5 [S]** Progress Trends `intensityMix` + `trendMetrics` uncached walks → `refreshAggregates()`.
- [ ] **#6 [S]** `FeedPostCard.commentCount` seeds comments 2×/render; `TodayView.lastKnownCoordinate`
  full‑sorts all workouts. Cleanups.

## Workstream 3 — See profiles & their route maps · P1  ← **in progress**
Both work for the seeded community (shipping/offline path). Gaps:
- [~] **P7 [M]** Visited/community profile grids draw a plain silhouette; own grid shows the full Mapbox
  snapshot. Snapshot community routes too so their maps actually show (`AthleteProfileView.swift`).
- [ ] **P4 [S]** GPS run with ≤1 coord → silent gap where the map should be (`CardioSummaryView.swift`).
  Add "route unavailable" placeholder.
- [ ] **P2 [S]** Own route hidden from feed by default (`.private` + `publicRouteMaps=false`). *(decision)*
- [ ] **P1 [M]** Real‑athlete byline silently inert on a miss (offline/guest) — add loading/fallback.
- [ ] **P3/P6 [S]** Post detail pushed from a grid gets a doubled nav bar; history detail ignores units.

## Workstream 4 — Randomize pfps: fake + real stock · P1  ⛔ blocked on rights decision
Today: 44 synthetic faces, deterministic + gender‑matched per athlete (`CommunityAvatars.swift`).
- [ ] Source real athletic/happy portraits; bundle as cached named assets alongside synthetic; widen
  the deterministic assignment across the combined pool (keep stable per‑athlete). **[M]**
- [ ] ⚠️ Decision: rights posture on real identifiable people as fake‑account avatars *(below)*.

## Workstream 5 — Release readiness · P1
- [ ] Full sim screen walkthrough — every screen loads, no crashes, back nav works.
- [ ] Strip/guard DEBUG marketing hooks (`--marketing-hero`, `--body-lit`, `--seed-demo`…) from Release.
- [ ] Version/build number, app icon, launch screen, Info.plist, entitlements; confirm no secrets committed.
- [ ] Swift Testing engine suite + UI tests green.
- [ ] Seeded community clearly badged (honest presence); paywall/onboarding gate holds.

## Sequence
1. ✅ WS1 (post cut‑off) + WS2 #1–3 (post‑run/History/photo perf) — done, built green
2. WS3 (route maps on profiles) ← **now** · then WS4 (avatars, needs rights call)
3. WS2 #4–6 + WS3 nits + WS1 multi‑photo test
4. WS5 (release readiness)

## Coordination note
A second Claude session shares this checkout and is working **onboarding / plan / progress** (identity
step, PlanView, HistoryFeedThumb). To avoid clobbering: I take **Community / Summary / avatars**; leave
onboarding/plan/progress to it. It runs `pkill xcodebuild` before its builds — expect the occasional
killed build; retry when its build loop is idle.

## Open decisions
1. **Avatar rights** — real+synthetic mix (best look, rights‑gray) vs synthetic‑only (safe).
2. **First‑build scope** — fix everything vs ship P0s + defer nits.
3. **Own‑route privacy** — keep private‑by‑default vs default route‑maps on for public posts.
