# Community realism audit — 2026-09-08

Scope: `HANDOFF-COMMUNITY-ROUTES.md`, Community wall, profiles, route generation and geometry.

**Follow-up:** the approved header, loading, route-browser and saved-collection changes are documented in [COMMUNITY-POLISH.md](COMMUNITY-POLISH.md). The presentation decisions below describe the earlier audit snapshot.
The globe is a separate follow-up. This checkout contains concurrent Plan work; verification uses
an isolated copy in `/tmp/momentum-community-work`, not a reset of the shared checkout.

## What the independent audit found

- **Codec:** the shipped bundle is entirely v2. Removed ambiguous v1 sniffing from the app; malformed
  payloads now reject the entire route rather than returning a plausible partial line. The Python
  test compiles the actual production Swift decoder and compares every coordinate against Python,
  including negative deltas, Earth bounds, truncated varints and a v1 magic-byte collision.
- **Pool agreement:** ledger `walk` resolves `(metro, home)` once. Lead, lifetime and sessions pass
  that home through; wall, visited-profile pages and pulse materialization pass the same home into
  `CommunityRoutes.loop`. Featured athletes were the exception: their derived home was a hashed
  suburb while their lead used a written coordinate. Featured homes now use the written coordinate.
  Tests compare every mapped generated lead against its ledger slot, geometry and printed distance.
- **Identity:** no name, handle, identity RNG order or follow storage changed. The fixed historical
  identity fixtures pass. `bio(for:rng:)` remains the last identity RNG draw. Changing the post copy
  does not change identity; removed analysis and elevation still consume their historical post draws.
- **Launch work:** route tables and directory build off the main thread. Measured directory builds
  were 178–236 ms on this simulator under varying concurrent load; this is not evidence of a speedup.
  Pool resolution now memoizes lengths/slots by exact metro/home, bounded at 4,096 entries. It does
  not decode more geometry. The map queue drops cancelled queued requests and caps active renders at
  four ordinary plus one urgent. A deterministic cancellation test proves 16 abandoned requests
  never start behind four active renders. Cold network maps still take time; no physical-device FPS
  claim is made.
- **Demo geometry:** the change from 24 to 200 vertices still cut corners on detailed loops and
  multi-lap workouts. Demo sampling now preserves every bundled vertex, including every lap.
- **Copy:** the trail pool is park-anchored walking directions, not verified singletrack. A real
  screenshot showed a “Trail run” along Tryon Road; mapped titles now avoid a surface claim. Removed
  invented trail ascent and canned “Momentum read” claims about heart rate, cadence, split drift and
  bar speed. Short edited caption pools avoid unsupported weather, timing and measured effort.
  Captions remain examples, not statements from real runners, and uniqueness is not forced.
- **Disclosure:** Community offers “Includes examples” with an explanation; sample profiles say
  “Example athlete.” This keeps the populated experience without presenting simulated people,
  posts or reactions as live members.

## Bounds that do and do not state a contract

The 8 km chord ceiling is a review trigger, not proof of land or runnable access. The 15% common
vertex-count ceiling catches a return to a fixed cap across the bundle, but could miss damage to
one route. Independent simplification fixtures pin the actual 5 m error budget and a 240-turn route
that must not be reduced to 90 points. “More points per kilometre” is not a valid universal rule:
straight roads legitimately need fewer vertices.

The 50 km p90 bound is only a regional regression guard. It is **not neighbourhood coverage**.
The test now measures the first coordinate of the actual mapped lead, rather than the first anchor
in a run pool that may not be the route on the card. Sparse suburbs still need more anchors; raising
the threshold again is not an acceptable fix. The core-city test now exercises fallback names such
as New York City and Shibuya-ku instead of skipping them. The park gate is 40 km from a metro town,
with 100 m tolerance only in Swift's approximate-distance test.

The previous nine hand-deleted remote park routes were not reproducible as an edit history. The
fetcher now applies the same geographic gate to all merged data on every save and rejects starts
snapped more than 1 km away. That independently removed two more candidate loops; see
[geographic removals](audits/community-2026-09-08/geographic-removals.json).

