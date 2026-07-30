# Community feed redesign — plan

> **Status (2026-07-28): the CARD is built; the FEATURE is not launched** (owner call: *"i just want to refine it for now, we aren't launching this yet"*).
> Community remains back-burnered per the 2026-07-16 solo pivot ([`SOCIAL-LAYER.md`](SOCIAL-LAYER.md)). There is still no `AppTab` case and no user-reachable entry point — the feed renders **only** under the DEBUG launch arg `--community` (pair with `--seed-demo`), so Release behaviour is unchanged.
>
> **Landed:** the media-first `FeedPostCard` (§1), the stat-plate fallback (§2), the like/comment/**share** action row (§4), the visible `⋯` moderation menu, and the five stores re-injected in `MomentumApp` **behind `#if DEBUG`**.
> **Not landed:** typed `FeedItem` metrics + the conditional third stat (§3), and every launch step in §6.
> The **profile grid** shipped for real — see §9.

Research basis: live measurement of Instagram's profile grid + feed (2026-07-28), Strava's activity card, and Substack Notes/Inbox.

---

## 1. The shape: Instagram × Strava × Substack

Three borrowings, each for one specific reason:

- **Instagram** — media is the hero, edge-to-edge, square corners, and *one type size* where weight and colour carry all hierarchy. One shape, no exceptions.
- **Strava** — the numbers are engine-generated, non-customisable, and always present. Achievements are adjudicated banners, never self-claims.
- **Substack** — amplification lives in a separate Activity surface, never mixed into the authored-work list.

Today's `FeedPostCard` is title-first editorial (byline → headline → stats → media → caption). The redesign inverts it to media-first.

```
┌──────────────────────────────────────────────────────────┐
│  ●32  Ada Okafor · 5h                              ⋯     │  header row 1
│       Morning Long Run                                   │  header row 2 (title)
├──────────────────────────────────────────────────────────┤
│                                                          │
│                    M E D I A   (hero)                    │  full-bleed, square, 4:5
│                                                          │
├──────────────────────────────────────────────────────────┤
│   21.1 km      1:42:07      4:51 /km                     │  stat strip
│   DISTANCE     TIME         PACE                         │
│                                                          │
│  ✦ Fastest half marathon                                 │  PR banner (earned iridescence)
│                                                          │
│  ♡ 24    ⌾ 3                                   ⤴        │  actions
│                                                          │
│  ada.okafor  Legs felt awful for 8k then something… more │  caption
└──────────────────────────────────────────────────────────┘
                    36pt whitespace, NO divider
```

**Feed type scale — state once, never deviate:** one size, **15pt**, line-height ~19. Hierarchy is `weight 600 vs 400` and `Theme.ink vs Theme.inkTertiary`. The only other sizes in the card are `Theme.FontSize.label` (11) for stat labels and the display face for numerals.

**Header row 1:** `AvatarView(size: 32)` · name `.rounded(15, .semibold)` `Theme.ink` · `·` + relative time `.rounded(15, .regular)` `Theme.inkTertiary` · optional Pro seal · `Spacer` · `ellipsis` in a 44pt target. The timestamp belongs *here* — today's card has none anywhere.

**Header row 2:** the workout title, `.display(20, weight: .bold)`, `lineLimit(1)`. A workout's name is *what it is*, not commentary, so it sits with the byline — not down with the caption.

**Media:** full-bleed to both screen edges, `cornerRadius 0`, no border, no shadow. Default **4:5**; photos at native ratio clamped to `[1.91:1 … 3:4]`.

**Between posts:** 36pt whitespace, `LazyVStack(spacing: 0)`, **no hairline**. Delete the divider at `FeedPostCard.swift:47` — density is the divider.

---

## 2. The no-photo problem — the central tension

Instagram is image-first; **most momentum workouts will never have a photo.** A ladder ending in "sport glyph on a pastel wash" makes the majority of the feed look broken and decorative at once.

**Resolution: when there is no image, the numbers become the image.**

| # | Condition | Media |
|---|---|---|
| 1 | `photosData` non-empty | `PhotoCarousel` (or `RoutePhotoCarousel` — route is slide 0) |
| 2 | GPS route present | Cached route snapshot, Mapbox Light canvas, solid `Theme.route` periwinkle, silhouette placeholder crossfading in |
| 3 | Strength with activation | `MuscleMapView`, worked muscles lit |
| 4 | **Everything else** | **The stat plate** (below) |

**The stat plate** — a deliberate typographic composition in the *same 4:5 frame*:
- Hairline border inset `Theme.Space.lg`, on `Theme.surface`.
- Centre-left: primary metric as a hero numeral, `.display(64, weight: .black).monospacedDigit()`.
- Beneath: unit label, uppercase `.rounded(label, .bold).tracking(1)` `Theme.inkTertiary`.
- Bottom-left: hairline rule, then two supporting metrics at `.display(17, .heavy)`.

It reads as the same voice as every summary hero in the app, rather than an apology for a missing photo. Crucially it keeps **one shape, no exceptions** — a masonry feed of mixed heights is what actually makes a feed look broken.

Retire `FeedMediaView`'s `timedCard` glyph watermark for feed use.

---

## 3. Where the numbers live

Media is the hero, so the numbers sit in a fixed strip **directly under the media, above the actions** — visually Instagram's caption position, occupied by facts instead of commentary. That single placement decision is what keeps this a training feed rather than a photo feed.

Reuse `StatGrid` verbatim. Adopt Strava's **conditional third slot**, engine-chosen, never athlete-customisable:

| Sport | Slot 1 | Slot 2 | Slot 3 |
|---|---|---|---|
| Run / ride / walk | Distance | Time | Elevation **if** gain > ~19 m/km, else Pace |
| Strength | Volume | Time | Sets |
| Timed / other | Time | — | *(two slots; don't invent a third)* |

> The athlete authors the **title** and the **caption**. The app authors the **numbers** and the **badge**. Never blur that line — non-customisability is the mechanic that makes a card read as a record.

**Required structural change:** `FeedItem.statLine` is a pre-formatted `" · "` string and `metrics` recovers structure by *sniffing keywords* (`/mi` → pace, `lb` → volume, `:` → time). Far too fragile to drive a conditional rule. Add typed fields — `distanceM`, `durationS`, `elevationGainM`, `paceSPerM`, `volumeKg`, `setCount`, `commentCount` — and derive `statLine`/`metrics` from them. Keep `statLine` stored as a fallback so already-published rows still render.

---

## 4. The three actions

### Like — keep as-is
`ReactionStore` semantics unchanged: one binary reaction, `Set<String>` in `UserDefaults`, count = `baseReactions + (hasReacted ? 1 : 0)` so the viewer's own tap is always real offline.

Two fixes:
- **Name it "Like" everywhere.** The code says `respectButton` and `SOCIAL-LAYER.md` says "one iridescent respect reaction" — but it ships a rose heart tinted `Theme.like`, with a11y labels "Like"/"Liked". It has never been iridescent. Fix the naming drift toward what actually ships.
- **Keep it reversible.** Strava's kudos is deliberately irreversible, which suits a public praise economy; it doesn't suit a private-by-default app where a mis-tap should be undoable.

No emoji/typed reactions — the `reactions` table is `PK (post_id, user_id)` with no type column.

### Comment — ship as-is
Already complete end-to-end and genuinely good: flat `Comment`, 280-char cap, `CommentModeration.clean`, dedupe on merge, per-row report/block/delete. Only change: surface `commentCount` on `FeedItem` so the inline count doesn't require loading the thread.

### Third action — **Share, out of the app** (owner call 2026-07-28)

Repost was requested, investigated, and **rejected**:

1. **A workout is a performed record, not a publishable opinion.** Reposting a run cannot transfer the run. The profile trio is *Workouts · Miles · PRs* — admitting a repost anywhere near it makes the profile lie about work performed.
2. **The repo already ruled on it.** `SOCIAL-LAYER.md:114` lists quote-reposts under *Explicitly rejected*, from a prior research pass on this exact question.
3. **Strava — the closest comparable — has no repost at all.**
4. **RLS is the real blocker, not the schema.** `public.posts` PK *is* the workout UUID, so a repost can never be a second row. Worse: `posts_read` gates on `visibility='public' OR (friends AND is_following)`. A repost by definition shows someone's post to a *different* audience — reposting a friends-only post leaks it. With GPS route maps, that's a safety bug.
5. **Empty reposts destroy the signal.** Substack is the cautionary tale: down-weighting the cheap reaction relocated low-effort behaviour into restacks rather than removing it.

**Share** sends the post outward (share card → iMessage/IG), matches the solo pivot's designated growth loop, and costs zero backend work. Icon far-right, separated from the left like/comment cluster — the Substack split, where the left cluster is engagement and the right is distribution.

> **Noted alternative — "Try it".** Research independently proposed a third slot with a native meaning: adopt the *prescription* (route geometry or session structure) onto your own Plan. Attribution collapse is structurally impossible (your copy is a plan with no results), it doesn't touch the privacy model, and it produces a training artifact rather than a vanity one. Not chosen; recorded because it's the strongest non-repost idea found and it needs Plan-side work anyway.

---

## 5. Reuse vs replace

**Reuse unchanged — hard-won work, don't rewrite:**
`FeedRouteSnapshots`/`FeedRouteMap` (rate-capped, cached per style+appearance+width, silhouette-first crossfade, *never a live map per row*) · `PhotoCarousel`/`RoutePhotoCarousel`/`ImageDownsampler` · `StatGrid`, `AvatarView`, `PRBadge` · all four `UserDefaults` stores · `SocialSyncEngine` + `RouteTrimmer` (publish-redaction contract, unit-tested — do not touch) · `SocialPrivacy` · the whole Supabase schema + `feed_page` RPC · `CommunityView`'s off-render-path feed assembly (**do not move assembly back into `body`** — per-body assembly of ~950 items saturated the main thread).

**Replace:** `FeedPostCard`'s composition (media from a fixed 168pt rounded band → full-bleed ratio-based hero) · the two-action footer → three actions with inline counts · the bottom hairline → 36pt whitespace · `timedCard` → stat plate.

**Delete on sight (design-law drift):** `PostDetailView.swift:180-187` and `AthleteProfileView.swift:184-190` render the "Momentum community" label as `Capsule().fill(IridescentMaterial())`. That is decorative iridescence marking *provenance*, not achievement. `FeedPostCard.swift:109` already demoted the same label to plain text; these two are stragglers.

---

## 6. What it takes to actually launch (the gate)

The solo pivot didn't just hide a tab — it **unwired the surface**. All of this is required before the feed is real:

1. **Re-inject the five stores** in `MomentumApp` (`FollowStore`, `ReactionStore`, `CommentStore`, `ModerationStore`, `RemoteFeedStore`). Every social view reads them via `@Environment` — presenting any of them today **traps at runtime**.
2. **An entry point that is not a sixth tab** (5 is the iOS ceiling). Recommend a push from the Profile header, matching `ProfileScreen(showsBackButton:)`'s existing reverse path.
3. **Call `runPublishSweep`** — it has *zero call sites* today.
4. **Put `ShareVisibilityRow` on the save screens** — *zero references* outside its own file today.
5. **Re-verify report/block/delete on device** (App Store 1.2 UGC).

> Steps 3 and 4 are the ones that get forgotten. **No post has ever been published from the shipped app** — the Supabase schema, `feed_page` RPC, and both storage buckets are live and empty. Without them the redesign is a beautiful renderer for zero rows.

---

## 7. Phasing

| Phase | Work |
|---|---|
| **P0** | Unblock (~half a day): re-inject stores, entry point behind a DEBUG `--community` arg, verify no trap. Nothing else is possible first. |
| **P1** | The card: media-first `FeedPostCard`, stat plate, typed `FeedItem` metrics, inline counts. Verify against the seeded community — no backend needed. Screenshot pass, light + dark. |
| **P2** | Make posts real: wire `runPublishSweep`, add `ShareVisibilityRow` to save screens, verify save → publish → `feed_page` → render. |
| **P3** | Moderation hardening: promote the menu out of `.contextMenu` into the header `⋯`; device pass on report/block/delete. |

**Explicitly not now:** repost-as-amplification, typed/emoji reactions, a composer for non-workout posts, a sixth tab.

---

## 8. Risks, ranked

1. **App Store 1.2 UGC obligations reopen the moment the feed ships** — filtering, reporting, blocking, published no-tolerance policy. All three entry points exist but have never been exercised on device. Gate P2 on a device pass; get the no-tolerance line into the ToS. *The app already ate one rejection this cycle.*
2. **GPS/privacy leakage** — publishing route maps from a private-by-default app is the highest-consequence failure. Visibility stays Private by default, per-workout opt-in only, `RouteTrimmer` redaction untouched, exact-location Off.
3. **Honesty debt from the 950 seeded athletes** — ~40KB whose only job is making a dead feed look alive. Defensible as scaffolding; with real users it is fabricated engagement. Decide before P2: keep with an unmissable plain-text "Momentum community" byline, or delete and ship the real empty state (which already exists and is good).
4. **Media-first is heavier** — bigger images, more of them. The snapshot cache and silhouette-first crossfade already solve this. Review rule: **never instantiate a live map or an un-downsampled image per row.**
5. **Design-law drift** — media-first pulls toward decorative colour and elevation. One warm accent (`Theme.like`), iridescence only on the PR banner, `Theme.purple` only on the Pro seal, zero radius and zero shadow on media.
6. **It costs v1 focus** — the solo pivot exists because retention, not virality, is the constraint. Keep P0–P1 behind a DEBUG arg.
7. **A follower-less feed has nothing in it** — make the empty state the default view with search prominent; don't paper over it with generated athletes (see risk 3).

---

## 9. Appendix — the profile grid (SHIPPED 2026-07-28)

Measured Instagram profile grid, live on 2026-07-28: tiles are **3:4** (changed from square in Jan 2025), gutter is **1.0px**, `border-radius: 0`, no borders/shadows, 3 columns on phone, edge-to-edge, and a single still photo carries **no overlay chrome at all**.

What we changed (`ProfileGrid.swift`, `ProfileScreen.swift`):

| | Before | After |
|---|---|---|
| Gutter | `Theme.Space.sm` (8pt) | **2pt** (`ProfileGrid.gutter`) |
| Corners | `Theme.Radius.card` (14pt) | **0** (`.clipped()`) |
| Border | `.stroke(Theme.hairline)` | none |
| Outer margin | 16pt | **edge-to-edge** (section rules keep their own margin) |
| Tile overlay | icon + distance + date on a 3-stop scrim | **the number only** |
| Press | `scaleEffect(0.97)` | **dim only** — a shrink opens a visible hole at a 2pt gutter |
| Sections | month rules ("JULY ─── 12") | **none** — one continuous mosaic |
| Tab bar → grid | 24pt + a phantom zero-height child eating another 24pt | tight |

**Aspect ratio was already correct at 3:4.** The tile keeps its number (owner call) because a photo grid can be text-free when the photo *is* the content — here most tiles are grey route lines, and without the number a 3-mile shakeout and a 20-mile long run are the same picture.

**Gotcha worth keeping:** removing the scrim broke legibility, because the tile ink now has to survive five canvases. `RouteSnapshotter.tileStyle == .light` — snapshots are baked on a **light** basemap in *both* appearances (route colour resolved against the light trait so a dark-mode phone never persists dark ink), while muscle/silhouette/glyph sit on Theme tokens and *do* follow the appearance. So `Theme.ink` over a snapshot flips to near-white in dark mode and vanishes. Fix: `WorkoutTileMedia` reports which canvas it drew via `onInkContext` — `.fixedLight` → `Theme.inkOnFixedLight`, `.appearance` → `Theme.ink`, `.photo` → white + halo. It re-reports if the async snapshot heal swaps the canvas, so a static "does it have a snapshot" check is *not* sufficient.

---

## 10. App Store screenshot recipe (profile grid)

```
xcrun simctl launch <udid> com.ephraimbel.momentum.app --seed-demo --marketing-profile --profile-tab
```

`--marketing-profile` (`DemoSeed.seedMarketingProfile`) is the established full-account seed: 208 workouts / 1650 mi, 20 featured runs on **real bundled city street-loops** (Austin, SF, Boston, NYC, Vancouver, London, Sydney), strength sessions interleaved so the mosaic alternates route maps and muscle maps.

**Two gotchas that make the shot non-deterministic:**

1. **`WorkoutSnapshotHealer.sweep` renders only 12 snapshots per launch** (default `limit`, and `RootView` uses the default). On a fresh install the top rows come up as bare silhouettes. Relaunch 3–4× — snapshots persist to `gps.mapSnapshotData`, so they accumulate — then shoot.
2. **PRs used to read 0.** `RecordsBook.backfillIfNeeded` was called from exactly one place, `ProgressView`, so the record book only existed if you'd visited Progress. Fixed 2026-07-28 — it now runs from `RootView`'s cold-launch block (one-shot, versioned flag, deduped per (type, workout)). The trio reads **32 PRS**. This was a real user-facing bug, not just a demo one: anyone importing history from Apple Health and going straight to Profile saw a flat zero.

### Why the tiles are NOT varied basemaps

Asked for, investigated, declined — three independent reasons:

1. **It was already tried and rejected.** `RouteSnapshotter.swift:20-25` (v4, 2026-07-24): *"on the colorful Standard/Streets basemaps the pastel trace drowned under restaurant pins and street colours ('tacky'), so the card renders on the clean canvas where the route reads like a Strava card."*
2. **It breaks the tile-ink contract.** `WorkoutTileMedia` maps `.snapshot → .fixedLight`, which `ProfileGrid` resolves to `Theme.inkOnFixedLight`. If snapshots could be dark (satellite/dark), the metric number goes dark-on-dark — the exact bug fixed on 2026-07-28. Varied basemaps is not a one-constant change.
3. **Dusk/Night can't even be baked.** `RouteSnapshotter.snapshot` never sets `lightPreset` on the basemap import, so those styles resolve to Standard *day*.

The grid already reads varied because the **routes** differ (real loops in seven cities), which is the honest kind of variety.

**If more richness is wanted, photos are the lever, not basemaps.** Neither seed inserts a single `WorkoutPhoto`, so the mosaic has no full-colour tiles at all — that, not basemap uniformity, is why it reads monotone next to Instagram. Adding a handful of run photos to the marketing seed would change the grid more than any style work, and it's honest (athletes really do attach photos).

**Worth knowing:** `CardioSaveView` already shows a per-run map-style picker and writes `gps.mapStyleRaw` — but every snapshot writer passes `RouteSnapshotter.tileStyle` unconditionally, so that stored choice is currently **cosmetic bookkeeping the tile ignores**. Honouring it would be the honest route to a varied grid (a real user could reproduce it), but it lands squarely on gotchas 1–3 above.

### Update 2026-07-28 — per-run basemaps SHIPPED (reverses the "not varied" note above)

Owner call. `RouteSnapshotter.renderVersion` → **5**: a route card bakes in **the style its run was saved with** (`gps.mapStyle`); `tileStyle` (Light) is now only the floor for a run with no style at all.

This made an existing shipped control real. `CardioSaveView`'s map-style picker is Pro-gated and its doc comment promises the choice is *"saved with the workout (grid tile, History, feed post)"* — but `WorkoutSnapshotHealer.rerender(_:style:)` accepted the style argument and discarded it, rendering Light every time while stamping the choice onto the workout. Someone could pay for map styles and see no change anywhere but the live preview.

**Tile ink follows the canvas** via new `MapStyleOption.bakesDarkCanvas` (dark / satellite / standardSatellite → white + halo; the rest → `Theme.inkOnFixedLight`). Dusk and Night are deliberately *not* dark-canvas: a `StyleURI` can't carry the Standard light preset, so they bake as Standard **day**.

**Two overwrite bugs surfaced doing this — both would silently flatten a varied grid:**
1. `WorkoutSnapshotHealer.healIfNeeded` rewrote `mapStyleRaw` unconditionally. Healing is about a *missing image*; restating the style meant a tile that healed before its style had been saved wrote the app-wide default back over the real pick. Now stamps only when nil.
2. **`seedMarketingProfile` has its own snapshot pass** at the end, separate from the common `--seed-demo` one — edit *both*. It hardcoded `.persisted` + `tileStyle` and wrote that back, flattening precisely the newest 22 runs (the entire visible grid) while everything below stayed varied. That's why the deep grid looked right and the top didn't.

`DemoSeed` now hand-places an `opening` sequence (standard · satellite · dark · outdoors · streets · 3D satellite) so the first screenful reads varied, with a 7-long `cardStyleRotation` for the rest — 7 against 3 columns never lines up into stripes.
