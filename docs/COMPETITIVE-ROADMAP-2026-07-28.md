# Competitive roadmap — 2026-07-28 (rev. 3)

> **Historical plan, superseded for implementation on 2026-09-01.** The active program is
> [`ELITE-RUNNING-SYSTEM.md`](ELITE-RUNNING-SYSTEM.md). In particular, every Health workout-import
> proposal below is retired by the 2026-08-15 signals-only owner decision and must not be implemented.

> **Status: PLAN ONLY. Nothing here is built.** Supersedes
> [`RUNNA-COMPETITIVE-ROADMAP.md`](RUNNA-COMPETITIVE-ROADMAP.md) (2026-07-06), whose entire P0 —
> structured workout model → guided in-run runner → Watch guided run (`:95-108`) — has since shipped.
>
> **Method.** Two passes: a codebase audit plus competitor research, then an adversarial red team of the
> result, then a fact-check of every citation against the tree. Every claim about our own code is cited
> to a file and line and listed in **Appendix A**; every market claim is listed in **Appendix B** with its
> sourcing status. Findings already shipped, or violating a stated principle, were dropped.
>
> **What the passes changed.** Pass 2 found three load-bearing errors (a headline slice that could not be
> built, an elevation source that does not exist, a market thesis that ignored that Strava has owned
> Runna since April 2025), one entirely new item (**T0.0**) that six others silently depended on, and a
> live data-loss path in shipping code (**W0.1**). Pass 3 checked 1,493 discrete claims and corrected 93,
> including a false impossibility proof used twice (HealthKit *does* carry laps), a race-week item scoped
> on a premise that was already false, and a `Workout.route` property that does not exist.

---

## TL;DR — the thesis

**Our engines have out-run our surfaces.** Nine finished, tested capabilities — five engines and four
computed values — reach zero or one pixel:

| Capability | Production reach | What's trapped |
|---|---|---|
| `GradeAdjustedPace` | **0 call sites** | Minetti's curve. Every hilly run is silently reported as a slow one. |
| `guideRoute` follow stack | **0 producers** | Dashed guide layer, off-route hysteresis, rejoin bearing, "· your loop" — built, tested, dead. |
| `RouteMatch` | **1 call site** | One sentence in the post-run summary. No route entity, no naming. |
| `CoachRacePlan` | **1 call site** | Five race sections, auto-seeded into chat only in the final 4 days; no Plan-page surface. |
| `PodiumOutlook` | **2 call sites** | Both in onboarding. Shown once in a lifetime, never re-run against improving fitness. |
| `NorthStarFunnel` (read side), `isManualTrim`, `LiveSnapshot.elevationGainM` | **0** | Computed and discarded. |
| `MetricsMonitor` | **1, no sink** | Started at `MomentumApp.swift:68`; MetricKit crash/hang/launch data goes to `os.Logger` and nowhere else. |

**Eleven of the seventeen T0/T1 items are surfacing rather than inventing** — T0.1, T0.2, T0.3, T0.4,
T1.1, T1.2, T1.3, T1.4, T1.5, T1.6, T1.9. Six are genuinely new: T0.0, T0.5, T0.6, T0.7, T1.7, T1.8.
(T2 craft, map and design refinements are excluded from that ratio; counting them would flatter it.)

**But that thesis had a floor missing under it.** All of that computation runs on per-fix GPS geometry,
and `HealthService.assembleImport` (`:388-409`) builds an imported workout carrying `distanceM`, one of
avg pace/speed, and `avgHR` — **and not one coordinate**. For a Watch or Garmin run, `RouteMatch` has
nothing to trace, GAP has no altitude, Trim has no line to drag, the GPX writer has nothing to write, and
the heatmap bins nothing. An unsourced pass-1 estimate puts those at the majority of our target athlete's
runs; Appendix B carries a competing unsourced figure pointing the other way, so **source one or soften
both**. Either way **T0.0 fixes it with first-party Apple API, and six other items depend on it — T0.1,
T0.2, T0.6, T1.5, M.1 and M.3.** T0.0 is cheap enough to build before the estimate settles; T0.1's gating
metric is what settles it.

**The moat, stated correctly.** The moat as the positioning docs define it — the deterministic plan,
recovery-aware adaptation, the injury loop, honest verdicts — **already ships and is already visible**
(rationale lines at `TodayView.swift:576`, `PlanView.swift:877`, `SessionDetailSheet.swift:59`;
`RecoveryAdaptation.tripwire/decide` at `TodayView.swift:457-463`; the Athlete Model rendered by
`ProgressView.athleteStory:1756` with three-pip confidence and correction-sticks-visibly behaviour). Two
things this product *promises* are not yet behaviours: **continuity** (a new phone wipes everything) and
**route identity**. Route identity is a **new wedge**, not part of the stated moat — do not amend a
positioning doc from a roadmap.

---

## §0 — Who we are actually fighting

**Strava owns Runna** (April 2025; bundle $149.99/yr, annual-only — App. B). Pass 1 built several "why it
wins" arguments by pitting Runna's weakness against Strava's weakness, which is a gap inside *one
company's portfolio*, closable by a bundle they already sell. Restated honestly it is a **stronger**
sentence: one company refused a subscriber's export, paywalled its API, and paywalled Year in Sport after
nine free years. That is a posture, and postures are what people leave. **Bundling risk applies to T0.1
and T1.3** — the two items whose argument genuinely pairs the two halves.

**Apple is the platform owner and was missing entirely from pass 1.** watchOS 26 shipped **Workout
Buddy** — Apple-Intelligence-generated real-time spoken coaching during an Outdoor Run, free. A
**Health+** AI coaching product is *reported* for 2026 (**unconfirmed**) — inside this plan's execution
window. This narrows one claim and must be named:

- **T0.3's absolute claim is wrong as written.** Rewrite: the one live coaching act that enforces a
  *prescription*. Workout Buddy motivates off your history and has no plan to hold you to; it needs an
  Apple-Intelligence iPhone, a Watch and headphones. **Ours needs a phone and any HR source — including
  the Watch the athlete already owns — and it holds you to a prescription rather than narrating your
  history.**
- **What survives if Health+ ships:** the deterministic engines, plan authorship, route identity, export,
  and the no-shame constraint Apple will not adopt. Health+ is the largest platform risk to the Pro
  *narration* layer, not to the engines.

**Durability tags.** Every **T0** item is tagged **perishable** (a competitor choice or a regulation
closes it) or **durable** (the lead comes from accumulated athlete data); T1 items inherit the tag of the
wedge they defend. Tags set *urgency* in the cut line — never value.

---

## The sentence this release is trying to earn

> *"It's the only one that tells you the hill was real, stops you running your easy runs too hard, doesn't
> lose anything, and lets you take everything with you when you go."*

Written down, dated, so it can be checked against what ships. **The loop-counting clause — "counts the
loop you actually run" — is earned in R3**, and is deliberately not in the sentence the committed
releases must deliver.

Seven of T0's eight items sit behind the hard paywall and so cannot decide a download directly; T0.7 *is*
the wall, and T0.4 is the one that points outward. **T0's job is the recommendation sentence and the
first-session save.**

Inline tags: **T0.0** wedge (durable) · **T0.1** wedge (durable) · **T0.2** parity number, wedge framing
(perishable) · **T0.3** wedge (perishable) · **T0.4** channel defect (durable) · **T0.5** table stakes
(perishable) · **T0.6** independence window (perishable) · **T0.7** solvency (durable).

---

## Metrics — what the labels mean

Every T0/T1/T2 item and W0 item carries a **Reads as success when** block using one of three labels.
`M.*` and `D.*` are acceptance-criterion items and carry no metric block.

- **Gated** — a bad reading stops named downstream work. The block must name what stops.
- **Health check** — an existence check or a zero. Never a usage target; low usage can be a valid outcome.
- **Compliance** — a standard, not a metric.

**Until T1.2's billing join lands, no benchmark quoted in this document is measurable.**

---

## Capacity, cut line and releases

**Capacity assumption.** One AI-assisted builder. Waves are **strictly sequential**; "in parallel" means
alternating, not concurrent. Size legend calibrated from this repo's own velocity (**528 commits from
2026-06-09 to 2026-07-28**, one committer under two git identities, in a window containing five tabs,
~20 tested engines, a watch app, widgets, the Fuel pillar and an App Store submission) — **not** industry
day-rates, which would manufacture precision no source supports:

`S` ≤ 2 days · `M` ≈ a week · `L` ≈ 2–3 weeks · `XL` multi-week with schema and back-end change.

| Release | Target | Theme | Contents |
|---|---|---|---|
| **W0** | this week | Safety and measurement | W0.1 quarantine · W0.2 prove it · W0.3 `syncedAt` edit bug · the `ShareLink` line (both share paths) · T1.2 instrumentation + the RevenueCat join · T1.7 notification preferences · the AI Act disclosure line · the stale `Theme.Elevation` comment |
| **R1 · v1.2** | ~2026-10-10 | *Don't lose anything, and stop lying about hills* | T0.0 route import · T0.2 GAP · T0.3 parts 1–2 · T0.6 export · T0.5 lap · T1.8 Phase A0/A · T2.2 contrast |
| **R2 · v1.3** | **before 2026-12-01** | *Every run counts, and it's yours* | T0.7 the wall · T1.1 Week One · T1.9 annual · T1.8 Phase B/C · T1.3 Sunday review · T0.4 card types · **D.3 masthead → T1.10 four-tab bar + action button** · T2.5 accessibility · M.6 legibility matrix |
| **R3 · v1.4** | 2027 spring marathon season | *The route story* | T0.1a "Run it again" · T0.1b route library · T1.6 race week · T0.3 part 3 · T1.7 lapse ladder · map items |
| **R4 · v1.5** | after R3 | *Fix your own data* | **T1.5 Trim, alone**, with `RecordsBook.recompute` in the same PR |
| **R5 · v1.6** | after R4 | *Life happened* | **T1.4, alone** |

> Craft (`T2.*`) and design (`D.*`) items are not scheduled as a wave; they land alongside the release
> that touches their surface. Only the two with hard dependencies are placed: T2.2 (before the card
> sweep) and T2.5.

> **R1's date assumes W0 and R1 overlap despite the strictly-sequential rule.** By the size legend, W0 is
> ~2 weeks and R1 has a floor of ~6–7 sequential weeks. If they do not overlap, R1 lands later — or cut
> T1.8 Phase A0/A into R2 and say so.

> **The January constraint is hard.** January is the category's peak acquisition month. Week One, the
> wall, and T1.2's billing join must be **done before 2026-12-01**, which leaves December for store
> review and the holiday freeze.

**The cut line.** W0, R1 and R2 are committed. Everything in R3, R4 and R5 is **deferred and
uncommitted**. Perishable items are pulled forward — T0.2, T0.5 and T0.6 all land in R1. T0.3 part 3 is
the one perishable item we accept deferring, because it is gated on HR confidence we do not yet have.

**The eight-week fallback**, if only one wave survives, is these six items and nothing else: the
`ShareLink` URL, T1.2 with the RevenueCat join, W0.1, T0.0, T0.2, and T0.6's `GPXWriter` plus the
per-workout export row.

**R4 and R5 exist because of the rollback gate** (Engineering gates §4): T1.4 has the highest blast radius
in the plan and T1.5 rewrites the sample-read path across nine production sites. Three extra submissions
is the price of a targetable revert. If that price is too high, relax the gate explicitly — do not let it
erode by scheduling.

---

## The one strategic question this plan does not settle

Two independent red-team lenses converged on the same argument, and it is the owner's call.

**The case:** the only asset here that cannot be bought, copied or shipped by Strava in a quarter is the
**Athlete Model** — a persistent, correctable, confidence-scored memory of one athlete. Copying it
requires eight weeks of a specific person's training, not eight weeks of engineering. The bet: make the
memory the product, put it at the centre of the post-run moment and the Sunday review rather than a
Pro-locked sub-segment of the third tab, sell *"by week eight it knows how you actually train"* as the
store subtitle — and then confront what that implies, which is that a hard paywall on day zero charges
for a relationship that does not exist yet.

**The counter, which is factually correct:** the surface already ships. `ProgressView.athleteStory`
(`:1756`) renders `growthCard` (before → after receipts), `coachMoves` (what the coach changed) and
`coachKnows` (labelled beliefs with three-pip confidence, where a user correction hides the derived card
so the correction visibly sticks). Building it again duplicates shipping code.

**My read:** both are right about different things. The *surface* exists; the *positioning* does not, and
the surface sits behind a Pro lock on the third tab. The cheap version is adopted here — T1.3 re-surfaces
tenure weekly, T0.0 makes the memory feed on every run rather than a minority. The expensive version —
reframing the paywall around the moment the app first proves it learned something — is **not** adopted,
because it reopens a hard-gate decision made on 2026-07-28. It belongs in its own decision, with T0.7's
data in hand.

---

## W0 — this week: safety and measurement

*Two of these are not features. They are the floor under everything else.*

### W0.1 · Quarantine The Store, Never Destroy It  `[S]`

**Problem.** `PersistenceController.swift:29-45` builds a bare `Schema(Self.models)`. There is **no**
`VersionedSchema`, `SchemaMigrationPlan` or `MigrationStage` anywhere in the tree — verified, zero
matches — despite the file's own header (`:5`) claiming *"Schema is versioned (`SchemaV1`) for lightweight
migration."* On any container-open failure the catch block calls `destroyStore(at:)` (`:40`), deleting the
store and its `-wal`/`-shm` sidecars, justified by a comment (`:38-39`) reading *"for a first release with
no migration history, essentially can't lose real data."* **That stopped being true at v1.1 build 11.**
There is no restore path and no support channel, so the failure mode is silent, total, permanent loss for
a paying subscriber — and this roadmap proposes five model changes on top of it.

**Build.** Replace the blind destroy with quarantine-and-report; delete two false comments; write the
additive contract down.

- On the retry path, rename the store aside with an ISO timestamp (`momentum-quarantined-<t>.store` plus
  sidecars) rather than deleting it. Launch empty, set a flag.
- One row in Settings → Data & privacy — *"We couldn't open your training data"* — exposing the
  quarantined file through the existing `fileWrapper`/`ShareLink` path so it is recoverable by hand.
  **Never red, never a modal on launch**: a corrupt store is not the athlete's fault, and a launch-time
  alert on a broken app is a trap.
- Fire `store_quarantined` through `AnalyticsSink` so it is countable rather than invisible.
- Delete the false `SchemaV1` header claim and the "no migration history" comment in the same commit.
- **Write the additive contract into the doc comment**, citing the shipped precedent:
  `LocationSample.pausedSpan` (`Workout.swift:133-139`) was added post-release as *"additive-only
  (defaults false, so pre-2026-07 rows read as 'never paused')"* and needed no `VersionedSchema` —
  exactly the shape T1.5's `trimmed`, T0.5's `isManual`, T0.2's `gapSPerKm`, T0.0's `importedFrom` and
  `SavedRoute` need. `VersionedSchema` arrives with the first **non-additive** change, which on this
  roadmap is T1.8's `updatedAt`/`deletedAt` sweep.

**Reads as success when:** `store_quarantined` is observable at all, and zero users report unrecoverable
loss. *Health check — a zero here is the goal.*

---

### W0.2 · Prove It, And Let Them Tell You  `[S]`

**Problem.** `MetricsMonitor` subscribes to MetricKit and writes crash, hang and launch data to
`os.Logger` and nowhere else — its own doc comment says *"forwarded to a dashboard later"* — while a live
`AnalyticsSink` sits directly beside it. So the PRD's own quality bars (crash-free > 99.5%, cold start
< 2 s) are **unverifiable in production**. Separately there is no in-app contact route: grep for
`mailto|support@|contact` in `Features/Settings/` returns nothing — on a plan that weaponises *"Runna
support told a subscriber they do not have the ability to export his history."* A stuck user's only
channel today is a one-star review.

**Build.** Two rows and three events, all inside T1.2's payload discipline.

- Forward MetricKit through the sink as `quality_bar(crashes:hangMs:ttfdP90Ms:)` plus `app_crash` and
  `cold_start_ms` — counts and latencies only.
- Settings → Data & privacy gains a **Contact** row (mailto, with a stated first-response window).
- `renewal_off(reason:)`: a one-shot, dismissible four-option picker fired when `customerInfoStream`
  first reports an active entitlement with `willRenew == false`. **That is the only moment the app can
  observe a cancellation** — App Store cancellation happens in the system sheet with no in-app hook — and
  it replaces the borrowed "38% lost motivation" benchmark with an owned number *before* T1.7's ladder is
  tuned against it.
- `account_created` / `account_skipped`, which T1.8 Phase C is gated on.

**Reads as success when:** the crash-free rate is readable from our own table, and `renewal_off` has
enough responses to rank cancel reasons before T1.7's ladder is designed. *Gated — if cancel reasons are
dominated by something this plan does not address, the ladder is re-scoped before it is built.*

---

### W0.3 · The `syncedAt` edit bug  `[S]`

Exactly one code path clears `syncedAt` — `FinishedWorkoutReader.commit(_:)` (`StrengthSaveView.swift:197-206`,
the write at `:205`) — and both the cardio and strength save screens already route through it
(`CardioSaveView.swift:308`). **The gap is `TimedSaveView.swift:152-155`**, which writes title/note/effort
and calls `context.save()` without re-dirtying, so a timed-session edit **never re-uploads**. One line
there. A prerequisite for T1.8 meaning anything.

**Reads as success when:** every edit path re-uploads — a fixture asserts `syncedAt` is nil after a
cardio and after a timed title/note/effort edit. *Health check.*

---

## T0 — the wedge

### T0.0 · Import The Route  `[M]` · wedge · **durable** · *hard prerequisite for T0.1, T0.2, T0.6, T1.5, M.1, M.3*

> The item our Strava red-team lens said would be the only one they would have to answer, and the one
> pass 1 missed entirely.

**Problem.** `HealthService.assembleImport` (`:388-409`) builds a `GPSDetail` carrying `distanceM`, one
of `avgPaceSPerKm`/`avgSpeedMS`, and `avgHR` — **and inserts no `LocationSample` at all**. `readTypes`
(`:38-40`) never requests `HKSeriesType.workoutRoute()`. So for a Watch or Garmin run, four tiered items
and two map items silently do nothing, and pass 1 never said so once. The verification appendix compounded
it: the row "no `HKWorkoutRoute` anywhere" was scoped to `Momentum/` and missed
`MomentumWatch/WatchCardioModel.swift:146`, which already requests `HKSeriesType.workoutRoute()` and
drives `HKWorkoutRouteBuilder`. **Our own watch already writes routes into Health. The phone has never
read them back.**

**Build.** Read `HKWorkoutRoute` on the import side — the exact mirror of T0.6's step zero, same Apple API
family from the other direction.

**Design.**

- Add `HKSeriesType.workoutRoute()` to `readTypes` (HealthKit re-prompts only for newly added types;
  existing grants persist).
