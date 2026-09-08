# Handoff: finish and raise the community route realism pass (2026-09-08)

Paste everything below the rule into Codex. It is written to be read cold.

---

## PROMPT

You are finishing and improving a change to **Momentum**, an iOS running app at
`/Users/ephraimbelachew/momentum` (SwiftUI, SwiftData, Mapbox, Swift Testing — not XCTest).
Read `CLAUDE.md` first, then the section of `docs/SOCIAL-LAYER.md` dated 2026-09-07,
"Where the seeded community actually runs".

The app ships a seeded community of ~2,871 synthetic athletes whose posts draw real GPS routes on a
Mapbox basemap. The owner's complaint was that it looked fake: people appeared to be running across
water, and everyone seemed to run in the same inner city. Another agent has just finished a large
pass on that. **Nothing is committed.** A second agent may be working in the same checkout, so run
`git status` before you touch anything and never `git add -A`.

Your job has three parts, in this order: **verify what was done, finish what was left, then make the
community page genuinely better.**

### Background: what was wrong, and what was changed

Both defects lived in the DATA, not the app code.

1. **Runners were drawn over water.** `scripts/fetch_community_routes.py` fetched real Mapbox
   Directions loops, then downsampled each to 90 points by keeping every Nth vertex. That replaces
   bridge and shoreline geometry with straight chords kilometres long, and the chord goes where the
   road did not. 425 of the 967 shipped loops carried a chord over 500 m, the longest 10.3 km.
   Sampled against Mapbox's own `water` polygons via the Tilequery API, **17 of the 40 worst loops
   were drawn over open water**: an 8.8 km line from Sausalito across the Golden Gate, a Chicago
   "run" out in Lake Michigan (8 of 8 samples wet), Sydney Harbour, Lake Ontario, the Hudson.
2. **Everyone ran downtown.** Every loop of a metro was routed from that metro's single downtown
   coordinate, while `CommunityPlaces` already spread the athletes across ~3,000 real towns. Two
   thirds of them said they lived in a suburb and traced city-centre streets.

Note the trap: `CommunityContentAuditTests.everyRouteFollowsBundledStreetGeometry` passed the whole
time and its comment claimed over-water routes were "structurally impossible". The test only ever
asserted the drawn shape equals a BUNDLED shape; the bundled shape was the broken thing. That
comment is now corrected. Be alert for the same class of error elsewhere.

**Data, both regenerated and installed:**
- `Momentum/Resources/CommunityRoutes.json` — 65 metros, 2,840 loops (2,253 run, 281 ride, 306
  trail across 63 metros), 1.14 MB. Was 967 loops in 947 KB.
- `Momentum/Resources/CommunityPlaces.json` — 3,018 towns, every one now carrying a region label so
  bylines read "Cedar Park, TX" rather than "Cedar Park".

**Scripts:**
- `scripts/community_routes_lib.py` (new) — Douglas-Peucker, the v2 wire codec, geometry helpers.
- `scripts/fetch_community_routes.py` (rewritten) — no index decimation; Douglas-Peucker at 5 m;
  `exclude=ferry`; iterative ring radius so a loop lands near its target distance; anchors picked
  from `CommunityPlaces` by farthest-point sampling with the metro's core city seeded first; a
  third kind, `trail`, anchored on parks and nature reserves via Mapbox's Search Box category
  endpoint; per-endpoint rate lanes; incremental save so `--merge` resumes.
- `scripts/audit_community_routes.py` (new) — samples the shipped bundle against the live water
  layer, exits non-zero if a loop is drawn on water.

**Swift:**
- `CommunityRoutes.swift` — wire format v2 (magic byte, zigzag varint deltas at 1e-5 degrees) with a
  v1 fallback; loops carry an `anchor`; new `Pools` and `pools(city:near:)`, now the single place a
  route pool is resolved; `kind(of:)` sends `.trailRun` and `.hike` to the trail pool.
- `CommunitySessionLedger.swift` — `walk`, `lead`, `lifetime`, `sessions` all take `home:`; trail
  runs are mappable where the metro has trail geometry.