## Re-fetch outcome

All **ten** requested metros were re-fetched: New York, Sydney, Berlin, Paris, Amsterdam, Madrid,
Tokyo, Auckland, Mexico City and Munich. The run completed 1,331 API calls in 779 seconds. Comparing
geometry, New York changed substantially (42 old shapes replaced by 44), with smaller changes in
Paris, Tokyo, Auckland and Munich. Sydney, Berlin, Amsterdam, Madrid and Mexico City returned the
same shapes: re-fetching them was necessary to verify the handoff, but claiming ten changed metros
would be wrong. Geographic gates then removed one additional San Antonio trail loop and one Tampa
trail loop. The staged bundle still had 2,840 routes before water quarantine.

## Water review method

The handoff's “one to three wet samples is a bridge” rule is insufficient. A short crossing can be
wrong too. The audit retains sample order and consecutive streaks, queries nearby road/bridge
features for every wet point, and records geometry hashes. Ferries, tunnels and motorway/trunk-only
evidence cannot clear a wet sample. Missing responses remain unknown and fail the audit.

Unresolved geometry is conservatively quarantined rather than described as proven unsafe. The
quarantine command requires the exact source bundle hash, refuses unknown results or empty audits,
and refuses to empty a metro's running pool. Geometry-hash exclusions are applied on subsequent
fetches too; changed geometry must be audited again. Final installation requires a second audit of
the retained bundle. A water polygon and a nearby mapped road are evidence, not public-access
certification. Segments below the chosen threshold and gaps between samples remain unvalidated.