- Per imported `HKWorkout`, run an `HKWorkoutRouteQuery` with `HKQuery.predicateForObjects(from:)`,
  stream the returned `CLLocation`s through **the same accept gate live capture uses**
  (`horizontalAccuracy ∈ (0,25m]`, newer timestamp), persist as `LocationSample`s **sorted by `t`** — so
  `GPSDetail.routePoints` stays the one canonical reducer on both sides. Skip silently when a workout
  carries no route series.
- **Do not recompute `distanceM` from imported geometry.** HealthKit's `totalDistance` is the recording
  device's own figure and is more accurate. Keep the imported scalar as the truth and use geometry for
  **shape only** — or the imported distance starts disagreeing with Health and with the athlete's watch.
- **Provenance:** an `importedFrom` value on `GPSDetail` (additive, nil-defaulted), carried forward so
  imported geometry may feed the heatmap, route identity, GAP and export but **must never re-mint a
  record** already set from the imported scalar, and must not feed pace recalibration — the same rule
  T0.6 states for imported courses.
- **Bounding is not optional.** The first Health sweep reads a year (`:321`), so route materialisation
  must be a bounded, idempotent, no-user-action pass in the *shape* of `WorkoutSnapshotHealer.sweep`
  (`:61`) — with the deltas stated explicitly: **≤40 per launch** where the healer does 12, **oldest
  first** where it is newest-first (`:62`), and **off the main actor** where the healer is `@MainActor`
  (`:13`) because it drives Mapbox.
- **What this does not solve today:** HealthKit **does** carry laps (`HKWorkoutEventType.lap`, written
  with `HKWorkoutBuilder.addWorkoutEvents`, read from `HKWorkout.workoutEvents`), but nothing we import
  from is known to populate it and our own watch does not write it. **T0.5 is phone-only until a producer
  writes lap events, not by construction.**

**Why it wins.** This stops momentum being a recorder competing with Garmin's recorder and makes it the
**training brain for athletes who never change how they record**. Strava and Runna both need you to record
with them, or accept a thin import with no geometry. A Garmin, COROS or Apple Watch athlete who connects
Health gets a full route library, honest verdicts, grade correction, a heatmap of their own city and GPX
export — on a device we do not own and a subscription we do not sell. It is also the on-ramp pass 1
asserted and never built.

**Reads as success when:** ≥70% of imported GPS workouts land with usable geometry, and the share of
route-matched runs among Health-connected athletes rises. *Gated — if geometry arrival is low, T0.1b's
library is not worth building and stops.*

---

### T0.1 · Your Loops  `[XL]` — T0.1a `[M]` + T0.1b `[L]` · wedge · **durable**

**Problem.** `RouteMatch` is the best-reasoned engine in the tree — 219 lines, 43 tests, three documented
load-bearing invariants — and its entire output is one sentence that scrolls past once
(`CardioSummaryView.swift:193`, the only call site). There is no Route entity and no naming — **the count
itself already ships inside the verdict sentence** (`RunVerdict.swift:192`, `:227`), which is precisely
why the library is a surfacing job. Separately the whole follow-a-route runtime is built and
shipping-dead: the dashed guide `LineLayer` (`CardioTrackingView.swift:290`), `RouteDeviation`
nearest-point + rejoin bearing with 35 m/20 m hysteresis (`:449`), the rotating banner and the " · your
loop" suffix (`:726`) — and all five producers pass `guideRoute: []` (`TodayView.swift:532/539/1520/1531`,
`PlanView.swift:218`).

#### ⚠️ Correction — the original slice 1 cannot be built

`RouteMatch.context(for:gps:priors:)` (`:191-194`) takes a **completed** `Workout` plus its `GPSDetail`
and bails at `guard todayTrace.count > 1`. All five `guideRoute` producers fire **before a trace exists**,
and no engine ranks prior runs as candidates to *go and run*. **Slice 1 was missing a selection surface,
not a persistence layer.**

**T0.1a · Run It Again** `[M]` — a "Run it again" action in `WorkoutDetailView`'s toolbar on any completed
GPS workout, building `RouteMatch.trace(gps)` (raw accepted fixes sorted by `t`) and handing it to the
`.cardio(…, guideRoute:)` launch enum. **Geometry is unambiguous because the athlete picked the run.** If
a Today-deck entry point is wanted in the same slice, add one explicit chooser sheet listing recent GPS
runs of the same discipline within `RouteMatch.withinDistanceTolerance` of today's prescribed distance —
never an implicit "your last GPS run", which hands a runner the wrong loop most of the time. The four
Today/Plan producers keep passing `[]` until a route is chosen.

**T0.1b · The route library** `[L]` — ships **after T0.0**, because a library assigned only from
phone-recorded runs is near-empty for the athlete pass 1 called the majority, and an undercounting "ninth
time on this loop" is a no-shame violation on an honesty-positioned product.

**Design.**

- **Model** (`Momentum/Models/SavedRoute.swift`): `id`, `name: String?`, `isCustomName`, `createdAt`,
  `typeRaw`, `distanceM` (which **is** the auto-name distance, rendered through `Formatters`),
  `autoNameWeekday: Int?`, `isLoop`, `geometryData`, `snapshotData`, `snapshotVersion`, plus denormalised
  `outingCount`, `lastOutingAt`, `bestDurationS` with the assignment engine named as the **single
  writer**. Mark both blobs `@Attribute(.externalStorage)` so the History rail's existence gate does not
  fault a ~100 KB PNG per row. Every property defaulted → additive migration under W0.1's contract.
- **The relationship, specified.** On `Workout`, declare `var route: SavedRoute?` — **it does not exist
  today.** On `SavedRoute`, declare
  `@Relationship(deleteRule: .nullify, inverse: \Workout.route) var workouts: [Workout] = []`. Name
  `inverse:` on the `SavedRoute` side **only** — naming it on both sides, or pointing it at a property
  that does not exist, fails to compile.
- **⚠️ Architectural decision 1 — store geometry, not cells.** `RouteMatch`'s first invariant is that
  every signature in a comparison shares **one** reference latitude taken from the run being judged. A
  cell set persisted at another run's refLat lands on a misaligned grid and silently never matches again.
  Store the line and recompute `RouteMatch.signature` at *today's* refLat on every comparison.
- **Geometry type, settled.** Store `geometryData` as `[[lat, lon]]`. `RouteMatch.trace` returns
  `[GeoPoint]` (`:182-184`) and `GeoPoint` carries `lat`/`lon` and nothing else (`GeoPoint.swift:7-9`);
  `MapMatchingService.downsample` takes `[CLLocationCoordinate2D]` (`:107`), so convert at the downsample
  edge. `SavedRoute` therefore carries **no altitude**, and ClimbPro stays killed (see Kill list). If
  altitude is ever needed, add a second builder over `routePoints` at that point, accepting that it is a
  Kalman pass and not a raw-fix map. **The matching trace stays raw** regardless.
- **⚠️ Architectural decision 2 — the auto-name violates a standing non-negotiable if stored as text.**
  CLAUDE.md: *"SI units stored everywhere; convert only at display time"*, and `DistanceUnit.auto`
  resolves from `locale.region` at call time (`Formatters.swift:4-14`). Persisting "5 mi loop"
  permanently mislabels the library after travel, a locale change or a Settings flip. Store the
  components; render through `Formatters` at read time; persist `name` **only** when
  `isCustomName == true`. Fixture: one stored row reads "5 mi loop" under imperial and "8 km loop" under
  metric.
- **Auto-name grammar** — deterministic and offline, **never reverse-geocode**. Base form "5 mi loop";
  upgrade to "Tuesday 5 mi loop" once there are ≥3 outings and ≥60% share a weekday; collisions take a
  trailing ordinal; a manual rename sets `isCustomName` and freezes the namer.
- **Engine** (`RouteLibrary.swift`, pure + fixture-tested): `assign(todayGeometry:distanceM:candidates:)`
  gating every candidate on `withinDistanceTolerance` **before** building its signature, through the same
  code path as `RouteMatch.matches` so the two cannot drift. **Tie-break:** highest mutual coverage wins;
  ties go to the oldest route; routes created inside a backfill batch join that batch's candidate set.
- **Write path**: `WorkoutRunner`'s deferred post-celebration block after map matching settles. Snapshot
  via `RouteSnapshotter` at 660×440. Launch backfill borrows the *shape* of `WorkoutSnapshotHealer.sweep`
  with the same three stated deltas as T0.0 (≤40, oldest-first, off the main actor). Counts are
  honest-but-partial until backfill converges; the verdict sentence is unaffected because `RouteMatch`
  computes it live at summary time.
- **Summary hook**: the `RunVerdict` line becomes a `Button` when `workout.route != nil` — identical
  typography plus a trailing 11pt `chevron.right` in `inkTertiary`. The sentence becomes a door.
- **Route sheet** (`.large`): `RouteMapView` at 240pt (this is how the athlete recognises *which* loop —
  the sheet's first job) → editable name in `.display(26)` (**not** `weight: .black` —
  `BrandFont.spaceGrotesk` collapses black/heavy/bold/semibold to one cut, `Typography.swift:39-41`, so
  the weight is inert) → four-stat row (`N times · X total · best T · last T`), all `.monospacedDigit()`
  → outings dot plot **gated at ≥5 outings**, with a two-line best/last pair below that; x = date, y =
  pace **inverted so faster is up**; fastest outing as a **filled iridescent dot with a monochrome halo**
  → per-outing rows → footer `OversizedButton` **"Run it again"**.
- **No-shame floor**: never render "slowest", never rank against anything but your own best, **no trend
  line** — a downward-sloping fit through a bad month is a verdict nobody asked for.
- **History rail**: 150×190 snapshot cards beneath `HeatmapHistoryCard`, gated at ≥1 route with ≥2
  outings, built in `.task(id: workouts.contentSignature)` with a static session cache.
- **Follow behaviour**: pass `route.points` straight through — `syncRouteLayers` already maps it. Banner
  copy stays as written ("Off the loop" / "40 m — head this way to rejoin"), one `Haptics.light()` on
  entry only, never on exit; past 400 m off for 90 s the guide fades to `lineOpacity` 0.12 and retires for
  the session — they changed their mind and the app should stop arguing.

**Why it wins.** Strava's Matched Activities is subscriber-gated, buried on a secondary page, rendered as
a speed scatter with a yellow dot for the PR, and **it never speaks**. Our ladder already produces the
quotable sentence and already computes a comparison Strava does not make at all — same road, three fewer
beats, same pace. Strava shipped off-route alerts only in June 2026, paywalled, route-scoped rather than
region-scoped (App. B). Everyone else's route features are downstream of a routing API; ours is downstream
of a run you already did, so there is nothing to author. And it is the only "segment" mechanic that
survives the no-shame rule, because the field is you.

**Reads as success when:** among athletes with ≥5 GPS runs, ≥40% have at least one route with ≥3 outings,
and ≥25% of them open the route sheet at least once. *Gated — below that, the History rail and the follow
guidance are not extended further.*

**Blocker.** `RouteMatch.swift` and its three test files are **untracked** on `feat/route-suggestion`.

---

### T0.2 · The Hill Was Real  `[M]` · parity number, wedge framing · **perishable**

**Problem.** `GradeAdjustedPace` implements Minetti's cost-of-running curve, is unit-tested at
`RunningScienceTests.swift:55-72`, and has **zero production call sites**. Every cross-terrain pace
comparison runs on raw pace, so a runner whose routes roll is systematically told they got slower — on an
app whose coaching posture is no-shame. `ProgressView.swift:1045` concedes the gap in copy without fixing
it.

#### ⚠️ Four corrections

1. **The EMA series does not exist.** `GPSProcessor.smoothedAltM` is a `private var` running scalar with a
   local `alpha = 0.3` (`:70`, `:190-192`), never persisted, never exposed; `RouteReplay` builds
   `RoutePoint(altitudeM:)` **raw** (`:103/:119`). Rewrite: re-apply the altitude EMA over `routePoints`'
   raw altitudes inside the new adapter, hoisting `alpha` into a named constant both the live hysteresis
   and the post-run adapter read. The EMA is causal and stateful, so **replay is deterministic only if
   input order is fixed** — sort by `t` and **reset the smoother across a `pausedSpan` gap** exactly as
   `GPSProcessor.swift:150-152` does on manual pause, or a car-park pause injects a phantom step.
2. **The distance ladder is deliberately geometry-free.** `RunVerdict.Run` carries date/distance/duration/
   avgHR only, and `CardioSummaryView.swift:189-192` states that intent verbatim. Computing a prior's GAP
   would fault that workout's `samples` and run a full Kalman smooth **on the main actor at the finish
   line**. Instead: persist `gapSPerKm: Double?` on `GPSDetail` (additive, nil-defaulted), written once in
   `finishWorkout` beside `persistSplits`, healed for old rows by a bounded launch sweep;
   `RunVerdict.Run` gains an optional `gapSPerKm`; the ladder uses it **only when both sides carry a
   stored value**, and priors without one are skipped rather than recomputed.
3. **The clamp rationale was wrong, and the descent is the real hazard.** Minetti fitted −0.45…+0.45, so
   ±0.30 is a noise guard, not a domain guard. `costRatio(−0.20)` = 0.50, which **doubles** the reported
   equivalent pace — rendering "GAP 11:24" under a raw 5:42 on a net-downhill run. That is a no-shame
   violation *inside the item that exists to fix one*. **Floor `costRatio` at 0.70** (`gapCostRatioFloor`)
   and state that GAP on a net-downhill run is capped.
4. `runGAPSPerKm` takes a **labelled** tuple array (`GradeAdjustedPace.swift:27`); Swift will not convert
   an unlabelled one. Write the labels into the signature.

**Design.** 100 m windows (`gapWindowM = 100`, a named constant, not inlined) with grade clamped to
±0.30; suppress entirely below 20 m total gain — a 3-second "correction" from noise is worse than silence.
The numeral renders `GAP 5:42` in `.rounded(Theme.FontSize.label, weight: .semibold)`, `Theme.inkTertiary`,
`.monospacedDigit()`, one step below the raw pace and **always beneath it, never replacing it** — the
clock is the truth, the adjustment is context. A 6pt single-hue grade ribbon under the elevation chart
(`Theme.Health.strainWash` at `washOpacity` for climbs, `Theme.hairline` for flat, nothing for descent — a
second tint for descent creates the two-tint chart the Health doctrine forbids). Monochrome, no
iridescence. Computed once in the existing `.task`-with-signature snapshot, never in `body`.

**Two abstentions, enforced in code, not just in copy.** (1) GAP never reaches `RecordsBook` — no record
is ever minted from a grade-adjusted number. (2) GAP feeds `RunVerdict`'s **distance** ladder only, never
the route ladder: `RouteMatch` matches by grid-cell footprint containment, so a matched pair ran the same
hills and terrain is already controlled by construction.

**Explainer**, three-part, with the honesty gate as non-negotiable copy: *"GAP is context, not a claim.
Your records, your splits and your plan credit all use the time you actually ran."* Extended by one
clause: *"GAP corrects for the hill, not the heat — wind, humidity and surface are not in this number."*

**Why it wins.** Strava and Garmin ship GAP as a bare number with no sentence attached; TrainingPeaks
calls it NGP and gets a different answer, and the cross-platform disagreement is a documented, live source
of runner distrust (App. B). Nobody shows their working. We can — and the part no competitor offers is an
explicit statement of what GAP does **not** do. Garmin's Hill Score exists precisely because
VO2max-derived numbers punish climbers: the incumbent conceding the same problem.

**Reads as success when:** GAP renders on every run with >20 m gain, and no run reports a GAP slower than
its raw pace, with the explainer reachable from it. *Health check — the value is that the app stops being
wrong. Explainer opens are reported for interest and carry no target.*

---

### T0.3 · Easy Means Easy  `[L]` · wedge · **perishable**

**Problem.** The loudest technical criticism of Runna is that it prescribes by pace and "completely
disregards" heart rate — an entire prescribed easy run in Zone 4 still grades complete. We stream live BPM
with a zone label (`CardioViewModel.swift:352` → `CardioTrackingView.swift:576`), render time-in-zones
afterwards, and never once say "this is a Z2 day." Worse, the estimate is uncorrectable: maxHR is only
ever Tanaka-from-birth-year (`OnboardingViewModel.swift:391-394`), and grep for `maxHR` across
`Features/Settings/` returns **zero**.

**Part 1 — Settings `[S]` (hard prerequisite for Part 3).** A "Heart rate" card between Preferences and
Apple Health with three rows — max HR, resting HR, LTHR — each showing the estimated value in
`Theme.inkTertiary` until overridden, under one card-level sentence: *"We estimated 187 from your age.
Correct it if you've tested."* **The editor:** a wheel picker per row with clamps (max 120–220, resting
30–110, LTHR strictly between), **no free-text field** — a mistyped 17 for 170 silently rewrites every
downstream prescription. Mount the existing five-row zone table (`ProgressView.swift:937-976`, Karvonen
when resting HR is known) as a live preview; **the mounted preview keeps its shipped
`MetricColor.zone(z.index)` chips — do not mandate monochrome here, the zone colours are the app's HR
vocabulary.** This one change silently upgrades every downstream zone prescription including
`SessionDetailSheet`'s `HRZones.target`. **Propagation rule:** future prescriptions and the live ceiling
recompute; already-logged time-in-zone stays as recorded; the change writes one rationale line rather than
moving history without a word.

**Part 2 — Summary `[S]`.** Extend `TimeInZonesCard` (already calling `ZoneDistribution.compute`) with one
sentence that **always leads with the positive share**: *"84% of this run stayed easy."* Flag
`Verdict.isTimeless` so history keeps it. No new card, no new bar.

**Part 3 — Live ceiling `[M]`.** On easy/long/recovery sessions only. Fires when HR sits above the
session's ceiling for a rolling 60 s, after a 5-minute settle. One calm glass banner in the `stepBanner`
slot (`momentumGlass` + `mapSafeTap`, ink on glass, one SF Symbol, no red) plus one `VoiceCoachService`
cue: *"Zone 3. Today is a Zone 2 day. Ease back."* **Capped at two cues per session** — a beginner cued
nine times in a 45-minute run is a no-shame failure on the app's most prominent new coaching act. Missing
or flatlined HR silently disables it. Copy is always an **instruction** ("ease back"), never a
**judgement** ("too hard").

#### ⚠️ Gate on HR confidence, not on ordering

Age-predicted max carries ±10–12 bpm of individual scatter — a whole zone. **Suppress the live ceiling
whenever either condition holds:** (a) max HR is still the Tanaka age estimate — the athlete has never
confirmed or edited it in Part 1; or (b) the athlete has ever recorded an HR at or above the stored max,
which is itself the signal the stored value is wrong.

> **Engineering note.** The pace-nudge path is gated on `let t = tracker`
> (`CardioViewModel.swift:299-305`) and `WorkoutRunner` only builds a structured workout for prescribed
> quality sessions — so easy runs have no tracker and no cue path at all. Part 3 needs a non-structured
> cue channel, which is why it is third and ships in a later release.

