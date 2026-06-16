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
- **Slice 0 — Profile + privacy controls** *(in progress)*: editable profile page + privacy matrix +
  per-workout & default visibility. No network; pure local + UI. Valuable on its own.
- **Slice 1 — Community feed** (World tab + share-card feed; honest seeded community, labeled).
- **Slice 2 — Other profiles + follow.**
- **Slice 3 — The globe** (aggregate heat → fuzzed clustered dots → individual dots; "Appear on map" opt-in).
- **Slice 4 — Reactions + live presence** (Realtime).
- **Slice 5 — Moderation tooling + (optional) comments.**