- `CommunityGenerator.swift` — resolves the athlete's home before the ledger walks; bio pools
  roughly tripled; `feedStyles` narrowed from five basemaps to the two defaults.
- `CommunityDirectory.swift` — `CommunityAthlete.homeCoordinate` (derived, never stored); three
  featured athletes given an explicit `metro`.
- `DemoSeed.swift` — `samplesFromLoop` kept 24 points of a 10 km loop, which is why the demo
  athlete's own grid drew smooth ovals across the University of Texas campus; now 200.

**Tests:** `MomentumTests/CommunityRouteRealismTests.swift` is new; the content-audit, coherence and
surface-perf suites were updated.

**Claimed results — re-derive them, do not trust them.** Whole unit target green at 2,254 tests in
253 suites. Median distance from an athlete's home to the start of the route their card draws fell
from 41.3 km to 14.0 km (p90 79.7 → 42.0). Vertex counts went from seven distinct values across 967
loops, 99.4% of them exactly 90, to 295 distinct values.

---

### PART 1 — Audit the previous agent's work

Assume nothing it claims is true. In particular:

- **Prove the codec round-trips.** `CommunityRoutes.decode` (Swift) must be the exact inverse of
  `community_routes_lib.encode` (Python). A v1 payload whose first byte happens to be `0x02` would
  be misread as v2; the shipped bundle is entirely v2, so decide whether that fallback is still
  earning its risk.
- **Prove every caller resolves the same pool.** `pools(city:near:)` is called from the ledger, the
  wall card, the profile grid, the pulse path and the tests. If one omits `home:`, the index a
  session stored names a different loop and the tile's printed distance stops matching the shape
  drawn beneath it. Find every call site and show they agree.
- **Confirm the identity contract held.** The ledger's RNG draw order is documented and pinned by
  `CommunityPlacesTests.theDrawOrderStillNamesTheSamePeople`. Nothing should have moved.
- **Measure launch cost.** `pools` now runs three times per athlete while the directory builds
  ~2,900 of them. This surface has a history of launch regressions; see `CommunitySurfacePerfTests`.
- **Distrust the test bounds.** Several were tuned after seeing the data: `maxChordM` went 4 km →
  8 km, a points-per-kilometre floor was replaced by a uniformity check, and the athlete-distance
  p90 went 40 → 50 km. Each has a written justification in the test file. Read them and judge
  whether any is a bound picked to make red go away rather than one that states the real contract.
- **Check a post-hoc data edit.** Nine trail loops were deleted from the bundle with a one-off
  script because their anchors sat 50 to 151 km from any town of their metro. The fetch script now
  filters parks at 40 km, but a clean re-fetch may not reproduce the shipped file exactly. Verify.
- **Judge one visual decision.** Narrowing `feedStyles` from five basemaps to two is taste, not a
  bug fix. It was done because one screen mixed a quiet grey street plan with a saturated
  blue-and-green atlas, which contradicts the app's "colour is earned" rule. Sanity-check it.
- **Confirm a safety assumption.** The bio pool expansion is only safe because `bio(for:rng:)` is
  the LAST draw from an athlete's rng stream. Verify that is still true.

### PART 2 — Finish what was left open

**2a. Resolve the remaining water hits.** The audit of the shipped bundle reported 188 wet samples
of 26,630 (0.7%) across 61 loops, worst loop 10 samples. Before, on just the 25 worst chords of the
old bundle, 302 samples were wet and one loop alone had 84. Most of the 61 are probably legitimate:
a bridge deck and a waterfront greenway both sit inside the water polygon, and Toronto's
harbourfront, the Hudson River Greenway and Vancouver's seawall are exactly where people run. **This
was not verified loop by loop.** Read the audit by CONSECUTIVE wet samples on one chord: one to
three is a bridge, dozens is a crossing. Classify all 61, then re-fetch or drop the real crossings.
Note the audit ran before those nine trail loops were dropped, so re-run it:

```
python3 scripts/audit_community_routes.py --min-chord 600 --spacing 250 --workers 10
```

Worst offenders to start with: Oslo run #28, San Francisco run #15, Toronto run #5, Brooklyn ride
#3, Tampa run #8, New York run #5.