> **Explicit rejection.** Do not relight the on-pace iridescent border as an on-*effort* border for a
> whole easy run. A border lit continuously for 45 minutes is ambient decoration, not an earned accent.

**Also fix:** the zone chips carry white numerals at 13pt caption (`ProgressView.swift:947-963`) and **all
five fail AA** — 3.06 / 2.84 / 2.78 / 2.38 / 3.34 against `#FFFFFF`, where 13pt text needs 4.5:1. Set the
chip numeral to `Theme.inkOnFixedLight` on all five. **Do not** re-tune the five-band convention runners
read across every app — T2.5 depends on that table's current encoding.

**Why it wins (claim narrowed — see §0).** The one live coaching act that enforces a *prescription*. Runna
is pace-only and its own subscribers left over it — one ran 80% of his sessions in Apple Workouts purely
to get HR alerts, then cancelled, leaving Runna as "a logbook and AI interface"; the failure mode is what
physios are reported to be blaming weekly for stress fractures and Achilles tendinopathy (App. B). Garmin
has the zones but downgrades *tomorrow* rather than correcting *today*. Strava tells you after the fact.
Whoop never watches the run.

**Reads as success when:** Parts 1–2 — ≥25% of athletes with an HR source correct their max HR within 30
days. Part 3 — the share of prescribed-easy time above the ceiling falls between the first and second
point release after it ships. *Gated — if Part 1 adoption is near zero, Part 3 stays suppressed and should
not be built.*

---

### T0.4 · Every Card Carries A Way Home  `[M]` · channel defect · **durable**

**Problem.** `ShareCardView.swift:404` shares an image and nothing else. Every card ever shared has been a
lost install. The 82 curated medallions have no share affordance, and the personal heatmap has no export —
while Strava structurally refuses to let anyone export theirs.

#### ⚠️ Three corrections

1. **`ShareLink` has no heterogeneous `items:` form.** Ship `ShareLink(item:message:preview:)`
   immediately — genuinely one line, W0, and it gets the URL into iMessage/Mail/Notes today — then a
   `struct ShareableCard: Transferable` exporting `.image` and `.url` representations (~15 lines). Honest
   limit: Instagram Stories takes the image and drops the link, so **the corner wordmark is the only thing
   that travels there**.
2. **"Line one" must cover both share paths.** `:404` is the image `ShareLink`; `:467` is a separate
   `UIActivityViewController` whose `activityItems` must carry the URL too, or every shared clip stays an
   orphan.
3. **The attribution premise was wrong.** `AnalyticsSink` runs on a device that already installed the app;
   it cannot observe an install caused by someone else's card, and iOS gives no deferred deep link without
   an attribution SDK, which the allowed-deps list forbids. **Real design:** the shared URL is an App Store
   Connect **campaign link** (`?pt=<providerId>&ct=<token>&mt=8`, one token per card type); install
   attribution is read **externally** in App Analytics → Acquisition → Campaigns; `AnalyticsSink` measures
   only the sharer's half via `share_created`; the ratio is computed by hand across two systems.

**Card types.** `ShareStyle` is workout-scoped with an `init(workout:)`, so the award and heatmap cards are
new card **types**, not new enum cases — budget accordingly. All three still slot into the existing
swipeable `ShareStyles` rail; no new surface, no new navigation.

- *Verdict card* — reuse `ShareCardContent`'s route-silhouette pattern (pure `Shape`, no basemap) with the
  `RunVerdict` sentence in `Font.display` at the largest size that fits two lines, date and distance small
  beneath. `RunVerdict.swift:211` already produces the string.
- *Award card* — medallion on a **fixed-light canvas in both appearances** (`Theme.inkOnFixedLight`;
  `Theme.ink` would flip near-white in dark and the engraving would vanish), centred at ~60% width, name
  in `Font.display` below, requirement line in Inter caption. **Crown medallions keep their iridescent
  face — already earned, already sanctioned** (add to T2.3's allowlist). Entry points: a quiet "Share"
  below the requirement in `AwardUnlockView` appearing only *after* the sheen completes, plus the
  medallion detail sheet.
- *Heatmap poster* — 1080×1920 or 1080×1080 through the same `Snapshotter` that `MapStylePreviews` and
  `RouteSnapshotter` drive: heat over the chosen basemap, bottom scrim, wordmark, one honest line
  ("1,284 mi mapped · 2026") from already-computed totals. Colours resolved in an explicit **light** trait
  or a dark-mode phone bakes the wrong ink into a persisted image. Laid out **around** the Mapbox
  attribution strip the Snapshotter hard-draws with no opt-out (`MapStyleOption.swift:186`).
  **Do not filter on `privacy == .private`** — every workout carries the model default and no visibility
  picker ships (see T1.8), so that predicate empties the poster. Gate on the same publish-path predicate
  T1.8 moves the geometry gate onto (`SocialPrivacy.isShared`), or state that no filter applies until a
  visibility control ships.

Every card gains a corner mark: 8pt wordmark bottom-left, hairline `momentum.app` at 40% bottom-right —
small enough to stay postable, because if it is big enough to crop out, people will crop it out.

**Honest ceiling.** A hard wall caps shared-in conversion at a cold paid-install rate, with the annual
trial as the only soft landing. If campaign data shows installs arriving without conversions, **that is
the evidence to re-open the paywall model as its own owner decision** — not before.

**Why it wins.** It is the only change that turns an artifact into a channel. Gentler Streak, an Apple
Design Award winner, spent its newest release on map styles for its share card; a third-party economy
(Run Photo, Run Story) exists purely because default cards aren't postable; and Strava gates Best Efforts
shareables behind a subscription, taxing its own distribution loop (App. B). Our composer is already the
best-built in the category — photo or video, camera, pinch-and-drag crop, overlay sizing — it just doesn't
fire at the moments worth sharing and doesn't bring anyone back.

**Reads as success when:** ≥1 attributed install per 20 shared cards at 60 days. *Gated — if attributed
installs are near zero, card-type work stops at the verdict card.*

---

### T0.5 · The Lap Button  `[S]` · **table stakes** · perishable · *phone-recorded runs only*

**Problem.** `CardioTrackingView.swift:586-590` is the entire control set — Pause and Finish. The only
lap-like affordance lives inside `stepBanner` during a guided structured session. A track workout or a
self-directed interval set cannot be marked at the moment it happens. A five-minute disqualifier whose
cost is invisible: the person who bounces at minute two never files a complaint.

#### ⚠️ Three mechanism corrections

1. **Do not bank into the existing `Split` relationship during the run.** `persistSplits` is guarded
   `guard type.isGPS, detail.splits.isEmpty else { return }` (`WorkoutStores.swift:79`), and its doc
   comment (`:76-77`) records that an empty split list was a *shipped bug* that starved the AI read of its
   negative-split call. Making it non-empty mid-run means the canonical kilometre splits are **silently
   never written**. **Use a separate `@Model ManualLap` relationship on `GPSDetail`**, which leaves the
   guard untouched.
2. **There is no lap channel on the checkpoint path.** `GPSWorkoutSink.checkpoint(distanceM:durationS:elevationGainM:)` is three doubles (`GPSTrackingEngine.swift:14`). Spec `func bankLap(index:distanceM:durationS:) async` with a no-op default on `NoopGPSWorkoutSink`.
3. **The reassurance sentence named the wrong reader.** `RecordsBook.cardioCandidates` reads
   `gps.samplePoints(type:)` → `CardioMetrics.fastestWindow` (`:115-123`) and never touches
   `detail.splits`. The true statement: **manual laps cannot reach the record book by construction.**
   Fixture: a run with manual laps still persists its kilometre splits at finish.

**Design.** Not a third 56pt button. A **full-width ≥48pt** glass bar above the Pause/Finish row — raised
from 44pt because it is pressed a dozen times per track session, at 6 mph, one-handed — showing **`LAP 3`
plus the running lap time only**; lap distance moves to the summary. Tap banks with `Haptics.milestone()`
and the numerals reset with a `Motion.lively` count-flip; long-press offers "Undo last lap" via
`confirmationDialog`, merging it back into the current lap. The bar **hides entirely** when
`vm.currentStep != nil` — a structured session already has rep boundaries and `skipStep` is its lap.

**Laps are pure MARKERS indexed into `GPSDetail.routePoints`.** A lap must never re-derive its own distance
from raw samples — the moment it does, the splits and the headline disagree, which is the exact bug the
canonical reducer was built to kill. Summary lap distance is read back through `gps.routePoints(type:)` at
the banked indices.

**Map markers**: each banked lap drops a stable `MapViewAnnotation` — 9pt `Theme.ink` disc, white 1.5pt
ring, small ink numeral. Deliberately **ink** where automatic unit milestones are **white**: white badges
are the app's measurement, ink badges are yours. Never re-lay-out an annotation (churning annotations force
spline recomputes). **Summary**: a `SegmentedCapsule` at compact scale, "Laps · Miles", defaulting to Laps
when manual laps exist. No colour, no iridescence — a lap is a mark, not an achievement. **Acceptance
check: one-handed reach verified on device, mid-run.**

**Deferred, on cost not capability.** The watch already has a Lap button (`WatchLivePages.swift:540` →
`model.lap()`) and banks laps in memory (`WatchCardioModel.swift:56`); what it lacks is a
persistence/transport path to the phone. HealthKit *does* carry lap events (see T0.0), so this is a
separate project requiring a paired device — it must not ride in on the phone lap button.

**Why it matters.** This doesn't beat anyone; it stops us losing to everyone. Garmin, COROS, Apple's
Workout app, Strava's Record and Runna all have it, and Strava shipped "Laps in Record" as a headline
feature of its 2025 Record redesign (App. B).

**Reads as success when:** it exists. *Health check — its value lands pre-install, in the review a
credible runner does not write.*

---

### T0.6 · Your Runs Leave Whenever You Want  `[M]` · independence window · **perishable**

**Problem.** No GPX/TCX/FIT writer exists. The Settings JSON dump carries scalars only
(`DataManager.swift:68-69`) — not one coordinate. `HealthService.save` writes an `HKWorkoutBuilder` with
energy and distance samples only. **Every GPS trace momentum has recorded is currently unexportable by any
path.**

**Step zero (~40 lines).** In `HealthService.save`, attach an `HKWorkoutRouteBuilder` and `insertRouteData`
from the accepted samples. Routes then land in Apple Health, visible to every other app the athlete uses
and exportable through Apple's own *Export All Health Data*, which emits per-workout GPX — portability
credibility bought with one Apple-native API, no parser and no file format to maintain.

#### ⚠️ Four corrections

1. **Step zero is not free.** `insertRouteData` requires **share** authorization for
   `HKSeriesType.workoutRoute()`, which is not in `shareTypes` (`HealthService.swift:33-38`). Adding the
   type only helps someone who calls `requestAuthorization()` again, and all four call sites sit behind a
   *not-yet-connected* state — so **already-connected athletes never re-prompt and route writes fail
   silently for exactly the users with history worth exporting**. `isAuthorized` reads only
   `workoutType()` status (`:70-72`) and cannot be the route-write gate. Spec a one-time re-consent row in
   the Settings Health card; gate every write on `authorizationStatus(for:) == .sharingAuthorized`, falling
   through silently when denied.
2. **Be precise about backfill.** `finishRoute(with:)` can attach a route retroactively to `HKWorkout`s
   momentum itself wrote (identified by the `HKMetadataKeyExternalUUID` stamp at `:110`), but never to
   Watch- or Garmin-authored ones. **GPX, not step zero, is what makes the existing library portable.**
3. **What a lapsed subscriber keeps.** Export is never gated by entitlement. The shipped "Export my data"
   row (`SettingsView.swift:494`) already sits outside every `paywall.isPro` branch; the GPX rows land
   beside it. Add a test asserting the export rows render with `isPro == false`. Keep the sentence as a
   stated *fact* in the trust copy, but do **not** add it to the Pro feature list — `PaywallView.swift:55`
   holds that list to eight rows because the scale math is tuned for the count, and a Pro bullet would make
   the claim false the day a churned subscriber tests it, which is exactly the mechanic T1.8 condemns in
   Whoop and Oura.
4. **Resolve the honesty constraint by taking the second exit:** widen the `DataManager` JSON dump to carry
   plan, records, awards and athlete-model facts in the same pass — the same DTO shaping T1.8 Phase A
   needs, so it is a down payment rather than a detour, and it lets the sentence be broad and true.

**Writer.** `GPXWriter.swift`, pure string building, no dependency. GPX 1.1, `<trk><trkseg>` with a
`<trkpt lat lon>` per accepted sample carrying `<ele>` and `<time>` (ISO 8601 UTC — SI stored, formatted at
the edge), HR in the Garmin `TrackPointExtension` namespace time-matched to the nearest fix, **trimmed
samples excluded** (the file is the run *as corrected*, which is why this pairs with T1.5). Built off
`GPSDetail.routePoints`, so the file's distance matches the reported distance for phone-recorded runs and
the recording device's scalar for imported ones. Per-workout via `WorkoutDetailView`'s toolbar menu, writing
a temp file to `ShareLink`; bulk export in Settings → Data & privacy, one file per GPS workout into a dated
zip, streamed to disk off the main actor with an inline `ProgressRing` showing "412 of 1,180". Skip FIT —
binary, materially harder, nobody has asked. Defer the **reader** until the follow runtime is reachable;
when it ships, imported tracks must not mint PRs and must not feed pace recalibration.

**Copy.** One `Font.rounded(.body)` sentence in `Theme.inkSecondary`, no badge, no icon, no chrome, because
the point is that it reads as a **fact**: *"Your runs are yours. Export every one as GPX, any time."*

**Why it wins.** Runna refused an export outright and it escalated into a GDPR complaint. Strava's
Standard-tier API since 1 Jun 2026 requires the developer to hold a paid subscription, retires endpoints on
a 90-day grace, bans cross-user data display and bans AI/ML training on API data. The FirstBeat precedent —
third-party licensing withering after a Garmin acquisition — is being cited by coaches hedging now. RunGap
exists as a paid product purely because this category's users refuse lock-in, and its users are by
definition the switching population. (All App. B.) **Risk to name now:** the same GDPR mechanism that proves
this wedge is what will force Runna to open export — at which point the wedge narrows to "independent" and
"Apple-native."

**Reads as success when:** it exists and is reachable by a **lapsed** subscriber — a test asserts the export
rows render with `isPro == false` behind an already-cleared gate. *Health check.*

---

### T0.7 · The Wall  `[M]` · solvency · **durable**

*(a) and (b) are `[S]` on their own; the `[M]` is the experiment wiring in (c).)*

**Problem.** With a hard onboarding gate (`RootView.swift:115` — only a purchase or restore clears it),
**install → paid is the entire funnel**, and all seventeen T0/T1 items serve someone who has already paid.
There is no item anywhere pointed at the wall. Monthly ships **`trialDays: 0`** (`PaywallController.swift:50`)
— a $14.99 charge before the athlete has run once, the single largest refund and one-star generator in the
funnel. And the $14.99-vs-$9.99 test appeared once as something instrumentation would let you *read*, with
no owner, no sample size, no readout date and no mechanism (`project.yml:126` records Superwall as unwired
by decision).

**Three moves, none of which reopen the hard-gate decision recorded 2026-07-28.**

- **(a) Test a 7-day trial on monthly.** A store configuration change, not code. A wall that charges before
  the first run is *the honesty problem this document exists to fix, pointed at ourselves* — the annual
  cohort gets a soft landing and the monthly cohort, the higher-churn one, gets none. **Landing this changes
  T1.1's day-6 branch; update it in the same release.**
- **(b) Instrument the proof-of-value step that already exists.** `OnboardingViewModel.swift:158-160` puts
  `reveal` **four** beats before the paywall — reveal → notifications → primers → rateUs → paywall (raised
  at `OnboardingFlow.swift:1424`). **Do not re-render it on the wall** — measure
  `reveal → paywall_view → paywall_purchase_started` and expect three intervening screens. If the beat needs
  to sit adjacent to the ask, that is its own change to propose.
- **(c) Make the wall A/B-able through RevenueCat Offerings/Experiments**, with a `price_variant` assigned at
  first launch, persisted, and stamped on `app_open` and `paywall_view` — never Superwall. **Gate:** the
  price test opens only after `trial_start` and a distinct onboarding placement string have been live for one
  full **monthly** renewal cycle (30 days). Move one variable at a time (gate shape *or* price, never both).
  A price decrease reaches new subscribers only. Cross-reference PRD §pricing and `MONETIZATION-SETUP.md` as
  the decisions of record.

**Why it matters.** Not a competitive item — a solvency item. If the wall converts at 4% instead of 8%, every
T1 item on this list is worth exactly half.

**Reads as success when:** `paywall_view → paywall_purchase_started`, read weekly. *Gated — a sustained fall
stops feature work until the wall is understood.*

---

## T1 — retention past month 3

*Users who don't complete three workouts in week one churn at 4–5× (App. B, unverified). These are ordered
by what they defuse: the wall's aftermath, measurement, the weekly ritual, the plan surviving a real life,
the single-incident churn events, and the two structural debts.*

### T1.1 · Week One  `[M]`

**Problem.** Every new user has already paid (monthly) or is inside a 7-day annual trial *before they have
run once* — and then lands on a map with a plan row and no arc. `NorthStarFunnel` is written but never
read: `markLaunch`/`markFirstWorkout`/`markFirstAIRead` fire (`Analytics.swift:90`, `:101-104`) while
`northStarStatus()` has **zero callers** and the status never reaches `AnalyticsSink`, so the funnel exists
only on-device.

**Design.**

- **Resolve the deck conflict.** `TodayView.swift:1044` states the rule verbatim — *"exactly three
  thoughts"* — and `:1073` says *"Never more than one."* Week One **temporarily replaces the utility line
  for seven days**, never adds a fourth slot.
- Eyebrow `WEEK ONE` in Inter caption on `Theme.inkTertiary`; three ~28pt dot slots on a hairline rule
  (filled = iridescent, pending = `Theme.hairline` ring); one sentence beneath in Inter body. Filling a slot
  animates scale + opacity only (`Motion.entrance`), never layout. Iridescence is legitimately earned — a
  filled slot is a completed session. **Under Reduce Motion, crossfade the fill with no scale.**