Mapbox references: [Tilequery](https://docs.mapbox.com/api/maps/tilequery/) and
[Directions](https://docs.mapbox.com/api/navigation/directions/). Tilequery distances are proximity,
not routed distance. Directions exclusions are best-effort, so requests now also include steps and reject returned ferry/train/inaccessible modes, missing steps and exclusion violations. The old request flag alone did not prevent ferry routes. Cached successful queries are local to
the audit; the default cache rotates daily. No API credentials appear in the report.

## Presentation decisions

- **Names:** retained. The simulator identity export contains 2,871 unique handles but only 1,009 display names; 2,850 athletes share a display name. Search already shows handle and location to distinguish them.
  A display-only alias migration could preserve handles, but renaming familiar followed people is a
  product change, not an urgent geometry fix. Do not regenerate handles from expanded name pools.
- **Avatars:** retained the 23 owner-supplied photos and existing presets/monograms. No generated
  faces or unlicensed scraped photos were added. More photographs would help, but the best source
  is consenting actual runners. Proposed pilot budget: **$300 maximum**, e.g. 20 participants at
  $15 with explicit image-use consent; this is a proposed allowance, not a vendor quote or spend.
  Keep a rights/consent manifest before bundling any new photos, and label fictional examples.
- **Header:** the normal layout is unchanged. A DEBUG-only `--community-compact-header` prototype
  replaces the empty Following strip with a compact Find people action when following nobody.
  Compare [current](audits/community-2026-09-08/header-current.png) and
  [proposal](audits/community-2026-09-08/header-proposal.png). Recommend the compact empty state;
  retain the richer strip once it has people.
- **Maps:** kept the two default basemaps. They remain visibly different, but less fragmented than
  five styles. Loading maps now say so; a failed render becomes “Route preview.” Reused cells do
  not display stale appearance snapshots while waiting for their new image.
- **Variety:** inspected six consecutive deep-scroll captures, more than 50 tiles, plus the warm
  wall and a full-screen post. Street grids, linear routes, irregular loops and out-and-back spurs
  are visibly varied. Repeated sport glyphs, monograms and generic bios are the bigger remaining
  tells. Adding random waypoints solely for novelty risks worse routes; keep the current shapes.

## Verification and practical limits

The revised staged-data community run passed **95 tests in nine suites**, including 1,882 mapped lead
pool checks. The 1,884 actual mapped lead starts had median home distance 9.84 km and p90 42.16 km. **Six UI tests passed**: live Mapbox wall browsing and opening the correct post/profile, the compact-header capture, handle search/profile navigation, plus three welcome animation/handoff tests. Screenshots verify presentation, not frame pacing on a real phone.

The initial whole unit target ran **2,281 tests: 2,275 passed, five failed, one skipped**. Failures
were in concurrent Plan work: three PlanContinuity SwiftData backing-data crashes, schema registry
36 versus expected 35, and a Plan management benchmark above its 200 ms limit. They are not hidden
behind the green Community subset. The repeated whole-target run executed **2,287 tests: 2,281 passed, five failed, one skipped**. The same five non-Community failures remained (Plan benchmark 266 ms). The tested snapshot predates subsequent concurrent Plan edits; this is not a claim about those newer edits.

Existing user-saved routes contain copied geometry. This bundle update does not rewrite those
saved records or migrate the shipped SwiftData schema. Users may still have old saved examples.

Commands (use an explicit available simulator UDID; never rely on `booted`):

```sh
xcodegen generate
xcodebuild build-for-testing -project Momentum.xcodeproj -scheme Momentum -destination 'platform=iOS Simulator,id=YOUR_UDID'
xcodebuild test-without-building -project Momentum.xcodeproj -scheme Momentum -destination 'platform=iOS Simulator,id=YOUR_UDID' -only-testing:MomentumTests
python3 -m unittest discover -s scripts/tests -v
python3 scripts/audit_community_routes.py --min-chord 600 --spacing 250 --workers 40 --report /tmp/community-water-final.json
```

`MomentumTests` is the whole verified target name. Confirm the executed count in the result bundle;
a misspelled `-only-testing` selector can execute zero tests. Builds here also passed the existing
`SourcePackages` directory explicitly with automatic package resolution disabled.


## Installed bundle and final water result

**2,826 routes across 65 metros**: 2,241 run, 281 ride and 304 park-anchored trail-pool routes.
All **61** original flagged loops are individually recorded in
[the decision ledger](audits/community-2026-09-08/all-61-loop-decisions.json), with ordered evidence
in [the original audit](audits/community-2026-09-08/water-before.json). Of those, 46 had mapped
bridge/waterfront evidence and 15 were quarantined: nine ferry-route geometries, five with only
trunk-road bridge evidence, and one pedestrian tunnel (Posey Tube) whose flat map trace reads as
water. The tunnel and trunk-road exclusions are conservative presentation/access decisions, not
claims that these crossings are impossible. The New York ferry geometry disappeared in the
re-fetch; the other 14 exclusions were removed from the refreshed shipping bundle. The 15 hashes
remain in `scripts/data/community_route_exclusions.json` to prevent their accidental return.

[The final audit](audits/community-2026-09-08/water-final.json) ran against the actual installed
resource: **7,555 segments, 21,052 unique samples, zero unknowns, zero unresolved water segments**.
There are 66 segments supported by mapped bridge evidence and two by mapped waterfront/path
proximity, across 44 routes. Dry samples are not continuous land coverage. The original scan's
transient network errors were retried successfully; no failed response was counted as dry.

Installed SHA-256: `a5464ccae9aaefc7e4d1e6dd0a35c088080602182ba3279c83f9b8022a2bf839`.
The final Python suite passed **12 tests**, including production Swift/Python parity over all 2,826
shipped route payloads plus independent and malformed vectors (282,519 compared coordinates).

The installed-data rebuild then passed **all 95 Community tests in nine suites**. Actual mapped lead starts had median home distance **9.93 km**, p90 **42.18 km** (1,884 posts); 1,882 generated lead/ledger geometry checks passed. The same exact resource was checked by the final water audit and cross-language codec test. A paired iPhone 15 Pro is listed; device frame-time profiling has not been performed. All reported UI validation is from the simulator.
