# momentum — Social Layer Design

> Companion to [`PRD.md`](PRD.md) and [`EXECUTION-PLAN.md`](EXECUTION-PLAN.md). Phase 5 social-lite,
> brought forward by decision **2026-06-15**. This is the authoritative design for the social surface.

## Guiding principle
The personal app is **sacred and private by default**. Social is a *second surface* that is **fully
opt-in** and **never leaks the private one**. Nothing about a user is public until they flip a switch,
and each switch is independent. This preserves the north-star ("a private mirror, not a public
ledger") while adding an opt-in public layer on top.

## Honest presence (decided 2026-06-15)
The app should feel alive **without deception** — no fake humans posing as real anonymous strangers
(brand, App Store 2.3/4.x, and FTC-endorsement risk). Liveliness comes from three honest levers:
1. A clearly-labeled **"Momentum community"** — curated, official/sample athlete profiles + activities,
   always badged as community content (never impersonating nearby strangers).
2. **Real aggregate presence** on the globe ("1,240 moving this week"), honest even at low counts.
3. The user's **own** activities seed the feed/globe so it's never empty.
Denser seeding later is always clearly-labeled community content.

## Information architecture
One new tab: **World** (5 tabs total: Today / Plan / Progress / World / Coach). The globe is the hero;
the feed pulls up beneath it; profiles push from either. Profiles are also reachable from Progress.

## The globe (centerpiece)
- **Custom minimalist globe** (Apple-native: SceneKit/Canvas, dark near-black landmass, no labels) so
  it reads as *momentum*, not "Apple Maps with dots." MapKit powers the city/street zoom levels.
- **Zoom continuum** globe → country → region → city → street: aggregate **glow heat** when far →
  **clustered** counts mid → **individual fuzzed dots** near.
- **Presence states:** live-now (bright, pulsing iridescent; static under Reduce Motion), recent
  (faint), density → soft iridescent bloom.
- **Privacy (hard constraint):** only public activities/users; never precise coordinates (snap to a
  coarse ~1–5 km H3/geohash cell + jitter; trim route start/end); live presence is ephemeral (TTL) and
  opt-in; one obvious "Appear on the map" toggle, **off by default**; fuzzing enforced **server-side**.

## Feed & posts
A post = a public `Workout` rendered in the existing share-card language (route/muscle thumbnail, hero
metric, PR badges, optional caption + optional public AI read). Modes: Following / Nearby / Discover +
discipline filters. **Interactions v1 (decided): one iridescent "respect" reaction + asymmetric
follow. Comments deferred** until moderation tooling exists. No-shame always: no public failure, no
shaming leaderboards.

## Profiles
Public projection of the athlete: avatar (iridescent orb/initials v1), name, @handle, optional
city, bio, lifetime totals + streak + consistency heatmap + PR shelf (reuses `ProfileStats`), recent
public activities. Own profile shows Edit + privacy; others' show Follow + public content only.

## 2026-06-17 — Globe moves to Today (World tab removed)
**Decision (supersedes the section below):** the **World tab is removed** (tabs are now Today · Plan ·
Progress · Profile). The globe becomes a **zoom-out from the Today map**: a `globe` button on Today
slides the cards away and flies the *same* Mapbox camera from the street all the way out to the world
(`worldMode` in `TodayView`). It's one continuous map — street → planet — not a separate screen. The
globe wears a realistic **satellite Earth** (`MapStyle.standardSatellite`: green/blue land + ocean +
atmospheric halo over space) — the one place we leave the monochrome basemap, because a *world* view
should feel like the actual world. Enter/exit use Mapbox's native `withViewportAnimation(.fly())` for
the cinematic zoom-out → arc → settle. Tapping a community dot still opens that athlete's profile.
`GlobeView` (the standalone tab screen) is deleted. DEBUG `--world` opens straight on the globe;
verified by the deterministic `GlobeLookUITests`. Everything in the section below about the World
*tab* still describes how the globe + profiles behave — only the entry point changed (tab → Today).

## 2026-06-17 — World tab IS the globe (feed removed)
**Decision (overrides the feed-as-World-tab IA above):** the World tab is now *only* the globe — the
map of everyone on Momentum. The aggregated Discover/Following **feed stream is removed** (deleted
`WorldView`, `FeaturedFeedCard`, `WorldFeedUITests`). Rationale: the globe is the differentiated,
honest centerpiece ("see everyone in the world"); a scrolling feed is the commodity Strava already
owns and pulled focus from the map.
- **What stays:** tapping a globe dot → that athlete's **profile**, which still shows their posts via
  `FeedPostCard` (route map / muscle map / timed discipline card). Your own posts still render on your
  profile (Progress → Profile). `FeedAssembler`/`CommunityDirectory`/`FollowStore`/reactions/comments
  all remain — they're profile-scoped now, not a global stream.
- `RootView` routes `.world → GlobeView()`; the globe hides its nav bar (the "Around the world"
  overlay is the title) and bleeds full-screen behind safe-area-inset overlays.

## 2026-06-17 — Profile becomes a tab; editorial-feed redesign
A push to make the social surface feel Substack/Strava-grade (clean, editorial, enterprise):
- **Navigation:** the immersive **Coach chat tab was removed** and **Profile is now its own tab**
  (Today · Plan · Progress · World · Profile). The coaching *chat* still exists, reachable from
  **Settings → Coach**; the coaching *intelligence* lives on as the Progress **"Coach"** segment
  (formerly "You" — the athlete-model read). `AppTab` (Route.swift) + `RootView` drive this.
- **Profile page (`ProfileScreen`)** is the body-of-work home: identity → headline counts
  (Workouts / Day streak / Following) → lifetime totals → discipline breakdown → consistency grid →
  trophy/PR shelf → your shared activities → privacy. Built from reusable components in
  `Features/Profile/`: `StatGrid`, `ConsistencyHeatmap`, `PRShelf`, `DisciplineBreakdown`.
  `AthleteProfileView` reuses the same scaffold (community body-of-work is deterministically
  synthesized in `CommunityAthleteProfile`, clearly badged). The old `ProfileView` was deleted.
- **Progress** no longer carries totals/heatmap/PRs (moved to Profile) — it stays the analytical brain
  (status, recovery, trend charts, weekly muscle, the Coach/athlete-model segment).
- **Feed:** editorial Substack rows — quiet byline, bold headline, a **Strava-style metric strip**
  (`FeedItem.metrics`, derived from `statLine`), lean chrome (whitespace + one hairline, no boxes), a
  **featured lead** (`FeaturedFeedCard`, full-bleed hero for the top photo/route post), a **discipline
  filter rail**, and gentle entrance choreography. Tapping a post opens the **reading view**
  (`PostDetailView`): full caption + the optional **Momentum read** (public AI narration via
  `FeedItem.aiRead` ← `Workout.aiSummary`; community seeded). Shared media via `FeedMediaView`.

## 2026-07-09 — Community tab (the feed stream returns)
**Decision (supersedes the 2026-06-17 "feed removed" call):** the aggregated feed is back as a
first-class **Community tab** (Today · Plan · Progress · **Community** · Profile — the tab bar is now
full; five is the iOS ceiling before "More"). Research pass (Strava feed critique + Substack model +
X timeline lessons) shaped the rules; the direction is *Substack-for-runners*, not a Strava clone:
- **Strictly reverse-chronological**, finite, follow-scoped. Two scopes — **Following | Everyone**
  (`CommunityView`, `FeedAssembler.scoped`); default Everyone so a new athlete never lands on a dead
  tab. **No algorithmic ranking, no "for you", no trending — ever.**
- **Declared intent** is the fix for Strava's high-traffic/low-signal feed: the save screens now ask
  *"How did it go — and why did this one matter?"* and carry the **per-workout visibility picker**
  (`ShareVisibilityRow`, seeded from the profile default — previously the default was never applied
  and everything saved private). The share moment happens at save time, with a plain-words hint of
  what each level exposes.
- **One iridescent "respect" reaction** stays the only reaction (no kudos arms race, no vanity-count
  scoreboard). **Flat comments** (280-char cap + moderation) ship on every post via `PostCommentsView`.
- **Multi-photo (cap 5):** `WorkoutPhoto` child rows on `Workout` (each blob its own external
  storage; legacy `photoData` folds in lazily on first photo edit), `PhotoCarousel` pager on feed
  cards + reading view; the first photo is always the hero in grids/tiles.
- **Community bylines navigate** (feed → `AthleteProfileView` → follow); own bylines stay inert.
- **Explicitly rejected:** algorithmic ordering, leaderboards/segments, quote-reposts, public-by-
  default visibility, fabricated engagement notifications (no real actors locally — social
  notifications wait for the Supabase phase, where `AppNotification` grows social kinds + a targetID).

## Privacy matrix (defaults conservative)
| Control | Default | Options |
|---|---|---|
| Workout visibility | Private | Private / Friends / Public (per-workout + global default) |
| Appear on the map | Off | Off / On (fuzzed) |
| Public route maps | Off | Off / On (trimmed + fuzzed) |
| Show exact numbers | On (if public) | toggle |
| Location shown | Off | Off / City / Region |
| Discoverable | Off | Off / On |

`Workout.privacy` (`.private`/`.friends`/`.public`) already exists; `SyncEngine` already omits route
geometry when private. The social layer extends this foundation; it does not replace it.

## Backend (Supabase, config-gated like sync/AI)
Owner-only-RLS tables: `profiles` (public projection), `posts` (public workouts; route only if
allowed, pre-fuzzed server-side), `follows`, `reactions`, `presence` (ephemeral TTL, fuzzed cell,
opt-in → Supabase Realtime drives the live globe), `reports`/`blocks`. Public-read only for rows the
owner marked public; writes owner-only; fuzzing server-side (never trust the client to redact).

## Safety & moderation (non-negotiable)
Report/block, rate limits, image/text moderation, content policy, minor protection, location-safety.
This is real scope — it's why social was deferred. Required before public UGC / comments ship.

## Monetization
Social is **free** (growth/virality per PRD §10). Pro stays the AI coach + advanced analytics.

## Phased build (each slice verifiable in-sim with seed data; live multi-user parts light up with Supabase)
- **Slice 0 — Profile + privacy controls** *(shipped)*: editable profile page + privacy matrix +
  per-workout & default visibility. No network; pure local + UI. Valuable on its own.
- **Slice 1 — Community feed** *(shipped local, 2026-07-09)*: the Community tab (`CommunityView`) +
  share moment on the save screens + multi-photo carousel; honest seeded community, labeled.
- **Slice 2 — Other profiles + follow** *(shipped local)*: `AthleteProfileView` + `FollowStore`,
  reachable from feed bylines and globe dots.
- **Slice 3 — The globe** (aggregate heat → fuzzed clustered dots → individual dots; "Appear on map" opt-in).
- **Slice 4 — Reactions + live presence** (Realtime). Reactions shipped local (`ReactionStore`).
- **Slice 5 — Moderation tooling + comments** *(shipped local)*: report/block (`ModerationStore`) +
  flat 280-char comments (`CommentStore`); server-side enforcement waits for Slice 6.
- **Slice 6 — Supabase backend** *(built 2026-07-09; lights up on project setup —
  docs/SOCIAL-BACKEND-SETUP.md)*: Supabase Auth session (Sign in with Apple → JWT via
  `AuthController`/`SupabaseClientProvider`), versioned migrations + RLS (`supabase/migrations/` —
  profiles/posts/follows/blocks/reactions/comments/reports; blocks enforced server-side both
  directions; `feed_page` keyset RPC), Storage (public `avatars`, private `post-photos` +
  per-viewer signed URLs), the publish sweep (`postPublishedAt` + client-side redaction +
  `RouteTrimmer` end-trimming — precise start/end never leave the device), and the four stores
  pushing/pulling through `SocialBackending` with zero UI changes. Remote athletes show **real
  data only** (`CommunityAthlete.isSample == false` hides the synthesized body-of-work).
  **Still deferred:** Realtime presence (globe) and social notifications (`AppNotification`
  social kinds + targetID deep-links).

## 2026-09-07 — Where the seeded community actually runs
**The wall's realism is a DATA problem, and two defects were shipped in the data while every test
watching the code passed.**

**1. Runners were drawn over water.** `scripts/fetch_community_routes.py` asked Mapbox Directions
for real street loops — and then threw most of each answer away, keeping every Nth vertex until 90
were left. On a long loop that replaces bridge and shoreline geometry with straight chords
kilometres long, and a chord goes where the road did not. 425 of the 967 shipped loops carried a
chord over 500 m; the worst was 10.3 km. Sampled against Mapbox's own `water` polygons — the same
data the app's basemap paints blue — **seventeen of the forty worst-chord loops were drawn over open
water**: an 8.8 km line from Sausalito across the Golden Gate, a Chicago "run" out in Lake Michigan,
Sydney Harbour, Lake Ontario, the Hudson. `CommunityContentAuditTests.everyRouteFollowsBundledStreetGeometry`
passed throughout, and honestly: every drawn polyline WAS a bundled loop. The bundled loop was wrong.

**2. Everyone ran downtown.** Every loop of a metro was routed from that metro's single downtown
coordinate, so all ~44 seeded athletes of a metro traced the same city-centre streets — including
the two thirds of them who, since the 2026-08-29 places pass, say they live in a suburb or a
commuter town. A wall of strangers whose stated homes span 2,990 real towns and whose maps span 65
downtowns reads as generated no matter how good the rest of the content is.

**What ships now.**
- **Geometry is the routed path.** Simplification is Douglas-Peucker at 5 m, which can only remove a
  point already lying on the line it leaves behind, so the shape stays on the road it came from.
  Ferries are excluded from routing (a ferry leg is a genuinely over-water polyline), and any chord
  over 700 m has its interior sampled against the live water layer before the loop is admitted.
- **Loops are anchored on the towns athletes actually claim.** Each metro's anchors are picked from
  `CommunityPlaces` by farthest-point sampling, so a handful covers the whole metro instead of
  clustering downtown, and the core city carries a bigger share because a third of a metro's
  athletes live there. Every loop ships its anchor (`c`), and `CommunityRoutes.pools(city:near:)`
  hands an athlete the loops near their own home — resolved identically by the ledger, the wall card,
  the profile grid and the pulse path, so the index a session stores still names the geometry the
  tile draws.
- **Trails exist.** A third kind (`trail`), anchored on parks, nature reserves, trailheads and
  forest via Mapbox's category search. Trail runs were unconditionally mapless before this, for the
  honest reason that no trail geometry was bundled — the one sport this community runs in nature was
  the one that never showed where.
- **Wire format v2** (`scripts/community_routes_lib.py` ↔ `CommunityRoutes.decode`): a magic byte,
  then zigzag varint deltas at 1e-5 degrees. Deltas cost about half what the old absolute `Int32`
  pairs at 1e-4 did, which is what pays for keeping the geometry instead of decimating it.

**The tripwires.** `CommunityRouteRealismTests` pins the shape properties offline — no chord long
enough to leave a road, geometry dense enough to be a routed path rather than a sample of one, every
loop anchored on a real place of its own metro, the median athlete starting within 15 km of home.
`scripts/audit_community_routes.py` does the empirical half against the live water layer; it is what
to run after a regeneration, and it exits non-zero when any loop is drawn on water.

**What that produced.** 2,840 loops across 65 metros (2,253 run, 281 ride, 306 trail) in 1.14 MB,
against 967 loops in 947 KB before. Runs span 2.4 to 26.2 km, rides 13.8 to 61.7, trails 4.0 to
18.2. The median distance from an athlete's home to the start of the route their card draws fell
from **41.3 km to 14.0 km**, and the ninetieth percentile from 79.7 km to 42.0 km. Vertex counts,
which the old fetch had collapsed onto exactly 90 for 99.4% of loops, now take 295 distinct values.

**One more thing the wall needed: ONE basemap family.** A seeded post's map style was dealt from
five options including the Pro `streets` and `outdoors` looks, so a single screen of six tiles could
put a quiet grey street plan beside a saturated blue-and-green atlas — six different apps in one
grid, and a straight breach of the house rule that colour is earned. It deals from the two default
styles now, which are also the two an athlete without Pro could actually be using.

**And the demo athlete's own runs.** `DemoSeed.samplesFromLoop` had the same disease at a smaller
scale: `dense: false` kept 24 points of a 10 km loop, so the profile grid drew smooth ovals straight
across the University of Texas campus and the Colorado River, over a basemap showing every street
they ignored. It keeps 200 now.

**Also fixed:** three of the eight featured athletes (`bennettbuilt`, `priya.hybrid`, `ergmornings`)
print no location by design, and `routeCity` therefore fell through to `CommunityLedger.fallbackCity`
— their globe dots sat in New York, London and Chicago while every mapped tile on their profile
grids drew **Austin** streets. They carry an explicit `metro` now; the byline is unchanged.


### 2026-09-08 — independent route audit corrections

See [COMMUNITY-REALISM-AUDIT.md](COMMUNITY-REALISM-AUDIT.md) for evidence and verification. The
previous section records the earlier implementation, not a geographic guarantee. Short wet streaks
are not automatically bridges, and `exclude=ferry` is best-effort: the fetcher must inspect returned
step modes. Pool equality proves data consistency, not real-world access. Park-anchored walking
directions are not verified trail surface. Demo routes preserve every vertex; the intermediate
200-point cap still cut corners. Sample posts no longer invent elevation or measured AI analysis.
The community remains a clearly disclosed example population, not evidence of live membership.