- **⚠️ Contradiction fixed.** Pending slots **show the target, never a deficit** — no checkmarks, no `0/3`,
  no percentage numerals, no missed-day mark, and the sentence beneath counts only what happened ("Two
  sessions in"). Deleting the pending slots would delete the visible destination the item's own evidence
  depends on.
- **Award chase**: reuse `AwardsShelf`'s existing next-up selection (`:30-42`). Note the tension to
  reconcile: NRC's hardest achievement tier retains at 74.17% (App. B, unverified), which argues for
  surfacing both an instantly reachable win **and a visibly distant one**, while `AwardsShelf` deliberately
  refuses summits forty tiers away. Pick one and say why.
- **Learning receipt**: each save appends one line naming what the app just learned, driven by
  `AthleteModelEngine.Confidence` sample counts — so the learning is **literal** rather than flattery.
- **Day 6 beat**: a full-canvas "Seven days in" — sessions done, distance, which recovery signals are now
  flowing, which confidence arcs filled, `PodiumOutlook` re-run against the week's data. **No upsell, no
  purchase ask.** Reuse `CompletionCelebration`'s ring-and-check language, hosted at root on its **own**
  `Color.clear` background view (RootView is at its documented 4-modifier cover ceiling).
- **⚠️ Cohort branch, corrected.** For the annual cohort **no money has been spent** (`trialDays: 7`), so
  day 6 is the trial-cancel decision. For monthly, money was spent on day 0 and renewal is day 30. Keep
  **one** day-6 receipt for all cohorts — it is the activation capstone, and deleting it for the monthly
  cohort would gut activation for exactly the cohort with the highest churn. **Branch on `trialDays > 0`,
  not on product id**, so T0.7(a)'s monthly trial is handled automatically: trial cohorts get *"Your trial
  becomes $109.99/yr tomorrow. Manage it any time,"* linking the manage-subscriptions URL already at
  `SettingsView.swift:42`; non-trial cohorts get nothing extra, because there is nothing honest to say.
  **Naming the charge before it lands suppresses refunds and is not an upsell.**
- **Zero-plan path**: "Log anything, even a walk", and the arc counts logs, so a lifter or no-race athlete
  never stares at an empty running scaffold.
- Tap dismisses forever. Two different concerns: `RevealOnce` (`SegmentedCapsule.swift:95-113`) suppresses
  the entrance cascade replaying **within a session** — it is an in-memory per-session ledger and cannot
  stop a cover re-presenting across launches; a **persisted** flag (`@AppStorage("weekOne.presentedAt")`) is
  what does that.

**Why it wins.** Nobody in the category treats week one as a designed arc — Runna sells a predicted time in
onboarding then hands you a calendar; Fitbod shows a body map once; Ladder relies on a human coach's
welcome. A hard paywall makes the honest "here is what you bought" framing available to us and structurally
unavailable to a freemium competitor that still has to sell.

**Reads as success when:** the ≥3-session share of week-one cohorts, against the 4–5× churn benchmark.
*Gated — below the benchmark, R2's remaining activation work is re-scoped.*

---

### T1.2 · Retention Instrumentation  `[M]`

**Problem.** `Analytics.swift:8-22` has fourteen cases and none is `app_open`, `session_start`,
`onboarding_complete` or `trial_start`; the only feature-scoped case still emitted anywhere is
`shareCreated(style:)` (`spotsViewed`/`spotSelected` survive as declarations with no emit site). The
onboarding paywall and the Plan-tab lock share the placement string `full_plan`. `onboarding_step` fires
from `.onChange`, which never fires for the initial value. And the north star requires an AI read that is
Pro-gated behind a hard paywall, so **only payers can satisfy a metric written for a free funnel**.

#### The revenue join comes first — it was the actual blocker

`AnalyticsSink` keys on a per-install UUID that "a reinstall legitimately produces a new one," and
`PaywallController.swift:311` documents in plain English that *RevenueCat's revenue data can't be joined to
our own `app_events` funnel* without sign-in — which is skippable (`OnboardingFlow.swift:1400`,
`onSkip: { onComplete() }`).

1. `Purchases.shared.attribution.setAttributes(["install_id": installID])` at `configure()`, so anonymous
   onboarding purchasers still carry the analytics key.
2. A **RevenueCat → Supabase webhook** writing `INITIAL_PURCHASE` / `TRIAL_STARTED` / `TRIAL_CONVERTED` /
   `RENEWAL` / `CANCELLATION` / `EXPIRATION` / `REFUND` into a `billing_events` table keyed on `install_id`
   and `app_user_id`, owner-only RLS.
3. Rename `paywall_convert` → `paywall_purchase_started(product:isTrial:)` — it currently fires on
   `.purchased`, which for the annual product is a **$0 trial start**.

**Then:** `app_open` (with `days_since_install` as a **bucket string**), `session_start`,
`onboarding_complete`, `trial_start`, `week_one_status` (0/1/2/3+, day 8), `north_star`,
`account_created`/`account_skipped` (W0.2), `plan_switch(from:to:)`, `winback_offer_shown`/
`winback_redeemed`, and a `source` (phone | healthkit) dimension on `workout_completed` — the import path
logs nothing at all today. Add a **feature-event tranche with an owner column** mapping each event to the
item that requires it.

**Payload discipline (unchanged, per PRD §13.3):** counts, booleans, latencies and short enum strings only —
no health values, no routes, no names, no locations. `days_since_install` ships as a bucket string, never a
timestamp, so it cannot be a fingerprint. `AnalyticsSink`'s batching, persisted offline queue, 500-cap and
4xx-drop already exist and need no change. Keep the `--seed-demo`/test muting intact so a screenshot session
cannot pollute the funnel it is meant to measure.

**Redefinition:** the north star becomes *"first workout saved within 72h of first launch"*, with the AI read
demoted to a secondary milestone — **and amend `docs/PRD.md` §12 in the same commit** (the
`**North star — Activation:**` line at `docs/PRD.md:781`), and fix the stale `PRD §13.5` citations in
`NorthStar.swift:3` and `Analytics.swift:73`, which are what pointed everyone at the wrong section.

**Deletions/fixes:** remove the dead `spotsViewed`/`spotSelected` cases; seed `onboarding_step` in `.task`;
give the onboarding paywall its own placement string.

**Reads as success when:** D1/D7/D30, trial→paid, and week-one activation are all readable from our own
tables against the category benchmarks. *Gated — it gates everything else on this list.*

---

### T1.3 · Sunday Review, And The Block That Closes  `[M]`

**Problem.** `NotificationService.swift:148` already ships a repeating "Your week in review" at Sunday
18:00 — the best weekly-open hook in the app — and it has **no destination at all**: `scheduleWeeklyCheckIn`
(`:148-157`) sets title/body/sound and no `userInfo`, the `didReceive` delegate handles only the Siri
meal-undo action (`:39-54`), and `onOpenURL` (`RootView.swift:332-335`) knows only `momentum://today`.
Tapping it foregrounds the app on whatever tab it was last on. Meanwhile the actual recap already exists
*and* already fires every Monday (`CoachProactive.swift:130-150`, free to read). Plan completion is also the
category's admitted churn cliff — Runna's own 2026 roadmap concedes future plans "won't just reset"
(App. B), which is an admission that finishing a block is when people cancel.

**Three moves.**

1. **Give the weekly request a destination.** Add a `userInfo` route, extend the notification delegate and
   `onOpenURL` to consume it, and land on the recap sheet. This is a from-scratch payload-plus-routing
   build, not a re-route.
2. **Promote the recap to a Progress-hosted sheet** using the **same `CoachSection` renderer the chat
   already uses** so there is one recap grammar. Layout inherits the sectioned-report language already
   shipped in Trends: numbered mastheads (`01 WHAT YOU DID` / `02 WHAT CHANGED` / `03 WHAT'S NEXT`) in Space
   Grotesk, one card treatment, `.reveal(_:once:)` stagger. All numerals `.monospacedDigit()` in `Theme.ink`;
   iridescence **only** on a PR chip, an award coin, or the completed-week ring. Adaptation receipts render
   in the existing one-line rationale style, never as a badge or a diff. One action at the end: **"Start
   Monday"**, deep-linking the next session. Under Reduce Motion the stagger becomes a single crossfade.
   Add a pinned "This week" row at the top of Trends so it is reachable without waiting for Sunday.
3. **Build the block retrospective** off `PlanView.swift:712`'s existing `renewalCard`: hang a longer scroll
   carrying the block's arc — weekly volume curve, pace-at-effort trend, readiness baseline shift, awards
   earned — ending in a share card and then the existing renewal CTA.

#### ⚠️ Two bullets added — this is where the moat gets restated

- Under **02 WHAT CHANGED**: one confident `MemoryNote` or a newly-filled `AthleteModelEngine.Confidence`
  arc, in the same one-line rationale style — **so tenure is restated weekly rather than cashed once in week
  one and never again.** The north star is "a personal AI that learns each athlete", and T1.1 was the only
  place the plan ever said so out loud.
- Add the block's **adaptation ledger** to the retrospective: every structural change the engine made this
  block, each with the rationale string it already wrote and the signal that caused it. Per-session rationale
  already renders in three places, so adaptation is visible *as it happens* — what is missing is any
  consolidated view of what a whole block did, which is the one genuine gap in the moat's legibility.

**Tone and copy rules.** Not a report card: volume down reads as "you absorbed", never a deficit; a moved
session is moved, never failed. **Every line must carry a cause the athlete could not have read off the
chart** — generic post-run narration ("truly easy") is the category's most-mocked AI feature. Free to read;
Pro gates only "Apply next week's proposal."

**Reads as success when:** weekly-review opens per notification delivered. *Gated — if opens per delivery
are flat, the block retrospective is not built.*

---

### T1.4 · Life Happened  `[M]` · ships alone in R5

**Problem.** The single loudest unmet need in the voice-of-customer corpus. Runna's 224-comment injury
thread's top complaint is that there is no way to manage skipped sessions; their own workaround is "at best
a hack." Garmin's answer is the opposite failure — silently downgrading tomorrow, which users call "far too
smart for its own good." (App. B.) Our Plan menu has two rows (`PlanView.swift:333-337`).

**Do not build a fourth plan-mutation surface.** Add two missing *intents* as entry points into the rebuild
path that already exists (`PlanService.swift:66`; `PlanSettingsSheet.swift:446-457`;
`PlanSettingsSheet.swift:97/287` already runs `PlanFeasibility` live against the **buffered** picker value
and renders the honest verdict card; `CoachUndo.Snapshot`; `InjuryReportSheet`;
`SessionDetailSheet.rescheduleStrip`).

A "Life happened" row in `PlanView`'s existing `Menu` opening a small case-picker sheet **from PlanView's
own stack, never a root cover**. Four `SelectionCard`s, ink-filled on select, **no iridescence** — being ill
is not an achievement.

| Case | Routes to |
|---|---|
| "Something hurts" | the shipped `InjuryReportSheet` |
| "This week is impossible" | `PlanSettingsSheet` in `.adjust`, days-per-week focused |
| **"I'm away, these dates"** | *the only genuinely new input* — a 3–21 day range writing an unavailability window the generator reads, then the same rebuild + feasibility card |
| "I'm not feeling 100%" | `InjuryResponse`'s existing severity ladder, not a third one |

The feasibility card **is** the preview — it already states the cost in signup language ("Your goal moves to
3:52 — or move the race two weeks") — so **do not build a before/after board diff as a prerequisite**; ship
it as a second slice if anyone asks. Undo reuses `CoachUndo.Snapshot` verbatim.

**Invariants.** Race day is never moved by the engine, **only by the athlete through the explicit
move-the-race option**. No week exceeds ACWR 1.3. Every changed session writes a rationale so the board
cannot render an unexplained edit. **Throttle:** athlete-initiated changes bypass the
≤1-structural-change-per-week budget (they asked) but must **not** reset the automatic budgets — document
that exception beside `lastAdaptedAt`.

**⚠️ Reachability fix:** `PlanView.swift:118` applies `.proLocked(.fullPlan, active: isFutureWeek)`. Life
Happened must be reachable for the **current** week without tripping `.fullPlan`, or T1.7's day-14 rung is
broken for anyone whose entitlement has lapsed.

**Why it wins.** Runna's "Not Feeling 100%" shipped only after community pressure and still delegates the
coaching decision back to the injured athlete. Humango's rebuild-the-remainder behaviour is the one thing
reviewers single out as impressive, and it sits inside a $28.99/mo triathlon app with no honesty engine
behind it. (App. B.) We can be the only running app that computes the ramp for you **and** prices the honest
cost of the interruption in the words the athlete heard at signup.

**Risk.** Highest blast radius in the plan. `PlanEngineInvariantTests` sweeps the whole input space.
**Descoped:** the B-race case is a schema change (`TrainingPlan`/`UserProfile` hold one `raceDate`) and must
be decided separately.

**Reads as success when:** the share of plans that receive a Life Happened event and remain active 30 days
later, versus plans that go silent. *Gated — if rebuilt plans go silent at the same rate, the second slice
is not built.*

---

### T1.5 · Trim The Run  `[M]` · ships alone in R4 · *phone-recorded and imported-with-geometry runs*

**Problem.** The only corrective action is `discard()` (`CardioSaveView.swift:371`), which deletes the
recording and un-credits the plan. A GPS spike at the start or ten forgotten minutes in a car park forces a
choice between a wrong distance — which poisons pace recalibration, records, plan credit and every route
match — and throwing the session away. `GPSDetail.isManualTrim` already exists with **zero other
references**: a field waiting for its feature.

#### ⚠️ Three corrections, one of which falsifies the item's own selling point

1. **One accessor, or the item is a lie.** Nine other production sites filter on `.accepted` and would all
   keep the trimmed spike — critically `routeCoordinates` (`RouteReplay.swift:17`), which feeds the
   persisted map snapshot, the share cards and the profile tiles, so **a trimmed run keeps rendering its
   untrimmed line in the athlete's grid forever**. Mandate `var usableSamples` on `GPSDetail` applying
   `accepted && !trimmed` (plus the `|| pausedSpan` variant `routePoints` needs) and migrate every reader in
   the same PR: `RouteReplay:17`, `RouteMatch:183` (route identity is the thing trimming exists to protect),
   `HeatmapSource:28/:40`, `SyncEngine:48`, `AwardsBook:165`, `WorkoutReadTemplates:165`,
   `TrendAnalytics:110`, `TodayView:739`, `CardioTrackingView:117`. Explicitly exclude
   `WorkoutRecovery:40/:54` with a one-line reason — it reads an in-flight workout that cannot have been
   trimmed.
2. **The scrubber's x-axis is TIME (`RoutePoint.t`), not distance** — `RouteReplay.swift:97` accrues moving
   time while `:106-117` accrues zero metres for a Doppler-stationary span, so on a distance axis a stopped
   span occupies zero width. **⚠️ But the time axis alone does not solve the motivating case either:** ten
   forgotten minutes in a car park auto-pauses after 4–5 s (`GPSTrackingEngine.swift:161-172`) and stores
   fixes as `pausedSpan` (`:145`), which `routePoints` skips entirely (`RouteReplay.swift:90-94`) — so it is
   zero-width on the moving-time axis too. **The stopped-span band and the suggestion chip must be built
   from the raw `pausedSpan`/Doppler-stationary samples, not from `routePoints`**; that is what actually
   delivers the one-tap fix. Render stopped spans as solid ink blocks in a thin band under the elevation
   ribbon, and add the auto-detected chip that pre-positions the handles — *"Stopped for 10:24 at the end.
   Trim it?"* That is the version worth screenshotting.
3. **The haptic detent was a motor hum.** "Every 10 m" over a ~320pt track on a 10 km run is ~31 m per point
   — roughly three haptic calls per point of drag — in the same release that authors deliberate CoreHaptics
   patterns. Re-spec: one `Haptics.light()` per ~8pt of screen travel, with `Haptics.milestone()` reserved
   for semantic snaps (unit markers, pause boundaries, stopped-span edges).

**Entry.** "Edit route" in the `CardioSaveView` editor block and in `WorkoutDetailView`'s toolbar menu, both
`.sheet` with `.presentationDetents([.large])`.

**Layout.** `RouteMapView` at 260pt redrawing live as handles move → beneath it, the elevation profile from
`routePoints` reused as the slider's **track**, kept range at full ink, trimmed ends at
`Theme.inkTertiary.opacity(0.25)` → the stopped-span band from correction 2 → two 28pt handles with 44pt hit
targets → a live readout (new distance, new time, new avg pace, all `.monospacedDigit()`, animating via
`AnimatedCounter`) → `OversizedButton` "Save trim" plus a text "Restore full route" shown only when
`isManualTrim`.

**Apply — mark, never destroy.** Set `trimmed = true` on samples outside the kept range, leaving
t/lat/lon/accuracy/altitude/speed intact. Recompute **only** through `gps.routePoints(type:)`. Decide and
**test** `startedAt`/`elapsedS` when the head is trimmed — streaks, weekly buckets, record dates and the
plan-session date all read it. Clear `gps.matchedRouteData` so a stale map-matched line cannot outlive the
trim, and clear `workout.route` (the `SavedRoute` link T0.1 adds) so the run re-assigns. Clear
`mapSnapshotData` and reset `mapSnapshotVersion` so the healer re-renders the tile and share card. Clear
`syncedAt` — upload geometry is derived per call in `SyncEngine.dto`, so that is what re-uploads the
corrected path.

**⚠️ Imported runs.** T0.0 makes the imported scalar the truth and geometry shape-only. Trimming an imported
run overwrites that scalar. **Pick one here:** trimming clears the imported scalar's authority and stamps a
`distanceSource = .geometry` value with one rationale line, **or** trimming is disabled for imported runs.

**Restore.** Clear the flags and recompute identically — lossless forever, because nothing was deleted.

**Records (same PR, non-negotiable).** **Add** `RecordsBook.recompute(after:)` — no retirement path exists
today (`RecordsBook` only promotes, via `beats`/`record`; its one `context.delete` sits inside the latched
v4 backfill at `:71`). It must retire any record the trimmed workout no longer supports and promote the
next-best. Fixture: trim a run holding a 5K record → assert retirement **and** promotion.

**Plan credit** is kept even if the trim drops below `PlanCredit.minFulfillment` — the app is not going to
un-check a session because it fixed its own GPS — and the confirmation says so.

**Copy.** "Trim your run" / "GPS wandered before you started, or the clock kept running after you stopped?
Drag the ends in." / "Trimmed. Your full route is still here if you want it back."

**Why it wins.** Voice-of-customer names one bad GPS trace as the single most emotionally violent churn
trigger in running software (App. B). Strava lets you crop; Garmin does not on the phone; Runna has no
editing at all. The differentiator is the honesty of the implementation: we mark rather than delete, so
restore works a year later, and we recompute through the **one** canonical reducer so no screen can disagree
with another afterwards.

**Reads as success when:** trims per 100 GPS runs, and zero record-integrity regressions. *Gated on the
second — a single phantom PR reverts the release.*

---

### T1.6 · Race Week, And A Projection That Moves  `[S]`

**Problem.** `CoachRacePlan` computes five sections and has one call site
(`CoachChatViewModel.sections(for:)`). It **already reaches athletes free and without typing** —
`CoachProactive.seedRaceWeek` (`:49-73`) auto-seeds a `.racePlan` card plus a bell notification for
`daysOut` 0–3, driven from TodayView's daily sweep, and reading is not Pro-gated (the gates are on send and
apply). What is missing is a surface earlier than the final four days and a Plan-page home for it.
Separately `PodiumOutlook` is called only from `PlanRevealView.swift:357/:372` — shown once in a lifetime,
never re-run against improving fitness.

**Build.** Extend and relocate, not first-ever surfacing.

- **Race week card**: extend `seedRaceWeek`'s gate to 14 days and give it a Plan-page home beneath the
  existing masthead, through the same `CoachSection` renderer. One card, one scroll, `.reveal(_:once:)`
  cascade. It must **read** from the engines that own each number — the `Formatters.raceCountdown`
  single-grammar precedent (`PlanView.swift:371`) exists precisely so the header and the card "must never
  disagree."
- **Projection that moves**: persist the block-start `PodiumOutlook`, re-run after every adaptation and
  monthly, render the delta inside the **existing** `RacePredictionCard` (`RaceInsightCards.swift:8-29`) —
  *"at week 0 this block projected 1:52; it now projects 1:49."*
- **Iridescence: ink.** `RaceReadinessCard.swift:14-15` already established the rule — *"a projection is
  information, not an earned moment"* — and its forecast path is deliberately dashed so "a projection never
  impersonates measured data." Note that `RacePredictionCard` itself currently carries an iridescent border
  (`RaceInsightCards.swift:51`, justified at `:3-4`). Under that rule, **demote that border to
  `Theme.hairline` in this PR and add the site to T2.3's inventory, making it seven rather than six.**

**Explicitly cut, with reasons:** the taper state (`RaceReadinessCard` already ships the race-day form
projection with a TSB sparkline), the fuelling timeline (`FuelingGuide` already renders in two places), the
countdown (`PlanView.swift:359-373`), and the per-segment course-elevation pacing list, which has **no data
source**: the only course geometry in the repo is the bundled marketing hero
(`Momentum/Resources/austin-marathon.json` — lat/lon only, no altitude, loaded at `TodayView.swift:123-135`),
and there is no course *import* path of any kind.

**Why it wins.** Garmin's PacePro is locked to a $600 watch and buried three menus deep; Stryd's Race Power
Calculator costs $249 of hardware; Runna ships race-week guidance as push notifications and hands you to a
generic tracker. (App. B.) Race prediction is the category's most-distrusted number, which is exactly why a
projection that visibly **moves** with real training reads as more credible than one that is asserted.

**Reads as success when:** race-week card opens per athlete with a dated race inside 14 days. *Health
check.*

---

### T1.7 · Notification Preferences, Then The Lapse Ladder  `[M]`

**Problem.** The only `Toggle` in `SettingsView` is `voiceCoachEnabled` (`:288`); the reminder time is
hardcoded 07:30 (`NotificationService.swift:16-17`); the look-ahead is 7 days (`:205`) re-armed **only from
app-open paths**; the single backgrounding hook flushes analytics and nothing else (`MomentumApp.swift:127`).
Someone who stops opening goes silent inside a week, and there is no APNs and no win-back of any kind.
Meanwhile an athlete who finds streak nudges stressful must silence coaching entirely — itself a churn path
and a one-star review on a no-shame app.

**Release 1 — Preferences `[S]`, ships in W0.** A Notifications row in Settings → Preferences pushing a plain
list of four toggles (session reminders, coaching notes, weekly review, streak nudges) plus a
`DatePicker(.hourAndMinute)` replacing the two hardcoded constants. No new visual vocabulary. **Cheapest item
on the roadmap** and it closes a real one-star path.

**Release 2 — the ladder.** `scheduleLapseLadder(from:plan:awards:)`, armed on **every backgrounding**,
cancelled on every open, with fixed identifiers so re-arming replaces rather than stacks, each rung checking
its own toggle before scheduling.

#### ⚠️ Branch on entitlement — the ladder conflated two different lapses

`PlanView.swift:118` walls future weeks, so a churned subscriber following the day-14 rung lands on a
partially walled plan — **notifying someone you already lost, with no offer, into a wall**. iOS 18 is the
locked minimum, so **App Store Win-Back Offers are available today** and pass 1 never mentioned them (zero
matches for `winBack|offerCode|presentCodeRedemptionSheet`). Branch on `paywall.isPro` **evaluated at fire
time, not at scheduling time** — the ladder is armed on backgrounding and entitlement can lapse in between.

| Cohort | Ladder |
|---|---|
| Entitled, inactive | Day 3 "Thursday's tempo is still on the board." · Day 7 nearest award progress from `AwardsEngine.progress` ("4 km from Century Club") · Day 14 "Your plan is holding — want us to rebuild the rest of it around today?" → Life Happened · Day 28 one line, then silence forever |
| **Lapsed subscriber** | Day 7 and Day 30 only, leading with what is still theirs — *"Your 214 runs and your marathon plan are still here"* — landing on a **Win-Back Offer** configured in ASC and surfaced through RevenueCat/StoreKit 2, never Superwall |

**Operational rules.** Bodies are **one sentence, no emoji**, and must pass the coach-voice rules — all
strings, including win-back, go into `CoachVoiceTests`. **Until Life Happened ships, the day-14 rung falls
back to `PlanSettingsSheet`'s rebuild path or is dropped — never left dangling.** Every rung **mirrors into
the bell inbox** on open using the existing kinds, so returning shows what was said rather than a badge with
nothing behind it. An athlete returning after 14+ days **lands on the rebuild offer**, not a stale,
guilt-shaped calendar. **Budget:** iOS caps pending local notifications at 64 — schedule the ladder rungs
**first**, then fill the remainder with session reminders. **Principle check:** this does not violate the ban
on default morning readiness pings — that rejection is scoped to the readiness ritual.

**⚠️ Sequencing:** the ladder ships **below T1.8 Phase A/B**, not merely after T1.4. Restore is the
precondition for the lapse ladder actually working: you cannot re-recruit someone you held hostage. A ladder
that re-recruits someone whose training was lost on their last phone upgrade is worse than no ladder.

**Why it wins.** Every competitor's win-back is a server push tuned for engagement. This is local-only — no
health data leaves the phone, no APNs entitlement, no privacy-label change — capped at four messages and
self-silencing, and every message states something specific and true about **this** athlete. The definitive
cancellation quote in the corpus: a Garmin Connect+ user cancelled because, after a 10-mile morning run, the
evening AI insight was about a 0.8-mile dog walk being 0.03 mph faster than yesterday's (App. B). **There is
no narration without new information** — that rule governs every string in this ladder.

**Reads as success when:** return rate per rung, and win-back redemption rate. *Gated — a rung with no
measurable return is deleted rather than reworded.*

---

### T1.8 · Continuity: The Restore Path  `[XL]` · **durable**

**Problem.** `SyncService.swift` is **63 lines**, and its own header admits it: *"Upload-only for v1;
bidirectional merge is the next layer."* No download direction, no CloudKit, and profile, `TrainingPlan`,
`PersonalRecord`, `EarnedAward` and `AthleteModel` are never uploaded by any path. A subscriber who upgrades
their phone loses everything the subscription bought while the App Store cheerfully restores their
entitlement. **The memory layer sold as the differentiator is device-only.**

**Phase A0 — widen the workout payload.** `WorkoutSyncDTO` is **fourteen** scalars plus an optional
`[[lat, lon]]`, under the header rule *"Raw `LocationSample` logs stay on-device"*: no samples, no `Split`
rows, no `HeartRateSample`, no photos, no `elapsedS`, no altitude, no `plannedSession` link, no snapshot.
**A Phase-A-only restore returns a list of dates and distances** — no heatmap, no route matching, no splits,
no time-in-zones, no line on any map. That is the same broken promise the item warns about, one level down.
Minimum honest payload: accepted geometry with `altitudeM` and timestamps (or a compressed polyline plus
parallel altitude/time arrays), `pausedSpan`, `elapsedS`, persisted `Split` rows, the HR series, photos to
Storage. **Storage budget is an open decision with an owner and a date** — a starting proposal is 25 MB per
athlete with geometry downsampled to one point per 10 m beyond the most recent 100 runs.

**Phase A — upload everything.** Push profile, `TrainingPlan` (+ `PlannedSession`s), `PersonalRecord`,
`EarnedAward`, the `AthleteModel` (Tier-A facts plus Tier-B memory notes) and the A0-widened workout payload
to Supabase, owner-only RLS on every new table.

**Phase B — restore into an empty container.** A one-shot download on first launch after sign-in, refusing to
run against a non-empty store. It must not re-fire 82 award celebrations on arrival — reuse the existing 48h
freshness window.

**Phase C — surface.** Settings gains a "Your data" card above Data & privacy with one status line carrying a
monospaced timestamp — *"Backed up · last synced 2 minutes ago · workouts, plan, records, coach memory"* —
`Theme.success` dot when current, quiet `Theme.inkTertiary` dot when pending. **Never red**: a pending sync is
not a failure. Below it a "Restore from your account" row. The restore itself is a full-screen cover on its
**own** `Color.clear` background view (RootView cover ceiling), using `ProgressRing` plus the plan-reveal
loader's ticking-checklist language, one line per domain as it lands. Monochrome throughout; the only
iridescence is the final check. Add the restore beat to the account step so a returning athlete is offered
*"We found 214 workouts and your marathon plan. Restore?"* rather than a blank app.

**Phase D — multi-device merge. Deferred, and named as a prerequisite rather than a bullet.** `updatedAt` +
`deletedAt` on every synced model — **this roadmap's first non-additive change, and therefore what forces
`VersionedSchema`** — a `deleted_at` column plus a per-device `last_pulled_at` cursor, and the Postgres clock
via trigger as the ordering authority so skewed device clocks cannot fight. **Until Phase D ships, a second
signed-in device is unsupported — say so in the UI.**

#### ⚠️ Three corrections

- **The geometry gate is currently dead.** `route` is nil whenever `privacy == .private` — the model default
  (`Workout.swift:17`) — and **nothing in the shipping app ever assigns `workout.privacy`** (zero
  `privacy =` writes app-wide), since the visibility controls were removed at the solo pivot. So every
  workout is `.private` and the Supabase `workouts` table contains **zero routes today**. Move the gate off
  `SyncEngine.dto` and onto the publish path that already owns it
  (`SocialPrivacy.isShared`/`SocialSyncEngine`), so personal backup uploads everything under owner-only RLS
  while nothing becomes visible to anyone. **Delete any "private workouts never upload geometry" line:** with
  no visibility picker shipping, it silently means "never upload any geometry."
- **Delete "last-write-wins" and "idempotent by construction."** Only `AthleteModel` and `MemoryNote` carry
  `updatedAt`, there are no tombstones, and W0.3 fixes the one edit path that does not re-dirty. Phase B is
  restore-into-empty-container only, which is what its own sentence implies.
- **Resolve the decision this omitted.** Before building Phase A, spend **one day** auditing
  `Momentum/Models/` against CloudKit's constraints — no `@Attribute(.unique)` (already clean), every
  relationship needs an inverse, every attribute optional or defaulted, `.externalStorage` blobs sized
  against CKAsset limits — and decide `ModelConfiguration(cloudKitDatabase: .private)` **versus** Supabase
  DTO expansion *on the record*, with each option's migration cost written down. CloudKit, if it survives the
  audit, delivers restore for a fraction of Phase A and is the Apple-native path.

**Instrument the precondition.** The account beat is the **last** onboarding step and is skippable
(`OnboardingFlow.swift:1400`), so an unknown share of paying subscribers finish as anonymous RevenueCat
customers with no Supabase user and nothing to restore. Log `account_created`/`account_skipped` in W0.2, ship
Phase A regardless (it is what makes a later ask honest), and **gate Phase C on a sign-in rate at or above
50% of paying subscribers over the trailing 30 days**; below that, spend the budget on a second, better-timed
ask at the day-6 receipt instead. The anonymous→identified aliasing path is already engineered
(`PaywallController.swift:315-317`), so a deferred sign-in does not cost the athlete their purchase.

**Why it wins.** Whoop and Oura hold history hostage **by design** — "cancel and you lose your scores" is
repeatedly cited as the reason people never *start*, not just why they leave (App. B). "Your training is
yours — restorable and exportable" is a position none of them can copy without giving up leverage.

**Reads as success when:** % of active accounts holding a complete server snapshot, then restore completion
rate. *Gated — Phase C does not ship below the 50% sign-in floor.*

---

### T1.9 · The Annual Moment  `[S]`

**Problem.** Annual is $109.99 against $179.88 for twelve months of monthly, and annual plans are ~4.5× the
LTV of budget options, having grown from 51% to 61% of category revenue (App. B). Settings' `proCard`
(`:197-207`) shows "Momentum Pro" and a green Active dot with **no plan period and no in-app switch path** —
only a "Manage subscription" row out to the App Store (`:211`), which never says what they're on or what
annual would save. **Nothing in the app ever offers the switch.** Meanwhile T1.3 builds a block retrospective
that ends in a share card and the renewal CTA — the single best-earned moment in the app to offer it.

**Design.** One quiet ink row at an earned moment. Trigger: a monthly subscriber who has completed a training
block, or three consecutive active weeks. *"You've trained N weeks. Switch to annual and save $69.89"* —
purchasing the existing annual package from the `default` RevenueCat offering, StoreKit handling the in-group
crossgrade. Dismissible forever. **No iridescence**: a price change is not something the athlete earned, and
putting the reward accent on a billing upsell is the fastest way to spend the accent's meaning. Place it
**beside** `PlanView.swift:712`'s "Build my next block" CTA and never in place of it — that CTA is a
*training*-block renewal, not a subscription one, and conflating them makes both read as a sales moment. Add
`plan_switch(from:to:)` to T1.2.

**Reads as success when:** annual share of active subscribers. *Gated — if the row does not move it in 60
days, it is deleted rather than iterated.*

---

### T1.10 · The Action Button, And A Four-Tab Bar  `[M]` — **owner decision, 2026-07-28**

> Not a ranked proposal. This is a directed IA change, recorded here so the rest of the plan can be
> reconciled against it. It supersedes the standing "the bar is full at five, no sixth tab" constraint in
> `CLAUDE.md` and in `Route.swift`'s `AppTab` doc comment.

**Problem.** Two things are wrong with the current shell, and they are the same problem seen from both
ends. **Start is trapped on Today.** `RootView.swift:411` builds a five-tab `TabView`, and the only way to
begin any activity is `TodayView`'s deck — `OversizedButton(title: startTitle, systemImage: "play.fill")`
alongside `logButton`. From Plan, Progress or Fuel there is no way to start a run, log a workout or log a
meal without first navigating home. **And the Profile tab is redundant**: `TodayView.headerCard` already
ships an `AvatarView` with `mapSafeTap("Your profile") { showProfile = true }`, so Profile has a working
entry point that does not need a fifth of the bar. Meanwhile Awards, the personal heatmap, the exercise
library and Notifications have no root-level entry at all.

**Build.** Drop `.profile` from `AppTab`, leaving **Today · Plan · Progress · Fuel**, and add one global
action button pinned bottom-trailing that opens a sheet of *things you do* — with a small navigation strip
for the destinations that are genuinely buried.

**Design.**

- **The bar.** `AppTab` becomes `today, plan, progress, fuel`. Icons unchanged (`map`, `calendar`,
  `chart.line.uptrend.xyaxis`, `fork.knife`). Frequency is the whole argument: Today is daily, Fuel is
  several times a day *if logging is cheap*, Plan is several times a week, Progress is weekly (T1.3's
  Sunday review lands there). Profile is an identity surface visited rarely. **Do not demote Fuel** — a tab
  is what makes meal logging cheap, and `FuelReadiness`'s under-fuelling floors are worthless unlogged.
- **Profile's entry, on every tab.** Today keeps its floating-glass avatar exactly as shipped. On the other
  three, the avatar takes the **leading accessory slot of D.3's `Masthead`** — which is why D.3 is a
  prerequisite rather than a conflict: one component, four surfaces, one entry point. Progress → You
  remains the second route.
- **The button.** A 56pt ink-filled circle on Liquid Glass, pinned bottom-trailing above the tab bar with
  a 16pt inset, `plus` rotating to `xmark` on open (`Motion.lively`). **Not iridescent** — it is a control,
  not an achievement, and T2.3's three-clause rule governs it. `Haptics.light()` on open.
- **⚠️ Prototype the native slot first.** `tabViewBottomAccessory` exists in the iOS 26.2 SDK (verified in
  the SwiftUI `.swiftinterface`) and the app already opts into Liquid Glass (`Glass.swift:40`). It gives
  the morph-to-expanded behaviour and correct safe-area handling for free, where a floating overlay must
  hand-manage inset, content occlusion and VoiceOver order. Spend an hour on it before committing to the
  overlay. If the inline treatment does not read as a *distinct* button, fall back to the overlay — that
  is the owner's stated shape and it wins on tie.
- **The sheet** (`.presentationDetents([.medium])`, hosted at root on its own `Color.clear` background —
  RootView is at its documented four-modifier cover ceiling). Actions first, ordered by frequency, every
  one of them wiring to a surface that already exists:

  | Row | Opens |
  |---|---|
  | **Start a run** — full-width, the only filled row | the existing free-run launch path |
  | Start something else | `SportPicker.swift` |
  | Log a workout | `LogWorkoutView` / `LogActivityView` |
  | Log a meal | the Fuel composer |
  | How I'm feeling | `CheckinSheet`, and `InjuryReportSheet` behind it |

  Then one quiet **Jump to** strip in `inkTertiary` caption: **Awards · Heatmap · Exercise library ·
  Notifications · Settings**. Only rarely-visited destinations go here. **Nothing that needs daily traffic
  may live in this strip** — a destination behind a menu gets a fraction of a tab's visits, which is the
  entire reason Fuel keeps its tab.
- **Today's deck keeps its Start, unchanged.** The deck's Start is *prescription-aware* — it carries
  `startTitle`, `goalControl` and today's session — while the button's is global. Duplication is correct
  here and the deck's own doc comment ("Start is the only filled element so the hierarchy never competes")
  still holds. **Nobody deletes the deck hero when this lands.** The deck's three-thoughts rule is
  untouched, so T1.1's Week One row is unaffected.

**Hazards — audited, and smaller than first written.** The whole `.profile` tab surface is **four
references**: `Route.swift:22` (title), `Route.swift:32` (`systemImage`), `RootView.swift:32` (the DEBUG
launch arg) and `RootView.swift:437` (`screen(for:)`). Because the shell is
`ForEach(AppTab.allCases) { Tab(...) }`, deleting the enum case removes the tab with no other shell edit.

1. **The `--profile-tab` DEBUG launch arg** (`RootView.swift:32`) is the real breakage, not persistence.
   Three UI suites pass it: `AwardsGalleryUITests` (with `--profile-highlights --awards-gallery`),
   `ImmersiveRouteMapUITests` (with `--profile-open-run`) and `ProfileGridUITests`. **Fix in the same
   commit:** keep the arg, return `.today`, and set `showProfile = true` so the tests still land on
   Profile. Do not delete the arg.
2. A floating overlay must not occlude the last row of any scroll view — add bottom content inset on all
   four tabs. The live-run screen is unaffected: it presents as a cover *over* the shell.
3. VoiceOver order — the button must not read before the tab bar.

> **Two corrections to earlier drafts of this item, both verified.** There is **no persisted tab
> selection** — `RootView.swift:27` is plain `@State` initialised from DEBUG launch args, with no
> `UserDefaults` anywhere, so a stranded `"profile"` raw value cannot happen. And there are **zero
> `selection = .profile` assignments** in the tree; the coach-nav switch (`:162-177`) never targets it and
> `momentum://today` is the only URL host (`:333`). The earlier "13 UI test files" estimate was the count
> of files mentioning any tab name; **three** actually break.

**How to build it — three commits, risk-ordered, each independently revertible.**

The core decision is to **route, not re-present.** All five actions already have owners inside
`TodayView`'s presentation stack (`startFree()`, `SportPicker`, `LogWorkoutView`, `CheckinSheet`).
Hoisting them into `RootView` would duplicate that logic and push against the documented four-modifier
cover ceiling. `AppRouter` already exists for exactly this job — its doc comment states the problem
verbatim: *"a runtime 'jump to another tab's screen' has no push mechanism — what it needs is a value."*

- **Commit 1 — the sheet, nothing user-visible.** Add a `QuickAction` enum
  (`startRun · startOther · logWorkout · logMeal · checkIn`), one field `var pendingAction: QuickAction?`
  on `AppRouter` under the same **consume-then-nil** contract the file already documents, the consumer in
  `TodayView`, and `QuickActionsSheet.swift`. Reach it behind a DEBUG launch arg (`--quick-actions`) to
  verify each row lands in the right owner. The shell is untouched; blast radius is zero.
- **Commit 2 — mount the button. Still five tabs.** This is where the value lands: Start becomes reachable
  from Plan, Progress and Fuel. Try `tabViewBottomAccessory` first — it is a plain
  `@ViewBuilder content:` modifier on `tabs` (two overloads in the iOS 26.2 SDK, the second taking
  `isEnabled:`) and it gives Liquid Glass and safe-area handling free. If it does not read as a *distinct*
  button, fall back to `.overlay(alignment: .bottomTrailing)` on `tabs` plus the bottom content inset from
  hazard 2. Attach the `.sheet` to the button's own container, never to RootView's modifier stack.
- **Commit 3 — Profile off the bar.** Delete the four references, fix the launch arg per hazard 1, and put
  the avatar in D.3's masthead leading accessory pushing `ProfileScreen(showsBackButton: true)` onto that
  tab's own stack. **There is no new presentation question to settle** — Today already does exactly this
  (`TodayView.swift:383-386`), and the push-not-sheet choice is a recorded user call from 2026-07-16
  ("the sheet read as a popup once Profile lost its tab to Fuel"). Profile has been through this
  transition once already.

**Ship 1 and 2 together; take 3 when D.3's masthead exists.** Commits 1–2 are pure addition. All the risk
is in 3, and separating them means a revert never costs you the button.

**Sequencing — this lands before the craft sweeps, not after.** T2.4 migrates eleven empty states and D.3
migrates three mastheads; both touch surfaces this change re-parents. Landing it after means redoing part
of both. **Order: D.3 (for the accessory slot) → T1.10 → T2.4.** Ships in **R2**.

**Why it wins.** Every competitor buries the start action one level down or dedicates the whole centre of
the bar to it. This puts the primary action in the best thumb position on the phone, reachable from every
tab, and simultaneously gives Awards and the heatmap — two of the app's most emotionally sticky surfaces —
their first root-level entry. It also costs a tab we were already paying for twice.

**Reads as success when:** runs started from a non-Today tab as a share of all starts, and Fuel's
daily-log rate holding flat or better after the bar changes. *Gated — if Fuel logging falls, the Jump-to
strip is not extended and the bar decision is revisited.*

---

## T2 — craft

*The engines are tested and the copy is careful. The shell is not: **194 button sites give no press
feedback**, a marathon PR feels byte-identical to tapping Start, the most-used secondary text colour fails
AA-large at 2.63:1, and the app **refuses the top four Dynamic Type sizes**.*

> **Honest reframe.** Four of T2's six items are **remediation** — defects that make the app feel unfinished.
> That is worth doing and is not the same as craft. There is not one *authored moment* in the seventeen T0/T1
> items. If a designed release is the goal, the authored moment has to be named separately and owned — see
> the strategic question above.

### T2.1 · Feedback: Every Tap Answers, Every Celebration Lands  `[M]`

**194** `.buttonStyle(.plain)` against **3** real uses of `PressableScaleStyle`, while `Haptics` fires **226**
times. A tap that buzzes but does not move reads as a bug. And `Haptics.swift:15` and `:19` show
`celebration()` is byte-identical to `success()` — both
`UINotificationFeedbackGenerator().notificationOccurred(.success)`; `celebration()` and `milestone()` (`:17`)
both carry *"Placeholder until a CoreHaptics pattern is authored."*

**Press styles.** Promote `PressableScaleStyle` unchanged — it already solves the documented scroll-vs-tap bug
via the button's own `configuration.isPressed` rather than a simultaneous `DragGesture`
(`SelectionCard.swift:100-107`). `.pressable` = scale 0.97; `.pressableRow` = scale 0.985 plus **0.82
opacity, folded in from `ProfileGrid.swift:496`** rather than minting a third literal. Animate with
`Motion.lively`. Transform + opacity only, so the 60fps bar holds on Today where the body re-evaluates
continuously under a panning Mapbox map. Reduce Motion drops the scale and **keeps** the opacity dip —
opacity is not motion, and removing all feedback for those users is the wrong reading.

**Sweep** ~160 live sites, Today first (highest tap volume). **Skip `Features/Social/*`** (~23 sites, dormant
by decision) and deprioritise `OnboardingFlow`'s 15. `.plain` survives only where the label already animates
its own press state (`SegmentedCapsule`) or the button is a non-visual hit target, **each with a one-line
comment**. **Grep for `.buttonStyle(.plain)` nested inside another Button's label before sweeping.** Verify
the non-negotiable case: a scroll-drag starting on a Today deck row must still cancel the press — that is the
exact bug `PressableScaleStyle` was written to fix.

**Haptics** (rewrite internals behind the existing API; all 226 call sites untouched), `CHHapticEngine`:

| Pattern | Spec |
|---|---|
| `celebration()` | rising two-tap: transient t=0.00 (0.6/0.3) → continuous t=0.06–0.34, intensity 0.30→0.90 at sharpness 0.2 → closing transient at **t≈0.52** (1.0/0.6), matching the checkmark's completion (`CompletionCelebration.swift:135-136`: a 0.18 s delay plus a 0.34 s draw). The beat's full budget is `duration = 0.99` with `handoff = 0.73` (`:36`, `:40`). |
| `milestone()` | soft triple transients at 0.00/0.09/0.18, 0.5/0.35 — feelable through a running-belt phone, never an alarm |
| `award()` | celebration plus a 0.5 s tail at 0.25/0.1, played under `AwardUnlockView`'s sheen so the sheen has a physical correlate |

**Lifecycle is the only real hazard:** lazily create the engine, install `resetHandler` and `stoppedHandler`,
re-prepare on every play — the `VoiceCoachService` ducking session **will** interrupt it mid-run, and an
un-re-prepared engine silently stops playing. Guard on `capabilitiesForHardware().supportsHaptics` **and fall
through to the current `UIFeedbackGenerator` implementations so the simulator and older hardware keep
working**. Do **not** suppress under Reduce Motion — haptics are not motion, and CoreHaptics already honours
the system haptics setting. **Physical device sign-off required; this cannot be regression-tested.**

**Why it wins.** Bevel — a hardware-free app whose entire moat is taste, and which Whoop sued in March 2026
over look-and-feel rather than features — earns the compliment "clean, minimal, highly responsive… less like
a spreadsheet and more like a refined, intuitive dashboard" (App. B). Responsiveness is a named, defensible
asset in this category, and nobody in the teardown has authored haptics.

**Reads as success when:** it exists. *Health check.*

---

### T2.2 · Fix The Most-Used Secondary Text Colour  `[S]`

`inkTertiary` light `#9AA0AC` measures **2.63:1** on `#FFFFFF` and **2.41:1** on `#F4F5F8` — failing AA
(4.5:1) and even AA-large (3:1). Dark `#7A7A7A` is 3.92 / 3.39. **519 call sites** (second only to
`Theme.ink`'s 629), mostly 13pt caption and 11pt label — every eyebrow, every chart caption, every stat
label.

**Commit 1** (first, so the colour edit is a clean one-liner): grep `inkTertiary.opacity(` — 21 sites — and
move every non-text sub-0.6 use to `Theme.hairline` (`TodayView.swift:1118` uses it as a hairline substitute
stroke; `ConsistencyHeatmap.swift:52/:124` as empty-cell fills). After this, **`inkTertiary` means secondary
TEXT and `hairline` means faint STRUCTURE**.

**Commit 2** — one file:

| | Current | Proposed | On background | On surface |
|---|---|---|---|---|
| Light | `#9AA0AC` | **`#6E7480`** | 2.63 → **4.69** | 2.41 → **4.31** |
| Dark | `#7A7A7A` | **`#8A8A88`** | 3.92 → **4.87** | 3.39 → **4.21** |

Preserve the hue relationship (light cool-neutral, dark warm-neutral) so no other token needs re-tuning.
Write the reservation into `Theme.swift`'s doc comment — *inkTertiary is for captions and labels, never body
copy*. Separation from `inkSecondary` (`#5B606B`, 6.31:1) survives at 4.69 vs 6.31 — still a legible
three-step ink ramp. Do **not** re-tune `inkSecondary` in the same pass; change one variable so any
regression is attributable. Safe by construction: `inkTertiary` is never used on a fixed-appearance canvas
(route snapshots and share cards use `Theme.inkOnFixedLight`). **Screenshot-diff Progress (densest caption
load) and Today's deck, light and dark, before and after.**

**Why it wins.** Crispness at 11pt is what makes a data-dense page read as authored rather than tolerated.
The serious tier lost on exactly this — Intervals.icu's own power users opened a forum thread titled *"It's
time to fix the UI!"* (App. B). The stated arbitrage is "take Garmin's honesty, render it with Oura's calm",
and you cannot be calm at 2.6:1.

**Reads as success when:** every `inkTertiary` text site clears 4.5:1 on `background`; the `surface` column
lands at 4.31 / 4.21 and **that shortfall is recorded as accepted**, or both hexes are re-derived against
`surface` (roughly light `#696F7A`, dark `#919191`). *Health check.*

---

### T2.3 · Restore The Earned-Iridescence Rule  `[S]`

**70** `IridescentMaterial` instantiations (72 grep hits including the declaration at `TodayView.swift:1687`),
**seven** of which attach the reward colour to states that are not rewards: the Grid/Highlights tab indicator
(`ProfileGrid.swift:32` — a **selection**), the unread dot (`NotificationsView.swift:88` — something the app
is **telling** you), the calibration toggle (`OnboardingFlow.swift:747` — an **input**), a 72pt disc behind
"Your map is empty" (`PersonalHeatmapView.swift:92` — an **absence**), two chat chips
(`CoachChatView.swift:197/:408`), and `RacePredictionCard`'s border (`RaceInsightCards.swift:51` — a
**projection**, per T1.6). `Theme.IridescentOpacity` — written explicitly *"to name the levels that were
scattered as raw literals"* — has one value call site while ~30 raw literals across 14 values remain,
including `CoachChatView`'s hard-coded 0.22 and 0.25, which are literally the `.chip` and `.glyph` cases.

**The test, stated so it cannot be re-litigated screen by screen:**

> Iridescence marks a thing the athlete **earned** — progress rings, PRs, streaks, completed plan checkmarks,
> on-pace step borders, the rest-timer ring, block-renewal cards, the plan reveal, and crown medallions (per
> T0.4). It never marks a thing the athlete **selected**, a thing the app is **telling** them, or a thing that
> is **absent**.

**Demotion mapping:** selection indicator → `Theme.ink`; unread dot → `Theme.ink` (high-contrast reads as
*more* urgent than a soft pastel, so this improves the affordance too); calibration toggle → ink fill matching
every other `SelectionCard`; heatmap empty disc → `Theme.hairline` with an `inkTertiary` glyph, **no disc**;
chat chips → `Theme.hairline` stroke on `Theme.surface`; `RacePredictionCard` border → `Theme.hairline`. **No
substitute accent**, and never `Theme.purple` (whose own rule, the route-purple PRO badge, must not blur
either).

**Tripwire, same commit.** A Swift Testing case scanning for
`IridescentMaterial|IridescentView|Theme.iridescent` outside an allowlist, with a diagnostic naming the
three-clause rule so it **teaches** rather than blocks. **Extend the pattern to `IridescentView`** —
`PaywallView`'s background uses `IridescentView(intensity: 0.72)` (`:171`), a third symbol with 22 sites a
material-only scan would never see. Allowlist the two sanctioned exceptions (Podium tier border, `PaywallView`
background) from day one or the test fails on landing. Scope to those symbols only; the opacity-token sweep
lands separately.

> **This is a new mechanism, not a copy.** It is the same *spirit* as `CoachVoiceTests` (a teaching diagnostic
> rather than a bare assertion), but `CoachVoiceTests` asserts on produced strings at runtime and **there is
> no source-scanning test in this repo today**. A test bundle in a simulator has no stable path to the repo
> tree, so decide the source-root strategy (a `#filePath`-relative walk) and size it as new work. The same
> qualifier applies to T2.6's and D.5's proposed scanners.

**Token sweep (separate commit):** map each raw literal to the nearest `Theme.IridescentOpacity` case **by
intent, not by arithmetic proximity** — a chip backing goes to `.chip` even if it was authored at 0.25.

**Reads as success when:** the tripwire is green and the count of non-earned sites is zero. *Compliance — this
enforces a stated CLAUDE.md non-negotiable.*

---

### T2.4 · One Empty State, Twelve Times  `[M]`

**Twelve surfaces each define their own** — ten named `emptyState` members (`FuelHistoryView:192`,
`SportPicker:123`, `ExerciseDetailView:130`, `PlanView:944`, `RacePickerSheet:225`, `BalanceCard:428`,
`CommunityView:278`, `StrengthLiveView:215`, `PersonalHeatmapView:89`, `NotificationsView:112`) plus inline
states such as `ProgressView.notEnoughData:1569` — with glyph sizes 15/22/28/32/34 plus BrandMark at 64 and 72
and a 72pt iridescent disc, three title fonts and three spacings. **Two carry no glyph at all**
(`RacePickerSheet`, `BalanceCard`), which the component must accommodate. A new user sees empty states more
than any other class of screen.

**Component:** `EmptyState(glyph: .symbol | .brandMark | .none, title:, body:, action:?, density: .page | .card)`.

- `.page`: glyph 44pt `.light` weight in `inkTertiary` → 20pt gap → title in `Font.display` in `Theme.ink` →
  8pt gap → body in `Font.rounded(caption)` in `inkTertiary`, max 2 lines, centred, 260pt max width → 24pt
  gap → `OversizedButton(.outline)` if an action exists.
- `.card` (nested): glyph 22pt, smaller title, no CTA, same rhythm at 0.6 scale.

**⚠️ Add a third variant, or the sweep buries the best idea in the app.** The specced form structurally cannot
hold a specimen — so the migration would standardise twelve surfaces onto the generic empty state while
`SpecimenOverlay` (ghosted real content at 8% grey with an EXAMPLE tag and a teaching line) stays stranded in
four Health call sites. Add `EmptyState.specimen(teaching:content:)`, delegating to the existing `View`
extension (`HealthStates.swift:136-140`) so there is one renderer, and name the surfaces that must use it:
ProgressView's empty trends, `ExerciseDetailView`, `FuelHistoryView`. **The choice is driven by whether the
surface has content worth ghosting, not by a default** — and budget each specimen as *authored fixture data*
(`Specimen.balanceWeek` is a hand-built 30-day series, `HealthSegmentView.swift:857`).

**Semantic glyph split:** `.brandMark` where the **app** has nothing yet and the athlete is invited to start it
(Plan, Profile); `.symbol` for states merely empty right now. **Document the EMPTY vs UNAVAILABLE split**: the
four existing `ContentUnavailableView` uses (`ExerciseLibraryView:67`, `TimedSaveView:37`,
`StrengthSaveView:47`, `CardioSaveView:71`) are **correct and must not be migrated** — `CardioSaveView`'s error
path in particular must stay one, because a dead-end error on a `fullScreenCover` is a trap.

**Motion:** entrance via `.reveal(once:)` so an empty state greets rather than tolls on every tab flip.
**Monochrome:** ink and `inkTertiary` only. **No-shame:** body copy states what will fill the space, never what
the athlete failed to do — the shipped "Your sessions land here as you train" is the model. **Do not force a
CTA where there is no honest action**; "You're all caught up" should stay a dead end, because that is the
correct state.

**Scope: migrate eleven, not twelve** — skip `CommunityView` (dormant; touching dormant files invites
parallel-session merge pain). **Sequence after T2.3** so the heatmap's iridescent disc falls out for free, and
**after T1.10**, which re-parents Profile and gives the heatmap and Awards their first root-level entry —
migrating those empty states before the bar changes means doing part of this twice.

**Why it wins.** We already have the best empty-state *thinking* in the category and get no credit for it:
`SpecimenOverlay` renders zero-data charts as ghosted specimens with a teaching line, so day one already looks
like the product. **Nothing in Whoop, Oura, Garmin or Runna does this.** The problem is that this idea lives in
one segment while eleven other empty states were each solved from scratch.

**Reads as success when:** it exists and is consistent. *Health check.*

---

### T2.5 · Accessibility  `[M]`

**Problem.** T2 calls itself enterprise-grade and its accessibility content was one colour token.
`MomentumApp.swift:122` **clamps at `DynamicTypeSize.accessibility1`, refusing the top four accessibility text
sizes**, under a comment (`:114-121`) naming the three layouts that broke: Today's primary button truncating to
"Start…", Progress's streak pill landing on the title, VO₂ MAX rendering as "3…". Those are three layout bugs
being paid for by every low-vision user. Grep for `reduceTransparency|differentiateWithoutColor|AXChartDescriptor`
returns **zero** — across every `momentumGlass` site including the live-run panel and Today's floating header,
and across eleven files importing Charts. The route map and heatmap have **no accessible representation at
all**: `mapSafeTap` labels the chrome, not the content.

**Four deliverables, ordered by coverage per unit cost.**

1. One `@Environment(\.accessibilityReduceTransparency)` branch inside `MomentumGlassModifier`, falling back to
   `Theme.surface` plus a hairline — **one file, every glass site at once**.
2. `accessibilityElement(children: .ignore)` plus a summary label on `RouteMapView` and `PersonalHeatmapView` —
   *"4.8 mile loop, 9 outings, best 41:12"* / *"1,284 miles mapped across 2026."* The map is the app's hero
   surface and is currently invisible to VoiceOver.
3. `AXChartDescriptorRepresentable` on the Trends charts, starting with the ones `MetricInfoButton` already
   writes an explanation for, so the descriptor **reuses copy that exists**.
4. Fix the three layouts the clamp comment names — a VStack fallback on Today's CTA at
   `dynamicTypeSize >= .accessibility1`, the streak pill, the hero stat — then **raise the clamp one step at a
   time and re-screenshot**, rather than committing to AX3 as a number up front.

**Deliberately not included:** a `differentiateWithoutColor` path for the HR zone chips — the shipped zone table
already carries Z-number, name, purpose and bpm range as text (`ProgressView.swift:947-963`), so colour is not
the sole encoding. Spend that effort on the chips' white-on-colour numeral (T0.3) instead.

**Why it wins.** Argue it as craft and it will get built that way. A page that survives XL type and reads
correctly under VoiceOver is the same quality signal T2.2 makes about 11pt contrast — and the map summary label
is a genuine category first, because nobody else's route map says anything at all.

**Reads as success when:** the clamp is raised at least one step with no layout regression, and the map has a
VoiceOver label. *Gated on (4) — if the layouts cannot survive one step up, the clamp stays and the reason is
recorded. (1)–(3) are compliance.*

---

### T2.6 · The display ramp  `[M]`

Pass 1 killed this and **stated the corrected version in the same cell that killed it**, which is mis-filing,
not a decision. 112 `.display(N)` literals across 22 distinct sizes; the modal size is **20** at 27 uses, and
`Theme.FontSize` has no 20. Re-derive the ramp so **the modal sizes are the steps**, extend `Theme.FontSize`
rather than adding a parallel enum, land as a mechanical map with a per-screen screenshot diff and a
source-scanning test once complete (same new-mechanism caveat as T2.3). Note that `BrandFont.spaceGrotesk`
collapses `.black/.heavy/.bold/.semibold` to **one cut** (`Typography.swift:39-41`), so weight is not a
substitute for size. Sequence after T2.2 and T2.1 — same craft lane, lower priority than a measurable contrast
failure and ~160 unstyled button sites.

**Reads as success when:** every `.display(N)` literal resolves to a `Theme.FontSize` step and the scanner is
green. *Compliance.*

---

## Map & route

*`M.*` and `D.*` are acceptance-criterion items and carry no metric block.*

### M.1 · Ghost trace on Today's map  `[S]`

Draw the last run's line under the puck on the hero surface, which currently renders one dot.

**⚠️ The original opacity spec inverted the mechanism.** The shipped finished-route renderer separates the line
from the basemap with a **6pt white casing under a 4pt gradient** (`RouteMapView.swift:162-169`) precisely
because a line needs separation from road geometry carrying its own casings. Substituting 0.45 opacity
*reduces* contrast against the very thing it must separate from — on the hero surface, in daylight. Respec as a
**separation spec**: full-opacity desaturated route ink at 2.5–3pt with a low-contrast casing in a neutral that
is **not white** (white is the live/finished route's signature, which is what the "reads as live" objection was
actually protecting), keeping `lineEmissiveStrength(1)` so night-lit Standard styles don't render it near-black.

Build from the most recent GPS workout's `gps.routeCoordinates(type:)` through `RouteSmoothing.smooth`, as a
single `LineLayer` with ids `today-last-src`/`today-last-line`. **Ramp visibility by zoom** — `lineOpacity`
interpolated from 0 below z12 to full at z13.5 — so it does not clutter a zoomed-out map. Add it inside
`.onStyleLoaded` on **every** style load (a reload wipes every runtime source and layer — the documented "heat
areas went away" bug). Insert below `location-indicator` found **by type**, the trick `syncRouteLayers` already
uses. Build coordinates in `.task(id: workouts.contentSignature)`, never in `body`. Tap-to-open via
`queryRenderedFeatures` inside a `mapSafeTap` (SwiftUI Buttons lose the gesture race to Mapbox's UIKit
recognizers). **Critical:** must not activate the puck or a `followPuck` viewport — pure GeoJSON needs no
location permission, so an un-located athlete who has trained before still sees their own city.

### M.2 · Offline honesty — the chip, not the tile store  `[S]`

Observe `mapboxMap.onMapLoadingError` for `.tile` errors in `CardioTrackingView`; three failures inside 20 s
raises one dismissible glass chip beside the GPS pill: *"Offline map · your route is still recording."* Neutral,
never repeated in a session. **The athlete's real fear when the map goes grey is that the run is not being
captured**, and capture is unaffected, so say so. Defer `OfflineManager`/`TileStore` until this chip's telemetry
shows real volume, and first measure what Mapbox's own on-disk cache already covers for an athlete repeating
home routes.

### M.3 · The heatmap as a poster  `[M]`

`HeatCell` already carries `count` and the renderer reads only the normalised `weight`, so *"you've been here 47
times"* is one property access away. Tap converts to a coordinate, finds the nearest cell within 40 m (a linear
scan is fine — a heavy history is thousands, not millions, and it runs once per tap), and renders a small glass
callout: "You've been here" / "47 times" in display tabular over a caption. **No ranking, no percentile, no "top
5% of your streets"** — it is a memory, not a scoreboard. Export as in T0.4. **Do not add date/sport filters**:
they multiply the content-signature cache key space on a surface whose performance depends on binning off-actor
and caching on one signature.

### M.4 · Live elevation gain  `[S]` — a layout decision, not a line count

`LiveSnapshot.elevationGainM` is populated on every snapshot (`:53, :94, :99, :185, :219`) and rendered nowhere;
`CardioViewModel` doesn't even expose it. But the stat row is one `HStack(spacing: Theme.Space.xl)` already
holding four conditional stats at `.display(20, weight: .heavy)` with **no `minimumScaleFactor`**
(`CardioTrackingView.swift:567-579`). So: an explicit **priority order capped at four visible stats** — Time and
the hero value permanent; elevation displaces cadence once gain > 20 m (so barometric noise never renders as a
climb); HR takes the fourth slot when a strap reports. **Acceptance criterion: legible at four stats on an SE.**

### M.5 · The rejoin-bearing note  `[S]`

Document at the rejoin-arrow call site that its rotation is a **true-north bearing** depending on the live map
being north-up. If course-up ever ships, the arrow must render
`rotationEffect(.degrees(rejoinBearing − cameraBearing))` or it points into a hedge.

### M.6 · Map legibility check  `[S]` — acceptance criterion, ships in R2

A 5 styles × light/dark screenshot matrix for route line, ghost trace and heatmap. **Gates M.1, T0.1b's route
sheet, and T0.4's heatmap poster** — which is why it is pulled into R2 alongside the poster rather than left in
the map lane.

---

## Design refinements

### D.1 · Zoom transition on the profile grid  `[S]`

The most screenshot-able interaction in the app is a hard cut: `ProfileScreen.swift:245` presents the pager as a
plain `.fullScreenCover`, and there are **zero** `.navigationTransition`/`.matchedTransitionSource` uses in the
tree despite iOS 18 being the minimum. Five lines: `@Namespace` on `ProfileScreen`,
`.matchedTransitionSource(id: workout.id, in: ns)` on the tile, `.navigationTransition(.zoom(sourceID:in:))` on
the destination. Key on the `PersistentIdentifier`, never an array index — a `LazyVGrid` reorders. The persisted
`RouteSnapshotter` image is provably the same artwork on both sides (`Workout.swift:81` stamps
`mapSnapshotVersion`), which is what makes a zoom read as **physical** rather than decorative — but confirm
`WorkoutSnapshotHealer` has settled before the transition rather than racing it, because a mid-flight re-render
looks worse than the hard cut it replaces. Reduce Motion degrades to a crossfade for free. Ship this **one** site
first and evaluate.

### D.2 · Branded launch  `[S]`

`project.yml:105-106` is `UILaunchScreen: UIColorName: background` — no image, no wordmark, even though
`WordmarkBlack`/`WordmarkWhite` already ship. Create a `LaunchWordmark` imageset (wordmark ~40% of image width on
transparent, generous padding — `UIImageName` renders centred and aspect-fit with **no layout control**, so the
padding *is* the layout), add `UIImageName` beside the existing `UIColorName`, then `xcodegen generate`.

> **Unflagged trap, decide deliberately:** the launch screen resolves its asset appearance from the **system**
> trait, but the app ships a user-facing appearance override (Settings → Appearance). An athlete on a light phone
> who forced Dark gets a black-on-white launch wordmark handing off to a charcoal app. Either accept it (it
> already affects the existing `UIColorName`) or make the asset appearance-agnostic — a mid-gray wordmark reads
> acceptably on both. Decide now, don't discover it in review.

Test on SE and Pro Max, and **delete the app between runs** because iOS caches the launch screen aggressively.
Treat the animated handoff overlay as optional and cut it if it costs more than an hour — the static asset
carries most of the perceived-speed win and the overlay adds a first-frame code path to the app's most sensitive
surface.

### D.3 · Extract the masthead, and pin Plan's title  `[M]`

Four header mechanisms each claim "the shared masthead language" in their own comments. The **design** is a
recorded 2026-07-16 user call (small centred lowercase display-face title with flanking accessories); only the
plumbing differs — and one difference is a real bug: `PlanView.swift:112` puts the header **inside** the
ScrollView's VStack so the title scrolls away, while Progress's is fixed and Fuel's uses a real toolbar principal
item. Build a `Masthead` component reproducing the **current** design exactly on `ProfileScreen`'s
`safeAreaInset(edge: .top)` mechanism; migrate Plan, Progress and Fuel, one tab per PR. **Do not change
alignment, case or size** — that was settled deliberately. Add one native-feeling behaviour: the bottom hairline
fades in on scroll, opacity bound to scroll offset 0 → 1 across the first 12pt of travel, crossfaded over
`Motion.fast`, **never animating height**. Add the optional eyebrow slot — `PlanView`'s `planContextLine` already
computes exactly that string. Leave Profile alone (its header has no title by design) and Today alone (floating
glass over a live map, a deliberate exception that belongs in the component's doc comment). Re-verify Fuel's
`.principal` accessibility labels and Pro-gated toolbar actions survive the move off the system toolbar.

> **T1.10 depends on this.** The masthead's **leading accessory slot carries the profile avatar** on Plan,
> Progress and Fuel once Profile stops being a tab — one component, four surfaces, one entry point. That makes
> D.3 a prerequisite for T1.10 rather than a competitor for the same surfaces, and it is why both ship in R2 in
> that order.

### D.4 · Dark mode depth — inside the card sweep, not standalone  `[M]`

`Theme.Elevation`'s doc comment still reads "Light mode is the hero aesthetic (forced .light)", stale since dark
mode shipped 2026-07-10; both tokens are pure black at 5%/10%, invisible against `#1E1D1B`. But dark mode is flat
because **165 inline `fill(Theme.surface)` backgrounds never call `.elevation` at all**, not because the values
are wrong. So: (1) fix the stale comment today, it's free; (2) decide which container is canonical — `healthCard()`
has 3× the adoption and better modifier ergonomics, so the cheapest honest path is making it a thin wrapper over
`Card(style:)`; (3) migrate **Progress and Plan only** (the two with documented three-weights-in-one-scroll
inconsistency, `ProgressView.swift:1727-1733`) and stop — the remaining files are cost without perceptible gain;
(4) as the **last** commit of that sweep, make `ShadowToken` appearance-aware (dark card black 40% r10 y3, dark
float black 55% r22 y8) and add a 1pt top inner stroke at white 6% masked to the upper half — a shadow says "this
is above", the highlight says "this catches light", and charcoal-on-charcoal needs both. **Do not tint the shadow
warm**; a tinted shadow reads as a coloured glow, and glow is reserved for the sanctioned Health wash. Tune on
device, not in a colour picker. Also add the `.plain` style (surface + hairline, for genuinely nested cards) and a
`header:` slot, both genuinely absent, and replace `ProgressView`'s `warmup` — three bare RoundedRectangles at
420/150/220pt with no hairline — with real Card wrappers containing `.redacted(reason: .placeholder)` skeletons,
the pattern five other surfaces already use.

### D.5 · Close the motion vocabulary  `[M]`

152 `withAnimation` sites: 60 spelled `withAnimation(Motion.…)`, 12 more reaching a token through a ternary
(`withAnimation(reduceMotion ? nil : Motion.standard)`), and **80 raw literals**. `duration: 0.2` appears 22
times with **no token**; 0.15 (×10) and 0.25 (×10) duplicate `Motion.fast` and `Motion.normal` exactly. Separately
12 `.snappy` and **4** `.smooth` animation curves coexist with `Motion.lively`/`travel` — a naive `.smooth` grep
also matches `RouteSmoothing.smooth`/`GPSKalmanFilter.smooth`, so **leave those alone**.

Add `Motion.quick = 0.20` (22 sites already reach for it by hand), map 0.15/0.20/0.25 onto fast/quick/normal,
collapse `.snappy` → `Motion.lively` and `.smooth` → `Motion.standard`, and add a source-scanning test banning raw
`withAnimation(.` literals outside `Motion.swift` (same new-mechanism caveat as T2.3). Review the live-run and
rest-timer sites **on device** — swapping `.spring(response: 0.3)` for `Motion.lively` (0.4) is a real timing
change on surfaces that are felt under motion.

> **Do not** ship a blanket `[.medium, .large]` sheet default: of 55 sheets, the 35 that declare nothing are mostly
> full NavigationStack forms where a resting medium detent is a regression — that is 55 judgement calls, not a
> house style. Build `.momentumSheet()` carrying only the genuinely uniform parts (drag indicator +
> `Theme.Radius.sheet` + presentation background) and let each site keep its own detents. Note that
> `ProgressView.swift:2111`'s `[.large, .medium]` is **not** a bug: `presentationDetents` takes a `Set`, so the
> order is inert and the sheet already rests at `.medium`. Normalise the spelling for readability only. If a
> `.large` resting detent is actually wanted, it needs the `presentationDetents(_:selection:)` overload with a
> `Binding` seeded to `.large`.

### D.6 · Lock Screen and Control Center  `[M]`

`TodayWidget.supportedFamilies([.systemSmall, .systemMedium])` — two families, no accessory. Meanwhile
`WatchComplications.swift:114/:191` already ships four accessory families on watchOS. **Three of them port to
iOS** — `.accessoryCircular`, `.accessoryRectangular`, `.accessoryInline`. `.accessoryCorner` is watchOS-only
(`@available(iOS, unavailable)`) with no Lock Screen equivalent; **do not budget for it.** Accessory widgets render
in the system's tinted/monochrome mode, so the design must read entirely through fill and shape: **completed days
filled, planned days rings**, and the earned accent simply does not exist at that size — which makes this safe on
the monochrome rule by construction. Then the ControlWidget — but note `momentum://start` does **not** exist
(`RootView.swift:331` handles only `momentum://today`), so a new deep-link case is required.

> **Cut** the interactive `Button(intent:)` in the medium widget: starting a GPS run needs foreground location, a
> Live Activity and the `CardioViewModel`, so the intent must set `openAppWhenRun = true` and becomes a deep link
> wearing an AppIntent costume — all the plumbing, none of the payoff.

Keep the day-roll guard and **test on a throwaway sim — App-Group snapshots survive uninstall in the simulator and
have burned this code before.**

---

## Packaging — free vs Pro

> **Under the hard gate, this table describes the post-lapse experience and the App Store description's honesty,
> not a free tier — nothing is reachable pre-purchase.** "Free" here means: still working when the entitlement
> stops.

> **The default is FREE, and that is a mechanism, not an intention.** `Services.swift:220` —
> `var requiresPro: Bool { true }` — means the `Feature` enum lists only paid capabilities, so **anything not added
> to that enum silently ships free**. Any new Pro capability requires a new `Feature` case **plus** its `placement`
> string in the same PR.

| Capability | Tier | Why |
|---|---|---|
| GAP · lap button · Easy Means Easy parts 1–2 · GPX export | **Free** | T0's organising claim is unsellable. A correction that stops the app telling a runner they got slower must keep working after the entitlement stops, or a reviewer gets the sentence *"they charge you not to be lied to."* |
| Route import (T0.0) · route identity verdict | **Free** | It is the on-ramp. A wall here defeats the switching argument. |
| Route library + "Run it again" | **Pro** | Accumulated-history value; the free verdict sentence still lands on every run. |
| Trim · heatmap poster | **Free** | Correcting your own data and exporting your own memory are both trust primitives. |
| Share cards (verdict, award, heatmap poster) | **Free** | A card that can't be made isn't a channel. |
| Week One · Sunday review (read) · block retrospective (read) | **Free** | It is the athlete's own week. |
| "Apply next week's proposal" · Life Happened rebuild · Race Week card · moving projection | **Pro** | The app-wide boundary: **free to see, Pro to act.** |
| **Restore** | **Free** | T1.7's win-back copy and T1.8's positioning both already assume it. If the decision goes the other way, T1.7's lapsed rung must be rewritten in the same PR. |
| Live effort ceiling (T0.3 part 3) | **Pro** | Real-time coaching is the paid promise, and it is gated on HR confidence anyway. |

`T2.*`, `D.*`, `M.1`, `M.2`, `M.4`, `M.5` and `M.6` are **exempt by construction** — you do not put a tier on a
WCAG fix.

---

## Engineering gates

**1 · Migration contract.** Every new property on an existing model is **optional-or-defaulted**, per the shipped
precedent `LocationSample.pausedSpan` (`Workout.swift:133-139`) — so `trimmed`, `isManual`, `gapSPerKm`,
`importedFrom`, `SavedRoute` and `Workout.route` need **no** `VersionedSchema`. Introduce `SchemaV1`/`SchemaV2`
and a `SchemaMigrationPlan` when the first **non-additive** change lands, which on this roadmap is T1.8 Phase D's
`updatedAt`/`deletedAt` sweep, with a test that opens a v1.1 store fixture and asserts it migrates. Measure the
`LocationSample` column-add on a seeded 500-run store and state the launch-time budget. **W0.1 lands before any of
it.**

**2 · Test gate.** The unit suite (**1,315 tests in 151 suites, ~21 s of execution inside a
`test-without-building` run**, green as of 2026-07-28) and `PlanEngineInvariantTests` must be green on every push,
enforced by a **git pre-push hook that greps for "Test run with N tests"** — because `xcodebuild` exits 0 on a
Swift-Testing project even when the bundle never loaded. Before T2.1, T2.2 and D.4 land, name a must-pass UI subset
covering the swept surfaces and **explicitly exempt** the environment-dependent suites (auth, Mapbox tiles,
HealthKit, StoreKit sandbox) so the gate is meaningful rather than permanently red.

> **CI stays deleted.** A full GitHub Actions workflow was built and removed at the owner's instruction, and the
> reasons hold: solo checkout, a ~20-second local suite, metered runner minutes, and the one real hazard (parallel
> sessions sharing this tree) occurs **locally, before any push**. The pre-push hook is the right instrument.

**3 · Device matrix.** SE-class + Pro Max, light/dark, Dynamic Type at the shipped clamp. Items requiring on-device
sign-off: CoreHaptics patterns, the launch screen, `Motion` timing swaps on live-run and rest-timer, the live
effort ceiling, the lap bar's one-handed reach, M.6's style matrix.

**4 · Rollback.** A **revert commit per item**, not a DEBUG flag — DEBUG is compiled out of the shipping build.
T1.4 and T1.5 each ship alone (R5 and R4) with the revert SHA recorded. A crash-free rate above 99.5% must hold for
72 h before the next wave starts.

**Two standing constraints:** new Swift files require `xcodegen generate` before they build, and this checkout is
shared with parallel sessions — check `git status` first and never `git add -A`.

---

## Risks and obligations

| # | Risk | Position | Owner action |
|---|---|---|---|
| 1 | **EU distribution** | Everything below is conditional on it | Decide first |
| 2 | **EU AI Act Art. 50**, applicable **2026-08-02** (five days out) | One disclosure line on the coach entry point and on AI-authored plan rationale. Cheap — do it regardless of whether the "obviously an AI" exemption applies. Do not write any later content-marking date in as fact until confirmed | **Ship in W0** |
| 3 | **European Accessibility Act** | Microenterprise exemption is the likely position — **record it as a decision, not an oversight**. Accessibility is still funded, as craft, in T2.5 | Record |
| 4 | **Mapbox MAU + Supabase egress** | New cost drivers: T1.8's download direction, Phase A0's sample payload, M.1's ghost trace | Model before T1.8 Phase B |
| 5 | **App Review on T0.3's live HR ceiling** | The copy is training guidance ("ease back"), not a medical alert, and must stay that way | Copy review |
| 6 | **Name/trademark** | `APP-STORE-METADATA.md` records the listing LIVE in ASC since 2026-07-16 and v1.1 build 11 shipped — this is **exposure, not a submission blocker** | Assign a date |
| 7 | **Platform: Apple Health+ / Workout Buddy** | Largest risk to the Pro *narration* layer. Engines, plan authorship, route identity, export and no-shame survive | Monitor; see §0 |
| 8 | **Competitor response** | Perishable items are tagged and pulled forward. GDPR is the mechanism that will force Runna to open export | Watch T0.6's window |
| 9 | **Key person / single checkout** | One committer, one working tree, parallel sessions | Named, not solved |

---

## Kill list

**Effort-shaded route trace** — adds a sixth parallel colour system, and makes the app's signature hero image a
data visualisation by default; `RunCharts` already ships a per-split pace bar chart with the best split marked,
directly below the map. If it returns, it returns as an owner decision about whether the hero route line may carry
data colour at all.

**Beacon / live location sharing** — `PresenceService` is still a TODO stub; precise location would become readable
by an unauthenticated URL-holder, adding a security review, a retention obligation and a privacy-label change. iOS
17+ Check In and Find My already do the core job free. The zero-backend version, if the safety job needs an answer:
a "Tell someone" pre-run share-sheet row and a one-tap "I'm back" on finish.

**Find Me A Loop / route generation** — relitigates a product call made four days ago. Commit `f5bb257`
(2026-07-24) deleted `RouteSuggestionEngine`, `MapKitDirectionsProvider`, `LoopQuality` and Spots (~1,000 lines)
because the generated routes were lopsided and backtracking. With fewer than 3 GPS workouts there is no heat prior,
so first-run falls back to the bare routing-graph loop that was rejected. The same payoff is free by filling
`guideRoute` from routes the athlete already has (T0.1a).

**Aerobic-decoupling Trends card** — built and deliberately cut on 2026-07-17 with the reasoning in
`ProTrendsSection.swift:8-13`. `TrendAnalytics.decoupling` is *within-run* cardiac drift (first half vs second,
≥20 min), not HR-at-pace across months, so "four beats lower than in April" would be a **false claim**. The
headline already ships in a stronger, route-controlled form: `RunVerdict.swift:217`'s lower-HR rung.

**Dressing the tab bar** — `MomentumApp.swift:113` already sets `.tint(Theme.ink)`; SwiftUI defaults to `.fill`
symbolVariant for tab items; `UITabBarItem` ignores `.fontWeight` on a Label; and forcing an opaque background
under a Liquid Glass tab bar (`Glass.swift:40`) is the hand-drawn-bar regression the proposal's own spec warns
against. **This still stands, and is not what T1.10 does** — T1.10 changes the bar's *structure* (five tabs to
four, plus a global action button) and deliberately leaves its *finish* to the platform.

**WeatherKit conditions** — a paid entitlement plus a capability plus Apple's mandatory attribution/legal link in
the UI plus a network call keyed to the run's start coordinate plus two new stored fields, on a summary screen that
must never block. Ship GAP first: same emotional payload, zero new dependencies.

**Course-up map mode and ClimbPro-style climb guidance** — course-up rotates the canvas against our north-up map
identity **and silently breaks the rejoin arrow** (M.5). ClimbPro needs altitude on the followed route, and
`guideRoute` is `[GeoPoint]` (`CardioTrackingView.swift:17`) — structurally altitude-free regardless of what
`SavedRoute` stores. **Infeasible as specced**, not merely deprioritised.

**Shoe mileage tracking** — `CoachKnowledge.swift:169` genuinely gives advice the app can't help anyone follow, so
the diagnosis is fair, but it is category parity nobody switches apps for and it has an unsolved design hole:
HealthKit-imported runs never pass through a save screen, so a summary-screen attach point produces a counter that
silently undercounts and therefore **lies**. T0.0 does not fix this — it delivers geometry, not a save screen.

**Live indoor / treadmill mode** — the post-hoc treadmill log already ships and the GPS-denied branch already
offers "Start without route". Doing it properly needs a real `isIndoor` + `distanceSource` schema migration
(`indoor` currently reaches the model only as note **text**), and structured adherence reads GPS pace so
distance-based steps have no source indoors. Revisit before winter, with the migration budgeted honestly.

**Two-arc SPEED/ENDURANCE predictor decomposition** — `PlanFeasibility` already refuses to flatter a goal, already
has a distance × experience volume floor table, and already returns `realisticFinishS`, so the marginal gain is
presentation, not truth. `weeksForVolume`/`weeksForTime` are locals inside a nested closure collapsed by `max()` at
`:174`, so exposing them is an engine API change.

**B-race / second dated race** — `TrainingPlan` and `UserProfile` hold **one** `raceDate`, and
`PlanFeasibility.assess` is shaped around a single target. A schema plus engine change, not a row in a tray.

**Watch lap parity and watch strength sync** — **deferred on cost, not capability** (see T0.5). Both are real gaps,
both are separate projects requiring a paired device to verify, and neither may ride in on the phone lap button.

**Offline map region downloads** — *deferred, not killed.* Ship M.2's honest chip first, then measure what Mapbox's
own on-disk cache already covers before writing a region manager. A per-install multi-hundred-MB download is an App
Store storage complaint, a support burden and an unresolved Mapbox billing question under the MAU model.

**Route builder · segments with leaderboards · turn-by-turn · 3D flyover replay** — a draw-your-own builder is a
full editing product (snap-to-network, undo stack, waypoint manipulation, versioning) arriving *before* the follow
runtime it depends on has shipped to a single user. Leaderboards are structurally incompatible with **two**
non-negotiables at once — solo v1 and no-shame (someone must lose). Turn-by-turn needs MapboxNavigation, not an
allowed dependency. Flyover is Strava's own clearest gimmick: high first-use delight, near-zero repeat engagement,
and a swooping 3D camera over a purple line is exactly the register a ~95% monochrome system exists to avoid.

**Resurrecting the community feed in any form** — v1 ships solo by the recorded 2026-07-16 decision. Also means:
don't migrate `CommunityView`'s empty state in T2.4, don't sweep its ~23 `.plain` sites, and don't spend further
polish on COMMUNITY-FEED-REDESIGN work.

**Four decisions previously made by silence:**

- **Localisation.** English-only through v1.x. Revisit when non-US installs exceed 15% of trailing 90 days —
  readable from App Store Connect with no instrumentation. A String Catalog before T0.2's explainer, T1.7's ladder
  and T2.4's eleven empty states would tax every copy-bearing item for a market that has not been measured.
- **Cycle-phase periodisation and postpartum protocols.** Both cross the no-medical-claims line from opposite
  directions: phase-based load prescription has a contested evidence base and a deterministic engine may not
  prescribe off a signal it cannot defend; postpartum involves pelvic-floor considerations a ramp built for tendon
  and bone adaptation does not model. A read-only, opt-in `menstrualFlow` read surfaced as **context on the
  readiness surface only** — never an input to load, pace or plan structure — remains available later as a
  genuinely small item.
- **Strength surfacing.** Deliberately deferred, not forgotten: the logger, muscle map, e1RM trend card and
  planned-lift checklist all ship, and `ProgressView.athleteStory` already renders "STRENGTH TRENDING UP". Revisit
  once T0 is out — Garmin bought TrainHeroic alongside TrainingPeaks.
- **The Athlete Model / LLM layer.** No new work this cycle. The differentiation is deterministic-engine honesty,
  not LLM output; its only unshipped exposure is device-only persistence, which T1.8 fixes, and its weekly
  restatement, which T1.3 adds.

---

## Sequencing

**W0 — this week.** W0.1 quarantine · W0.2 prove it · W0.3 the `syncedAt` bug · the `ShareLink` line (both share
paths) · T1.2 instrumentation + the RevenueCat join · T1.7 notification preferences · the AI Act disclosure line ·
the stale `Theme.Elevation` comment. **Before anything touches the map layer: land `RouteMatch.swift` and its
three test files — they are untracked on `feat/route-suggestion` and half of T0 is downstream of code nobody has
merged.**

**R1 · v1.2 — the honesty wedge.** **T0.0 first** — it is the floor under T0.1, T0.2, T0.6, T1.5, M.1 and M.3.
Then GAP (highest ratio of credibility to engineering, and its absence is a no-shame violation we commit by
omission). Then the lap button. Then Easy Means Easy parts 1–2. Then GPX out, led by step zero **with the
re-consent row**, in the exact quarter when "independent" is a live and briefly ownable word. T1.8 Phase A0/A runs
alongside as the long pole — **upload before any restore UI**, or a restore screen returns a plan-less account and
reads as a broken promise. T2.2's contrast fix in a quiet moment.

**R2 · v1.3 — before 2026-12-01.** T0.7's wall work (trial-on-monthly first, it is a store config change) · Week
One · the annual moment · T1.8 Phase B/C · the Sunday review · T0.4's card types · **then D.3's masthead
followed by T1.10's four-tab bar and action button, in that order and before T2.4** · T2.5 accessibility · M.6's
legibility matrix. **This release is dated by the market, not by code.**

**R3 · v1.4 — the route story, into spring marathon season.** T0.1a "Run it again", then T0.1b's library (after
T0.0 has filled it) · Race Week · T0.3 part 3 · the lapse ladder, **below T1.8 Phase A/B** · the map items.

