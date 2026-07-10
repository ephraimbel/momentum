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
- **Slice 6 — Supabase backend** *(the follow-up phase)*: Supabase Auth session (Sign in with Apple →
  JWT), SQL migrations + RLS for `profiles`/`posts`/`follows`/`reactions`/`comments`/`reports`,
  Storage buckets for post photos/avatars, Realtime presence, and social notifications
  (`AppNotification` social kinds + targetID deep-links). Everything above swaps its UserDefaults
  store for the network without UI changes.