**2b. Re-fetch the ten metros whose anchors used a stale rule.** Some metros carry no place named
after themselves — the geocoder answers Berlin with "Mitte", Tokyo with "Shibuya-ku", and after the
places regeneration New York with "New York City". Those fall back to the town nearest the metro's
own coordinate. The code is correct now, but the shipped data for them was built before the fix:

```
python3 scripts/fetch_community_routes.py \
  --cities "New York, NY|Sydney|Berlin|Paris|Amsterdam|Madrid|Tokyo|Auckland|Mexico City|Munich" \
  --anchors 10 --workers 10 --merge --out Momentum/Resources/CommunityRoutes.json
```

Metro keys are separated by `|`, not `,`, because the keys contain commas. Expect about 20 minutes.
Then re-run the audit and the tests.

### PART 3 — Make the community page better

The realism problem is fixed; the page is not yet as good as it could be. Everything below is
grounded in something observed on a real simulator run. Use judgement, do the ones that earn their
weight, and say what you skipped and why.

1. **Duplicate athlete names.** 40 first names × 45 surnames is 1,800 combinations for 2,863
   athletes, so roughly half the community shares a full name with somebody, which is visible in
   search. It was left alone because handles derive from names and `FollowStore` persists follows BY
   HANDLE (UserDefaults plus Supabase), so a rename orphans every shipped user's follow list. Find a
   migration-safe way to widen the name space — for example a handle-preserving alias map, or a
   collision-resolution pass that only renames athletes nobody can have followed — or document the
   decision to live with it.
2. **The cold-start of the wall.** Route tiles show line-art placeholders for tens of seconds before
   the Mapbox snapshots land, and the placeholder is indistinguishable from a finished tile, so it
   reads as the design rather than as loading. Check on a real device, then decide whether it needs
   a loading treatment or a warm-up of the first screenful.
3. **Avatars.** 23 real photographs cover 2,871 accounts; the rest wear brand-glyph presets or
   letter monograms. The owner has twice deleted generated faces as "obviously fake"
   (`CommunityAvatars.swift` says "do not re-add generated faces"), so the only sanctioned path is
   more real, licensed photographs. Cost it out and propose.
4. **Header density.** The wall spends about a third of the first screen on search, the Following
   row and the scope tabs before the first tile, and the Following row is nearly empty for a user
   who follows nobody. This is a deliberate information architecture, so propose rather than
   restructure, with a screenshot of each option.
5. **Route variety within a metro.** Loops are anchored on ten places per metro with a rotating
   distance menu. Look at fifty consecutive tiles and judge whether the shapes read as different
   people's routes or as one generator's. If they clump, the levers are the anchor count, the
   waypoint shapes in `_waypoints` (triangle, quad, out-and-back), and the bearing rotation.
6. **Anything else that reads generated.** You have fresh eyes. Scroll the wall deeply, open
   profiles, use search, and write down what breaks the illusion.

### PART 4 — Verify before you report

```
xcodegen generate
xcodebuild build-for-testing -project Momentum.xcodeproj -scheme Momentum \
  -destination 'platform=iOS Simulator,id=EC8B432A-B25A-4771-BFB9-4C65BEB3DDBF'
xcodebuild test-without-building -project Momentum.xcodeproj -scheme Momentum \
  -destination 'platform=iOS Simulator,id=EC8B432A-B25A-4771-BFB9-4C65BEB3DDBF' \
  -only-testing:MomentumTests
python3 scripts/audit_community_routes.py --min-chord 600 --spacing 250 --workers 10
```

Run the WHOLE `MomentumTests` target — `-only-testing` with a wrong identifier silently runs zero
tests, and passing that way is the classic false green here. Then look at it yourself: install the
app, launch with `--seed-demo --profile-tab --profile-community --feed-global`, wait about a minute
for the Mapbox snapshots, and screenshot the wall and a full-screen post.

Report what you verified, what you found wrong, what you changed, and what you deliberately left
alone. Where you disagree with a decision above, say so and give your reasoning rather than
silently reverting it.