**R4 · v1.5.** T1.5 Trim, **alone**, with `RecordsBook.recompute` in the same PR.

**R5 · v1.6.** T1.4 Life Happened, **alone**.

**Craft is not a wave; it is the tax paid alongside every wave.** Land the six iridescence demotions **with** the
tripwire in one commit, **before** T2.4's migration, so the heatmap's disc falls out for free. Sweep press styles
tab by tab starting with Today, and never combine that with the card-container sweep in one PR. Author the haptics
on a real device.

---

## Appendix A — code claims verified by hand

| Claim | Verified |
|---|---|
| `GradeAdjustedPace` has zero production call sites | ✅ engine file + `RunningScienceTests` only |
| All five `guideRoute` producers pass `[]`; consumer stack live | ✅ `TodayView:532/539/1520/1531`, `PlanView:218`; `CardioTrackingView:290/449/726`, 35 m/20 m hysteresis |
| `RouteMatch.context` requires a **completed** workout | ✅ `:191-194`, `guard todayTrace.count > 1` — falsified the original slice 1 |
| `assembleImport` inserts **no** `LocationSample` | ✅ `:388-409` — distance, one of pace/speed, avgHR, nothing else |
| `HKSeriesType.workoutRoute()` appears **only** in `MomentumWatch` | ✅ `WatchCardioModel.swift:146` — the watch writes routes; the phone never reads them |
| HealthKit **does** carry laps | ✅ `HKWorkoutEventType.lap` (iOS 10+), `HKWorkoutBuilder.addWorkoutEvents`, `HKWorkout.workoutEvents`; zero `HKWorkoutEvent` uses in our tree — corrected a false impossibility proof |
| Zero `VersionedSchema`/`SchemaMigrationPlan`/`MigrationStage` in the tree | ✅ while `PersistenceController.swift:5` claims "Schema is versioned (`SchemaV1`)" and `:40` calls `destroyStore`, justified at `:38-39` |
| Monthly `trialDays: 0`, annual `trialDays: 7` | ✅ `PaywallController.swift:50/53`; `:311` documents the revenue-join gap; `:315-317` the anonymous aliasing |
| `GPSProcessor.smoothedAltM` is a private live scalar, `alpha` local | ✅ `:70`, `:190-192` — the series originally specced does not exist |
| `costRatio(−0.20)` = 0.50 | ✅ a raw 5:42 really would render as GAP 11:24 without the floor |
| `inkTertiary` `#9AA0AC` = 2.626 / 2.408; `#6E7480` = 4.695 / 4.307 | ✅ recomputed from the colorset JSON against real tokens; every figure in the table reproduces |
| All five HR zone chips fail AA on white | ✅ 3.06 / 2.84 / 2.78 / 2.38 / 3.34 at 13pt caption |
| 194 `.buttonStyle(.plain)` vs 3 real `PressableScaleStyle` uses; 226 `Haptics.` calls | ✅ |
| `celebration()` byte-identical to `success()` | ✅ `:15` vs `:19`; `celebration()` and `milestone()` carry the placeholder comment, `success()` does not |
| `persistSplits` guard, `GPSWorkoutSink.checkpoint` shape, `RecordsBook.cardioCandidates` reader | ✅ `WorkoutStores.swift:79` (bug comment `:76-77`), `GPSTrackingEngine.swift:14`, `RecordsBook.swift:115-123` |
| Nine `.accepted`-filtering readers needing the `usableSamples` migration | ✅ list confirmed; `WorkoutRecovery:40/:54` correctly excluded |
| Nothing in the app assigns `workout.privacy` | ✅ zero `privacy =` writes app-wide — the Supabase `workouts` table holds no routes |
| `WorkoutSyncDTO` = 14 scalars + optional `[[lat, lon]]` | ✅ `SyncEngine.swift:14-30` |
| `Workout` has **no** `route` property today | ✅ T0.1 must declare it; `matchedRouteData` lives on `GPSDetail` (`Workout.swift:89`) |
| `Services.swift:220` — `var requiresPro: Bool { true }` | ✅ the free-by-default mechanism |
| Dynamic Type clamped at `accessibility1`, comment names three broken layouts | ✅ `MomentumApp.swift:114-122` |
| 112 `.display(N)` literals across 22 sizes, modal 20 at 27 uses, no 20 in `Theme.FontSize` | ✅ |
| `SyncService` 63 lines, upload-only, header admits it | ✅ |
| `CoachRacePlan` 1 call site, but **auto-seeded free** for `daysOut` 0–3 | ✅ `CoachProactive.swift:49-73` — corrected a false "Pro-gated, typing only" premise |
| `ProgressView.athleteStory` ships (growthCard / coachMoves / coachKnows) | ✅ `:1756` — the "surface the Athlete Model" proposal was correctly rejected as already built |
| Velocity basis: 528 commits, 2026-06-09 → 2026-07-28, one committer (two git identities) | ✅ `git rev-list HEAD --count` |
| Unit suite: 1,315 tests in 151 suites, ~21 s execution, green | ✅ run 2026-07-28 |

## Appendix B — market claims, sourcing status

Every quantitative market claim below came from pass-1 web research and **has not been individually re-sourced**.
Several are quoted to two decimal places, which overstates their precision. Treat them as directional, and **once
T1.2 ships, re-derive T1.1's and T0.5's sizing from our own funnel rather than from category benchmarks.**

| Claim | Status |
|---|---|
| <3 workouts in week one → 4–5× churn | Unverified — load-bearing for T1.1 |
| NRC day-one achievement retention 33.96% vs 20.46%; hardest tier 74.17% | Unverified — the 74.17% drives T1.1's two-target directive |
| Health & Fitness conversions Day 0 86.1% / Days 4–7 2.6% | Unverified |
| Trial→paid 42.2%; renewals 59–68% / 45.1% / 37.1%; monthly churn 10–13% | Unverified (Adapty 2026 cited) |
| Annual plans ~4.5× LTV of budget options; 51% → 61% of category revenue | Unverified (Adapty 2026 cited) — load-bearing for T1.9 |
| Cancel driver #1 = lost motivation (38%) | Unverified — **W0.2's `renewal_off` replaces it with an owned number** |
| Garmin prediction error 8–15% / 15–25% | Unverified |
| "Nearly 3 in 4 athletes hit Record in the app" | Unverified — points **opposite** to "HealthKit-imported runs are the majority for our target athlete", which is also unverified and load-bearing for T0.0. **Source one or soften both.** |
| Strava GAP vs TrainingPeaks NGP disagreement as a distrust source | Unverified |
| Strava off-route alerts shipped June 2026, paywalled, route-scoped offline | Unverified |
| Strava Standard-tier API terms from 1 Jun 2026 (paid sub, 90-day retirement, no cross-user display, no AI training) | Unverified |
| Strava gates Best Efforts shareables; Year in Sport paywalled Dec 2025 | Unverified |
| Runna refused export → GDPR complaint; 224-comment injury thread; 2026 roadmap "won't just reset" | Unverified |
| Runna pace-only critique; the5krunner Feb 2026 physio reports; the "logbook and AI interface" cancellation | Unverified |
| Garmin Connect+ dog-walk insight cancellation quote | Unverified — governs T1.7's copy rule |
| Humango rebuild-the-remainder praise; $28.99/mo | Unverified |
| Garmin PacePro watch-locked; Stryd Race Power Calculator $249 | Unverified |
| Whoop/Oura "cancel and lose your scores" as a purchase blocker | Unverified |
| Bevel "clean, minimal, highly responsive"; Whoop v. Bevel March 2026 | Unverified |
| Intervals.icu forum thread "It's time to fix the UI!" | Unverified |
| Gentler Streak share-card map styles in its newest release | Unverified |
| One bad GPS trace as the most violent churn trigger | Unverified |
| Garmin acquired TrainingPeaks + TrainHeroic 2026-07-22 | Reported; beyond assistant knowledge cutoff |
| Strava acquired Runna April 2025; bundle $149.99/yr | Corroborated by this repo's own `RUNNA-COMPETITIVE-ROADMAP.md` |
| Apple Workout Buddy in watchOS 26 | Reported |
| Apple Health+ AI coaching | **Unconfirmed** — labelled as such wherever cited |
