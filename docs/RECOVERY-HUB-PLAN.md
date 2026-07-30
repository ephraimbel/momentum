# Recovery Hub — Design & Integration Plan

> Status: approved design, drives implementation. Composes with the shipped stack — `TrainingLoad` → `ProgressInsights` → `RecoveryModel` → `RecoverySignals` → `RecoveryAdaptation` → `FitnessFreshness` → `TrendAnalytics` — every new engine consumes those; nothing re-derives them. All file:line references verified against the current tree.

---

## 1. Vision

Every recovery app on the market ends at a verdict — Oura says "take it easy" and leaves you standing there. Momentum is the only app where the morning score has a **consequence**: readiness flows into `RecoveryAdaptation` and can literally rewrite today's session, with a plain-words receipt. The Readiness hub is where that invisible guardian becomes visible — one honest 0–100 score decomposed into the real pillars that built it, strain vs recovery as one picture, sleep through a training lens, and every metric carrying a why-it-matters education line. Every number is deterministic (`Momentum/Engines/`, pure, fixture-tested, personal-baselines-only, never a diagnosis); AI narrates on top and computes nothing. The killer frame: *"Readiness 61 this morning — your tempo moved to Thursday, today is 4 easy miles"* — no competitor can render that second beat, because none of them own the plan.

## 2. Where it lives

> **AMENDED 2026-07-15 (user call + adversarial IA review): the hub is a third Progress SEGMENT — `Trends · Health · History`** — not a pushed screen. Content lives self-contained in **`Features/Recovery/HealthSegmentView.swift`**; ProgressView is touched only by a small late diff (+1 `Segment` case, +1 body-switch line, formCard/recoveryCard/signalsRow → compact `ReadinessStrip`, one `onSelect` branch, one launch-arg line). Verified: this is *equal-or-less* ProgressView surface than the pushed variant's own P3, and it fixes the pushed plan's broken entry plumbing (RootView's per-tab NavigationStack has no path binding — a runtime cross-tab push had no mechanism; a segment needs only a value via a tiny `@Observable AppRouter { pendingTab, pendingProgressSegment }` + a `pendingNav.viewHealth` case). Precedents distinguished: "You" was merged because it was THIN (~3 facts); the heatmap stayed a card because it's PASSIVE look-back. Health is 7 cards + 12 explainer sheets + its own free/Pro split with a daily consequence — segment vs *hidden*, not segment vs merged. Per-segment gating precedent already exists (History's `.fullHistory` row, ProgressView:901–956). **Naming resolved: segment word = "Health"** (clear scent, matches the Apple-Health acquisition hook, 6 chars — the custom capsule picker doesn't scale with Dynamic Type, so 3 words fit deterministically); **"Readiness" stays the hero-card/score word inside.** Deterministic deep-link: `--progress-health` via the Segment initializer (the most reliable pattern in the file). One accepted cost: a segment advertises emptiness to watch-less day-one users — §5's specimen/check-in states carry that bar.

*(Superseded original: a pushed `RecoveryHubView` — kept here for history; the paragraphs below are otherwise unchanged and every card/engine/state applies to `HealthSegmentView` verbatim.)*

**Entry points (four, all reading the same engines):**

1. **Progress → Trends hero card.** A redesigned readiness card absorbs and replaces the current `formCard` (ProgressView:762) + `recoveryCard` (:1114) + `signalsRow` (:1160); `NavigationLink` → `RecoveryHubView`. The `recoveryUpsell` connect-Health flow (:1175–1207) survives unblurred — it's the acquisition hook.
2. **Today — the morning readout.** The deck keeps exactly three thoughts (TodayView:795–800); we do **not** add a fourth. The `utilityLine`'s post-check-in state (currently `quietActionsRow`, :831–833) becomes `MorningReadinessLine`: mini ring + score + band word + the single biggest driver in plain words. Reuses the `recoverySignals()` read already in bootstrap (:321). Tap → Progress tab + push to the hub. If `RecoveryAdaptation` fired, a hairline footer: *"Today adjusted — tap to see why."*
3. **AthletePanel rail.** The READINESS callout (ProgressView:1929) retargets its `target` scroll id to the new hero card.
4. **Coach deep link.** Coach plan-change cards cite the same engine outputs — *"Readiness 42 this morning (short sleep + elevated resting HR), so I've swapped tomorrow's intervals for an easy 30"* — via the existing `CoachIntentBridge` pattern, consent-gated apply. The hub is the evidence; the coach is the narration. The coach never recomputes.

**Surfacing the silent guardian:** `@Query(sort: \CoachingEvent.date, order: .reverse)` filtered to `.ease`/`.recover` renders the full "we eased Thursday because…" trail (headline + `Decision.reason` already persisted verbatim, RecoveryAdaptation.swift:72, :102–103) using the existing `adaptationList` timeline (ProgressView:2008–2035). For a live today-explanation, call the pure `RecoveryAdaptation.decide(signals:intensity:checkin:)` and `tripwire(acwr:signals:)` with the same inputs TodayView uses (:326–328) — showing either "all clear — no signals firing" or the two active warnings. Dedupe and throttles are already handled upstream (CoachingEvent:43–52; `plan.lastAdaptedAt` at RecoveryAdaptation:68) — the hub only reads.

## 3. The data

Already read (HealthService.swift:22–34): workouts, heartRate, restingHeartRate, heartRateVariabilitySDNN, sleepAnalysis, vo2Max, bodyMass, stepCount, activeEnergyBurned, distances. **Additions** (extends `readTypes` → one-time Health re-prompt; empty result = absent, never zero):

| Signal | HK identifier | Who writes it | Why it matters (one line) |
|---|---|---|---|
| Respiratory rate | `.respiratoryRate` | Watch S3+ (sleep tracking); Oura/Whoop/Garmin mirror nightly | Your steadiest vital — a rise of 1–2 breaths/min above your own norm often precedes a day your body wants easy, before you feel anything. |
| Sleeping wrist temp | `.appleSleepingWristTemperature` | Watch S8/Ultra+ only (Oura/Whoop keep temp proprietary) | A half-degree deviation from your nightly norm is a classic sign your body is diverting energy away from adaptation; only ever read vs your own baseline. |
| Blood oxygen | `.oxygenSaturation` | Watch S6+, Garmin, Oura | Steady overnight SpO₂ means the aerobic system is delivering; dips vs your norm are worth noticing alongside sleep — FYI only, never scored (too noisy). |
| Cardio recovery (HRR) | `.heartRateRecoveryOneMinute` | Watch-tracked workouts only (watchOS 9+) | How far HR falls in the first minute after hard work — one of the most honest fitness signals; watch it climb over a block. |
| Walking HR average | `.walkingHeartRateAverage` | Apple daily (worn Watch required) | Everyday-movement heart rate is a quiet fitness barometer; drifting up while load is flat is an early fatigue whisper. Feeds `DayStrain`'s intensity nudge. |
| Steps | `.stepCount` (already read; new reduction) | iPhone, Watch, Garmin — multi-source | Non-workout movement is real load your legs absorb; a 15,000-step day before a quality session isn't rest, and strain should say so. |
| Sleep stages | `HKCategoryValueSleepAnalysis` core/deep/REM/awake (already read; new query shape) | Watch (watchOS 9+), Oura, Whoop, Garmin; phone-only = `.inBed` only | Deep sleep is where hard training gets banked (muscle repair, growth hormone); REM consolidates skill and mood. |
| Time in daylight | `.timeInDaylight` | Watch SE2/S6+ (watchOS 10+) | Morning light is the strongest lever for consistent sleep timing — the cheapest recovery gain available. Education tile, deferred to P4. |
| Mindful minutes | `HKCategoryTypeIdentifier.mindfulSession` | Watch Mindfulness, Calm, etc. | Down-regulation measurably speeds the shift into recovery mode after hard days. Education tile, deferred to P4. |

**Multi-source rules (service layer):** sleep duration = the shipped 18-hour union-merge (`sleepHoursLastNight()`, HealthService:411–445) stays canonical; sleep stages = single best source per night (largest total asleep — cross-source stage unions produce impossible nights); steps = per-source daily sums, take **max**, never `.cumulativeSum` across sources; HRV/RHR/respiratory = per-day median. **Biggest service gap to close:** only `latest()` (:380) and one 30-day `average()` (:393) exist today — add a day-bucketed history query (`HKStatisticsCollectionQuery` / per-day sample reduction) returning `[(day: Date, value: Double)]`.

## 4. The engines

All pure structs/enums in `Momentum/Engines/`, `Sendable`, SI units, `Calendar`/`now` injected, recompute-from-source (no derived persistence — late-syncing Garmin data self-heals on next compute). None duplicates `RecoveryModel`/`RecoveryAdaptation`/`TrendAnalytics`; all compose with them.

### 4.1 `HealthBaselines.swift` — build FIRST; everything reads it
- **Input:** `dailyValues: [(day: Date, value: Double)]`, `windowDays`, `now`, `calendar`.
- **Output:** `Baseline { mean, sd, dayCount, windowDays, lower/upper (mean ± 1 SD), isBanded (≥7 days), isEstablished (≥14), z(_:) }` — or `nil` if empty.
- **Math:** one value per local day (median), mean + population SD, **one winsorization pass** (clamp beyond ±3 SD, recompute) so a 200 ms HRV artifact dies without hiding a real trend.
- **Windows:** HRV 30d · RHR 30d · respiratory 30d · wrist temp 60d · walking HR 60d.
- **Fixtures:** exact mean/SD on 30 knowns; winsorization shifts mean < 2% vs outlier-free; 6 days → not banded, 13 → not established, 14 → established; multi-sample day counts once; window cutoff at day 31.

### 4.2 `MorningReadiness.swift` — the headline number
Blends `RecoveryModel.score` (the load pillar, unchanged) with body signals into one 0–100 with **per-pillar contributions** and a **confidence tier**. `RecoverySignals.blendedReadiness(base:)` (RecoverySignals.swift:89) becomes a deprecated shim over this, so Today and the hub can never disagree.

- **Output:** `score: Int` · `band: RecoveryModel.Readiness` via `RecoveryModel.band(_:)` — **one banding function app-wide, cuts 25/45/65/80** (verified: RecoveryModel.swift:75–82) · `pillars: [Pillar {kind, score 0–100, weight, points = weight·(score−50)}]` · `modifiers` (respiratory/temp) · `confidence: high/medium/low/minimal`. Zero pillars → `nil` → "learning you" state, never a fake number.
- **Raw weights, renormalized over present pillars** (this IS the missing-signal degradation): load 0.30 (`RecoveryModel.score` verbatim, present iff `hasData`) · HRV 0.25 (z-path `clamp(50 + 20·clamp(z,−2.5,2.5))` when banded; ratio fallback matching `hrvTrend` cuts: ≥1.05→75, ≥0.92→55, ≥0.82→30, else 10) · sleep 0.20 (`clamp(100 − 25·max(0, need−lastNight) − 2.5·min(debt14,12))`) · resting HR 0.15 (inverted z; Δ fallback matching `restingHRTrend`: ≤−2→75, <1→60, <4→40, else 15) · check-in 0.10 (`clamp(60 + energy{−25/0/+20} + legs{+20/0/−20/−35})`).
- **Modifiers** (post-blend, sparse Apple-only signals never earn pillar status): respiratory z ≥ 2 → −10, z ∈ [1,2) → −5; wrist temp Δ ≥ 1.0 °C → −10, 0.5–1.0 → −5; combined floor −15. Unbanded baseline → silently zero (a deviation penalty against an unlearned norm is exactly the false alarm this design prevents).
- **Invariant (test it):** renormalized weights + clamped pillars ⇒ one pillar moves the score ≤ 30 pts, modifiers ≤ 15 — one noisy night can never crater a Primed athlete to Depleted. `pillars[].points` sum to `blend − 50` — that's the DriverRow's math.
- **Guidance text:** `RecoveryModel.guidance(band)` (:90) — already written for this re-banding case.
- **Fixtures:** all-neutral → 50/moderate; golden morning hand-computed; renormalization exactness (load+checkin only = (0.30·L+0.10·C)/0.40); watch-less non-nil at `.minimal`; zero pillars nil; ratio-vs-z path; single-pillar |Δ| ≤ 30; modifier floor; band boundaries 24/25, 44/45, 64/65, 79/80 match `RecoveryModel.band`.

### 4.3 `DayStrain.swift` — daily strain 0–100
**Naming note:** `RecoveryModel.strain` (RecoveryModel.swift:46, Foster weekly load × monotony — computed but never rendered today) is a different internal quantity. The UI word "Strain" is only ever this engine.

- **Inputs:** `workoutsToday` · `ambientSteps`/`ambientActiveKcal` (service nets out workout windows, clamps ≥ 0) · `walkingHRAvg` + baseline · `chronicLoad` (FitnessFreshness CTL) · `now`/`calendar`.
- **Output:** `score: Int (0–100)`, `band: light/moderate/hard/peak` (0–24/25–49/50–74/75+), `workoutLoad`, `ambientLoad`.
- **Math:** `workoutLoad = Σ TrainingLoad.session(w)` (day-bucketed by `calendar.startOfDay` — the shipped convention); ambient = steps primary (`steps/1000 × 10`) or kcal fallback (`kcal × 0.25`), **never summed**; walking-HR multiplier `clamp(avg/baseline.mean, 0.9, 1.15)`; `raw = workoutLoad + ambientLoad`; `reference = max(CTL, 30)` (cold-start floor); **saturating curve** `score = round(100·(1 − exp(−raw/(1.6·reference))))` — anchors: raw = reference → 46, 2× → 71, 3× → 85. Scale-free: the same session scores lower as chronic load grows ("this used to be a hard day for you").
- **Fixtures:** rest day → 0/light; anchor pins 46/71; monotonicity sweep; cold start CTL 4 high-but-<100; steps-vs-kcal exclusivity; multiplier clamp; 23:50/00:10 day-key + DST day; band boundaries.

### 4.4 `SleepReport.swift`
- **Output:** `asleepH` (union-merged) · `stages: {coreS, deepS, remS, awakeS}?` (nil = duration-only night, UI never pretends) · `efficiencyPct?` · `needH` (default 8.0; after ≥14 nights in 60d: `clamp(median of 4–12h nights, 7.0, 9.0)`) · `debt14H` (Σ shortfall over *present* nights — missing nights skipped, never counted as zero-sleep) · `midpointDriftMin?` (**circular** SD of nightly sleep midpoints, ≥5 nights — 23:30 vs 00:30 reads as 60 min, not 23 h) · quality bands per dimension (duration vs need; efficiency ≥90/80; debt <2h/2–5h; consistency ≤45/45–90 min).
- **Stage bands:** before 10 stage-nights, values with NO band + "learning your norm" (no population deep/REM tables — personal-norm mandate). After: `HealthBaselines` on deep-% and REM-%.
- **Fixtures:** exact stage durations + same-stage overlap merge; two stage sources → larger-asleep source's stages, union duration; duration-only night; need learning (13→default, median 6.2→clamped 7.0, naps excluded); debt with missing nights; the midnight-straddling circular-drift test (≈38 min, NOT hours); 4 nights → nil drift; 9 vs 10 stage-nights banding.

### 4.5 `StrainRecoveryBalance.swift` — the signature chart's engine
Descriptive only — the *action* path stays `RecoveryAdaptation.decide/tripwire`, which this composes with, never replaces.

- **Output:** `days: [Day {date, strain?, readiness?, balance = readiness − strain}]` (gap-free date spine, nil-holed, 7 or 30) · `state: building/balanced/overreaching/detraining/insufficient` over trailing 7.
- **Math:** `d̄` = mean of `readiness − strain` where both exist (≥ 4 such days, else `.insufficient`): `d̄ < −10` → overreaching · `[−10, 25)` → building · `[25, 45)` → balanced · `≥ 45` with `ctlDelta7 ≤ 0` → detraining, with `> 0` → balanced. **The CTL guard is what keeps a race-week taper from being scolded as detraining** — `ctlDelta7` comes from `TrendAnalytics.fitnessFreshness` (:49), already charted.
- **Fixtures:** one per state at exact boundaries (−10/25/45); taper guard both directions; 3-of-7 days → insufficient; nil-holes excluded from `d̄` but present on the spine; `balance` nil when either side missing.

**Historical readiness/strain series:** recomputed on demand from Health history + persisted `DailyCheckin`s + workouts (no derived persistence), built off-render-path via the `ProTrendsSection.Model.build()` pattern (ProTrendsSection.swift:23–37, `.task(id:)` :53).

## 5. The screens

**Today — `MorningReadinessLine`** (utility-line state): 44pt mini ring + score numeral (Space Grotesk, `.monospacedDigit()`), band word, one engine-chosen driver line ("Short night — today's run is easier on purpose"). Adjusted-plan hairline footer when adaptation fired. Tap → hub.

**`HealthSegmentView`, top to bottom** *(amended name — free glance cards render plain; the depth cluster wraps in one `.proLocked(.advancedAnalytics)` per §8)*:

| # | Card | Content | Chart | Animation | Education footer |
|---|---|---|---|---|---|
| 1 | **ReadinessHeroCard** | 180pt ring, count-up numeral, band word, `RecoveryModel.guidance` line, 7-day dot micro-strip | Custom `Canvas`/`ProgressRing` — mint-ink fill on 22%-pastel track, hairline ticks at **25/45/65/80**; iridescent `MeshGradient` fill only at `.primed` (≥ 80) | Track fades (0.15s) → `trim` sweep + `AnimatedCounter` in lockstep (~0.9s, `Motion.travel`) → band-word crossfade + 1.0→1.03→1.0 pulse + `Haptics` tick at each band crossing → if Primed, one iridescent sweep (1.2s) then the slow 8s ambient loop | "How readiness is scored" ⓘ → sheet; partial-data footnote lists inputs used ("From HRV + resting HR — no sleep data last night") |
| 2 | **DriverRow** | Three chips naming today's top drivers by |points| ("HRV ↑ vs normal · Sleep 7h 40m · Yesterday hard") + the live `RecoveryAdaptation.decide`/`tripwire` readout ("all clear" or the two active warnings) + the `CoachingEvent` ease/recover timeline via `adaptationList` | Deviation mini-bars growing from a baseline centerline (the contributor cascade — the pedagogy IS the animation, 60–80ms stagger) | Chips scroll to their card | Each driver states its plan effect: "HRV suppressed → this is why intensity eased today" |
| 3 | **BalanceCard** "Strain & Recovery" | 7d/30d segmented; recovery + strain curves; current-state word (building/balanced/…) | Two `LineMark`s, **one shared 0–100 axis** (never dual); mint ink circle end-dot vs peach ink **square** end-dot (shape redundancy — weakest CVD pair) + 2-swatch legend; `AreaMark` between curves split at crossings, mint/peach wash 12%; gridlines 25/50/75; direct end-labels; shared-x scrub lollipop; gaps > 1 day break as dotted hairline bridges | Left-to-right mask reveal (`scaleEffect(x:)` anchor .trailing, 0.6s); end dots + labels pop last; 7d/30d crossfade with `Motion.reversible`, axes never jump | "Big strain on big recovery is a training block working; the same strain on a low-recovery week is where overreaching quietly starts" ⓘ |
| 4 | **SleepCard** "Sleep" | Last night: duration hero ("7:41") + horizontal stage bar; below: 7-night stacked columns + 14-day debt area with "paid down / building" word | Stage bar: 20pt stacked `BarMark`, single-hue periwinkle depth ramp Deep `5B6BD6` → Core `8F9BFF` → REM `B8C0FF`, Awake = `Theme.hairline`; columns ≤ 16pt, y-gridlines at 2h; debt = periwinkle-wash `AreaMark` under 2pt periwinkle-ink line, zero-line emphasized | Stacks grow `scaleEffect(y:, anchor: .bottom)` | Phone-only → single-tone bar + "Stages come from a watch worn overnight"; missing night → hollow hairline column. Footers per §7 |
| 5 | **VitalsBoard** "Your vitals" | 2×2 upgraded `VitalTile`s: HRV, Resting HR, Respiratory, Wrist temp — latest value (Space Grotesk 22pt tabular) + delta chip + in/out-of-band stated in **words** | 30-day 2pt ice-ink sparkline (temp tile alone: lilac ink) riding a `RectangleMark` personal-band ribbon (mean ± SD, pastel 12%); no axes on tiles (the ribbon IS the reference); tap → full `TrendChartCard` with axes + scrub | Sparkline draw-on; the first completed 14-day baseline earns a one-time ribbon shimmer | < 14 days → "Building your baseline — 9 of 14 days" + 14-tick progress row; each tile's ⓘ opens its explainer |
| 6 | **RhythmCard** "Weekly rhythm" | 4-week × 7-day heat-dot grid of `DayStrain`; kept rest days rendered proudly | Dots on 24pt centers; peach-ink opacity steps 0.25/0.5/0.75/1.0 by strain quartile + size 6→10pt (survives grayscale); planned rest = hollow 8pt circle with centered tick; today = ink ring; tap dot → day summary | Dots ripple in by column, 20ms apart; a completed balanced week earns a one-time row shimmer + `EarnedLine` | "Rest days" explainer ⓘ |
| 7 | **LearnCard** "How this works" | Two rows: "How readiness is scored" · "Where this data comes from" (Apple Health as the single aggregator — Watch, Garmin, Oura, Whoop all arrive through it) | — | — | Opens `MetricDetailSheet`s |

**Explainer sheets:** all copy appended to `MetricExplainers` (`E(id:title:tagline:formula:sections:footnote:)`, MetricInfo.swift:6–19; registry `MetricExplainers.all` at :166 — new entries must be appended there or the registry test fails), presented via the existing `MetricInfoButton` + `MetricDetailSheet` (staggered sections, Reduce Motion honored, MetricInfo.swift:47–108). Formulas shown where honest. Standing footer on every sheet: *"Guidance, never a diagnosis — if something feels wrong, talk to a professional."*

**Empty / cold-start / no-watch — first-class states:** No-watch → hero becomes the check-in path (`CheckinSheet` already exists): same ring, same bands, **dashed** mint fill + "From your check-in" caption — self-reported never impersonates measured; earned iridescence still applies at Primed. VitalsBoard collapses to one elegant `ConnectRow` (Apple Health mark, one sentence, one button — shown once prominently, then a footer row, never re-nags; reuse `recoveryUpsell` copy). Zero-data charts render as designed **specimens**: ghost data in hairline gray at 8%, small-caps `EXAMPLE` tag, one teaching line — day one already looks like the product. Partial data degrades silently per card with one calm footnote; never a warning triangle, never yellow.

**Global chart rules:** `.monospacedDigit()` on every tick, value, and delta; 1px solid `Theme.hairline` gridlines, never dashed; axis text 11pt Inter `inkTertiary`; one y-axis per chart; 2pt round-join lines; ≥ 8pt end dots with 2pt surface ring; bars ≤ 24pt with 4pt rounded data-ends; endpoint + extreme labeled, scrub carries the rest.

## 6. Color & motion system

**Doctrine: ink draws, pastel breathes, iridescence is earned.** Structure, text, axes, numerals: always monochrome. Each domain owns exactly ONE pastel as its *wash*; the hub reads colorful because five quiet tints coexist across cards while any single card stays ~90% monochrome. Text never wears a data color.

| Domain | Pastel (wash only: fills 10–14%, ribbons 12%, tracks 20–25%, dark glows 16%) | Ink (every mark: lines, dots, bars, ring fills) |
|---|---|---|
| Sleep | periwinkle `B8C0FF` | `5B6BD6` |
| Recovery / readiness | mint `C8FFE0` | `2E9E6B` |
| Strain / load | peach `FFD8C2` | `C96F3B` |
| Vitals (HRV/RHR/resp) | ice `C2F0FF` | `1E90C0` |
| Temperature / illness-watch | lilac `E6C2FF` | `9A5BD6` |

The two-step is load-bearing: raw pastels fail as chart marks (contrast vs white as low as 1.09:1, gray under CVD); the ink set passes lightness, chroma, CVD separation ≥ 16 ΔE, and ≥ 3:1 contrast **on both** the light surface and `#1E1D1B`. Ship as `Theme.Health` tokens. Never: pastel text, pastel lines, ink backgrounds, or two domain tints on one chart — the BalanceCard's mint+peach is the sole sanctioned pairing, and it carries a legend + shape-differentiated end markers. This extends the sanctioned `MetricColor.zones` precedent (MetricColor.swift:22–28) — multi-hue only where a recognized convention demands it. **Illness-watch is lilac + words, never red** ("Running warm vs your normal — worth an easy day"); there is no bad color anywhere in the hub.

**Earned iridescence — exactly four triggers, never simultaneous:** (1) readiness band `.primed` (≥ 80, the engine's cut — not 85): hero ring fill renders as `MeshGradient` with one slow sweep on land; (2) a balanced week completed (7 days inside the recovery envelope): one-time shimmer across that RhythmCard row; (3) sleep-consistency streak milestones (7/30 nights, inheriting app streak rules — 2-day grace, never "lost"); (4) first vitals baseline banked (14 days): a single ribbon shimmer, a welcome moment, not recurring. Note: today's always-iridescent `readinessRing` (ProgressView:1227) is retired by this rule — sub-Primed rings render mint ink. Celebration at the top instead of punishment at the bottom is the deliberate inversion of Whoop's red-shame.

**Motion:** page cascade reuses `.reveal(delay:)` (AnimatedCounter.swift:78), 70ms stagger, below-the-fold reveals on scroll. All animation transform-only (opacity/scale/offset/trim), 60fps; nothing loops except earned iridescence (8s, never faster, never strobing). **Reduce Motion — the full story:** counters render final values; ring and charts appear complete behind a plain crossfade; band word appears set, no pulse; earned iridescence renders as *static* mesh — the achievement shows, it just doesn't move; stagger collapses to one fade. Haptic ticks remain (not motion). **Dark (#1E1D1B / #2A2926):** same validated inks, washes warm to 14–16% + soft same-tint glow (radius 12, pastel 20%) — warm, never neon; earned marks don't re-anodize between modes.

**The three animation moments worth real investment** (everything else instant/subtle): the morning reveal → plan reaction two-beat; the contributor cascade (bars grow from the baseline centerline — the score teaches itself); recovery arriving after strain (the load bar lands, readiness dips, then visibly climbs back over the week with a shimmer at the crossover — supercompensation made visible: "the dip is the point").

## 7. The copy deck

Voice: warm, plain-English, no-shame, no citations-theater, no medical claims. Each hub card carries a one-line footer ending in ⓘ; sheets hold the full entries below (each becomes a `MetricExplainer` with *What it is / Why it matters / What moves it* sections).

**Readiness** — *What it is:* One 0–100 number for how ready your body is to absorb training today, blended from your overnight signals. *Why it matters:* Fitness is built in recovery, not in the workout — the session applies the stress, and your body adapts while you rest. Training hard on a body that hasn't finished adapting mostly adds fatigue, not fitness. Readiness times the hard days for when they'll actually count. *What moves it:* Sleep, alcohol, illness, stress, and how hard the last few days were. One low morning means little; a low week is your body asking for ease. *(Formula line: "Readiness = weighted blend of HRV, resting heart rate, sleep, recent training load, and your check-in — same math every day.")*

**HRV (heart-rate variability)** — *What it is:* The tiny variation in time between heartbeats while you sleep — a read on your nervous system's balance. *Why it matters:* When you're recovered, the rest-and-digest side of your nervous system runs the show and the gaps between beats vary more. Under fatigue, stress, or oncoming illness, the fight-or-flight side takes over and the rhythm turns metronome-steady. Your trend against *your own* normal is the signal — comparing your number to anyone else's is meaningless. *What moves it:* Hard training, poor sleep, alcohol, and stress push it down; easy days, good sleep, and consistency bring it back.

**Resting heart rate** — *What it is:* Your heart's idle speed, measured overnight when nothing is asked of it. *Why it matters:* A fitter heart moves more blood per beat, so it idles slower — watching it drift down across months is watching fitness arrive. A sudden jump of 5+ beats above your normal usually means your body is working on something: fatigue, dehydration, or fighting a bug. *What moves it:* Aerobic training lowers it over months. Alcohol, heat, late meals, and illness raise it overnight.

**Respiratory rate** — *What it is:* How many breaths you take per minute while asleep. *Why it matters:* This is your steadiest vital — it barely moves night to night, which is exactly what makes it useful. A clear rise above your normal often shows up a day or two before you feel run down, making it a quiet early-warning line worth glancing at. *What moves it:* Very little, normally — which is the point. Illness, poor air, and heavy fatigue nudge it up.

**Wrist temperature** — *What it is:* How far your overnight skin temperature sat from your personal baseline. *Why it matters:* Your body runs a tight thermostat, so a real deviation means something's up — often the immune system getting to work before symptoms show, sometimes just a hot room or a late workout. It reads best alongside your other signals, not alone. *What moves it:* Illness, alcohol, late exercise, room temperature, and — for some — the menstrual cycle's natural rhythm, which the trend line makes visible.

**Sleep stages (core, deep, REM)** — *What it is:* The three kinds of work your brain and body cycle through at night — light (core), deep, and REM. *Why it matters:* Deep sleep is the body shift: growth hormone is released and muscle repair happens mostly there — it's where hard training gets banked. REM is the brain shift: skill, coordination, and mood consolidate. Core knits the cycles together. Runners shortchanging deep sleep are doing workouts they never fully cash in. *What moves it:* Deep sleep concentrates early in the night, so a consistent bedtime protects it. Alcohol is the biggest REM thief; caffeine after mid-afternoon cuts deep sleep.

**Sleep debt** — *What it is:* The running gap between the sleep you've had and the sleep you need, over the last two weeks. *Why it matters:* Debt compounds quietly — reaction time, pace at a given heart rate, and injury resilience all slide as it builds, usually before you feel obviously tired. The good news: it pays down fast, and the chart shows it shrinking within a couple of honest nights. *What moves it:* Nightly duration versus your need. An earlier night beats a weekend lie-in — big catch-up sleeps shift your rhythm and cost you later.

**Sleep consistency** — *What it is:* How closely your bed and wake times repeat, night over night. *Why it matters:* Your body rehearses sleep before you're in bed — hormones and temperature start shifting on schedule. A steady schedule means deeper, more efficient sleep from the same hours; the same 7½ hours at random times genuinely restores less. It's the highest-leverage sleep habit, and it's free. *What moves it:* A regular lights-out and alarm — weekends included, within an hour or so.

**Strain** — *What it is:* How much load today put on your body — every run, ride, and lift folded into one number, plus the everyday movement your legs still have to absorb. *Why it matters:* Strain isn't the enemy; it's the ingredient. Adaptation needs enough stress to signal "get stronger" — but stress only converts to fitness when recovery keeps pace. The number exists so hard days can be *deliberately* hard and easy days honestly easy, instead of everything blurring to medium. *What moves it:* Duration times intensity. Long easy work accumulates it slowly; intervals and racing spike it fast — and heat or hills raise the true cost of the same route.

**Strain–recovery balance** — *What it is:* The two curves together: what you're spending versus what you have to spend. *Why it matters:* Neither line means much alone — big strain on big recovery is a training block working; the same strain on a low-recovery week is where overreaching and injury quietly start. Weeks of peach-over-mint is the pattern worth acting on, and acting on it early is cheap. *What moves it:* You steer strain with your plan; recovery follows sleep and stress. When they drift apart, the fix is almost always an easier day or an earlier night — not more discipline.

**Rest days** — *What it is:* Planned days of little or no training — a scheduled part of the program, not a hole in it. *Why it matters:* This is when the adaptation you trained for actually gets built — muscle repairs, energy stores refill, the nervous system resets. Skipping rest to "stay on track" trades next week's fitness for today's mileage; it's the most common way strong training blocks unravel. *What moves it:* Nothing to optimize — take them as planned. A kept rest day counts toward your streak, and your rhythm chart wears it proudly.

**Where this data comes from** (LearnCard) — Momentum reads every wearable through Apple Health — Apple Watch, Garmin, Oura, and Whoop all deliver their overnight signals there. We never rank you against anyone; every band on every chart is your own normal, learned from your own nights.

## 8. Free vs Pro

**Principle (competitor lesson made policy): you never pay to see your own body — you pay for the trends and the synthesis.** Whoop's deepest resentment is subscription-gated raw data; we invert it.

- **Free (the glance layer):** Today's `MorningReadinessLine`; hub hero ring + score + band + guidance; DriverRow (today's pillars + the live adaptation readout); last night's sleep duration + stage bar; each vital's latest value + vs-your-normal delta in words; every explainer sheet (education is always free); the connect-Health `ConnectRow`; and `RecoveryAdaptation` itself keeps acting for everyone (shipped behavior — entitlements don't regress).
- **Pro (the depth layer):** BalanceCard (7d/30d history + state), 7-night sleep columns + debt area + consistency, VitalsBoard 30-day sparklines + baseline ribbons + full `TrendChartCard` views, RhythmCard, the CoachingEvent timeline history.
- **Feature case:** reuse **`.advancedAnalytics`** (Services.swift:196; placement `"analytics_locked"` :211) via `.proLocked(.advancedAnalytics)` (ProLock.swift:7) — the Progress Pro cluster is deliberately one-unlock-opens-the-page (ProgressView:362–363), and readiness/form already lives inside that gate. Do **not** blur `recoveryUpsell` (:1175). Only add a `case recoveryHub` (placement `"recovery_locked"`, 4 switch entries) if marketing wants a separately A/B-testable Superwall placement — flagged as an open question, not assumed.
- **Explicitly rejected:** red/shame states; medical-adjacent claims ("illness detected"); dense gauge dashboards (one hero, one decision, charts on demand); recovery gamification or sharing readiness to Community (recovery is the private mirror — it stays out of the social layer entirely); fake precision (show the math on tap, honest rounding, felt-experience override kept — "feeling great anyway? keep the session"); default morning push-pings (the ritual is pulled, not pushed — bell inbox only).

## 9. Build phases

Each phase ships independently and leaves the app releasable.

**P1 — Data + baselines foundation.**
Extend `HealthService.readTypes` (respiratoryRate, appleSleepingWristTemperature, oxygenSaturation, heartRateRecoveryOneMinute, walkingHeartRateAverage, timeInDaylight, mindfulSession); add the day-bucketed history query + per-source-max steps + per-day-median reductions + ambient netting; add sleep-stage/night queries (single-best-source stages, union duration). Build `HealthBaselines`. Add `RecoverySignals.demoStrained` + `--health-recovery-strained` (HealthService demo short-circuit pattern at :103) and a synthetic 30-day history hook modeled on `--zones-demo` (:326–346). Seed `DailyCheckin`s + one eased session in `DemoSeed`.
*Verify:* `HealthBaselinesTests` + service pure-helper tests (whole scheme, Swift Testing, build-for-testing → test-without-building); `--health-recovery-demo` and `--health-recovery-strained` still drive the existing recoveryCard.

**P2 — Engines.**
`MorningReadiness` (+ `blendedReadiness` becomes a shim over it — Today and Progress render identical scores), `SleepReport`, `DayStrain`, `StrainRecoveryBalance`. Fixed-calendar/fixed-now fixtures per the shipped engine-test convention; the full test plan in §4 (band-boundary parity with `RecoveryModel.band`, the ≤30-point invariant, the circular-drift midnight test, the taper guard).
*Verify:* whole-scheme test run green; no UI change yet beyond identical scores (shim equivalence test).

**P3 — The hub + entries + gating.**
`Features/Recovery/RecoveryHubView.swift` + the 7 cards (built from `VitalTile`/`Sparkline`/`TrendChartCard`/`FitnessFreshnessCard` components, ProTrendsSection.swift:107–500, and the off-render `Model.build()` pattern); `Theme.Health` tokens; all §7 copy appended to `MetricExplainers.all`; Progress hero card replaces formCard/recoveryCard; Today `MorningReadinessLine`; AthletePanel rail retarget; `.proLocked(.advancedAnalytics)` split per §8; deep links `--recovery-hub` (DispatchQueue auto-push pattern, TodayView:344–365), `--progress-scroll-recovery`, and `--recovery-lab` isolated harness (clone of `--analytics-lab`, ProfileScreen:35–37).
*Verify:* simulator screenshots (explicit UDID — sims are contested between sessions) of: full-data light + dark, `--health-recovery-strained` (eased-day receipt visible), no-watch check-in state, cold-start baseline-building state, specimen empty state, Pro-locked vs entitled (`StubPaywallService` returns entitled in dev — screenshot both via the paywall stub toggle); Reduce Motion pass.

**P4 — Polish + the three moments.**
Hero band-crossing choreography + haptics; contributor cascade; supercompensation shimmer at the recovery-crossover; earned-moment triggers (balanced week, consistency milestones, first baseline); coach citation cards through `CoachIntentBridge`; weekly recovery recap folded into the existing `CoachWeekRecap` ("Readiness averaged 74, up 6 — the easy Tuesday paid for Thursday's tempo"); optional More-signals row (SpO₂ / daylight / mindful FYI tiles).
*Verify:* screen-recorded motion review at 60fps + Reduce Motion re-pass; dark-mode UI-test suites re-run (they key off launch args — keep new args in the `#if DEBUG` cheap-string-check style); a fresh-install day-one walkthrough confirming the specimen → baseline → banded progression.

## 10. Risks & open questions

**Risks**
1. **ProgressView is a hot, contested file** (multiple parallel sessions share this checkout; ProTrendsSection integration was previously deferred for this exact reason). Mitigation: build the hub self-contained in `Features/Recovery/`, touch ProgressView only in a small, late diff; check `git status`/stash before editing.
2. **Extending `readTypes` re-prompts Health authorization** — existing users see a new permission sheet; a denial reads as empty data. The empty-=-absent rule (every engine input Optional) already absorbs it, but onboarding copy for the re-prompt needs a pass.
3. **Historical recompute cost:** 30 days of readiness requires 30 days of HRV/RHR/sleep queries + per-day engine runs. Must stay off the render path (`Model.build()` + `.task(id:)`) per the page-load-perf lesson; budget and profile before shipping P3. If it can't hit budget, fall back to persisting a small daily snapshot — a deliberate exception to recompute-from-source, decided then, not now.
4. **Two strains, one word:** `RecoveryModel.strain` (Foster, internal) vs `DayStrain` (the UI's Strain). Enforced by review: the monotony-based quantity never surfaces under that name.
5. **Score-shift on upgrade:** `MorningReadiness` won't numerically equal `blendedReadiness` in all cases (pillar renormalization vs fixed offsets). Users will see their number move once. Mitigation: shim-equivalence tests bound the delta on the demo fixtures; ship engines and UI in the same release so it moves exactly once.
6. **Wrist temperature is Apple-Watch-S8+-only** (Oura/Whoop don't write it) — the lilac tile will be empty for many; its baseline needs 14 days before the modifier can ever fire. The building-baseline state must look as designed as the full one (it does — §5).
7. **Whoop-pathology guard:** any future proposal to gamify recovery (badges, leaderboards, streak pressure) violates §8's rejections — recovery must never become a performance to optimize.

**Open questions**
1. **Marquee word final call: "Readiness" (recommended) vs "Body".** Readiness encodes the moat (score → action); Body wins only if the surface grows into a broader daily-health mirror. Also: the engine's raw band words (`Moderate/Strained/Depleted`) read more clinical than the UX ideal ("Steady / Take it easy") — renaming `Readiness` enum raw values is a one-file change but touches shipped copy; decide before P3.
2. **Separate Superwall placement?** Whether to add `case recoveryHub` for independent paywall A/B, or stay inside `analytics_locked`. Marketing call; 4 switch entries either way.
3. **Future-load ghost bars** on BalanceCard (planned sessions as outlined bars — "how this week's remaining sessions will land given your recovery trend"): the one insight no competitor can render, but it needs a plan-session → estimated-`TrainingLoad` mapping that doesn't exist yet. P4 stretch or fast-follow.
4. **Manual sleep entry** for watch-less users (one-tap "hours slept" on SleepCard): included in the UX spec; confirm it's worth the input surface vs phone-detected duration alone.
5. **Post-workout reverse arrow** ("tonight, expect a dip — that's the training working"): a readiness *expectation* is a new prediction shape for a deliberately descriptive system — needs its own design pass before any engine work.
6. **Menstrual-cycle context** for the temperature trend (the copy already gestures at it): reading `HKCategoryTypeIdentifier.menstrualFlow` is a meaningful privacy-surface expansion — explicitly out of scope until decided.
---

## 11. Review amendments (2026-07-15 — adversarial completeness audit, 3 specialists, all code-verified)

The audit's bar: *every chart/vital must change a plan decision*. Verdict: the recovery-side coverage is genuinely complete vs Oura/Whoop/Bevel/Garmin; the systemic hole was **fitness-direction signals we read but never show**, plus four places the loop back into the plan wasn't closed. These amendments are COMMITTED scope.

### 11.1 Close the plan-adaptation loop (the audit's core findings)

1. **`PlannedLoad.swift` — new pure engine (open-question #3 → committed, P2).** `PlannedSession` → estimated `TrainingLoad`: `minutes = targetDurationS ?? (targetDistanceM/1000 × targetPaceSPerKm)`, intensity from `EffortAdaptation.expectedRPE(runType)` (same Foster session-RPE convention as `TrainingLoad.session`), distance fallback `km × 6`, strength ≈ Σ targetSets × ~3 min @ RPE 6. ~40 lines + fixtures. Unlocks three decisions: **future-load ghost bars** on BalanceCard (planned sessions as outlined bars against the recovery trend — the chart no competitor can draw), the race-day Form projection (11.1.2), and a **pre-week planned-vs-actual ACWR recheck** — `ACWRGovernor` runs only at generation against *planned* history; after misses/pauses the coming week can quietly exceed 1.3× the athlete's actual chronic. One consent-gated "next week is planned at 1.4× what you've actually been doing — trim?" proposal through the existing apply/`lastAdaptedAt` path.
2. **Race-day Form (TSB) projection — committed (P3/P4, dated-race plans only).** The taper is open-loop today (`taperMultipliers` fixed at generation; `RaceBriefing` static). Concatenate actual daily loads with `PlannedLoad` estimates for remaining sessions through `FitnessFreshness.series` (pure impulse-response — trivially projectable) and read the race-day point. Render as a **dotted extension of the already-planned CTL/TSB curve** with the race-day dot labeled via `formLabel` ("projected +12 — arriving fresh" / "projected −6 — this taper isn't tapering"), feeding `RaceBriefing` narration + a consent-gated taper trim. The feasibility verdict's missing final act.
3. **Illness-watch concordance INTO `RecoveryAdaptation` — committed (P2).** As drafted, respiratory/temp were score *modifiers* only — `decide()` couldn't see them, making "the score has a consequence" false for exactly the signals we're adding. Extend `RecoverySignals` with `respiratoryZ?` / `wristTempDeltaC?` (nil while baseline unbanded — the false-alarm guard carries over) and add two warning lines to `decide()`: "breathing rate above your norm", "running warm vs your normal". The 2-signal guard, aggressive leash, and DriverRow rendering work unchanged; concordant deviations legitimately trigger the ease. Stays OUT of `tripwire` (that's load+body; illness is body+body). Lilac + words, never red.
4. **`StrainRecoveryBalance.state == .overreaching` → week-level protective proposal — committed (P3).** A week of poor recovery at *normal* load (mean(readiness−strain) < −10 over ≥4 valid days) currently changes nothing — the only week trigger is completed-load ACWR. Reuse the consent-gated Proposal pattern → `apply(.ease)`, sharing the `lastAdaptedAt` gate (never stacks). Without this the signature chart informs no decision — failing the plan's own bar.
5. **Truthfulness fixes — committed (P3).** (a) Score-vs-action divergence: `MorningReadiness` can read Depleted while `decide()` returns nil (load-driven low, no acute signals) — DriverRow must say so honestly: *"low from training load, no acute body signals — the plan already carries this via your deload cadence"*; optionally count band ≤ depleted as one warning sign in `decide()` (bounded, fixture-tested). (b) §1's marquee line "your tempo moved to Thursday" overstates `applyToToday` (it *converts* quality → easy; nothing re-lands). Ship the honest copy ("today became easy on purpose") in P3; a bounded requeue (converted quality re-lands on the week's next open day respecting hard-day spacing) is a separately-decided fast-follow — never narrate what the engine can't back.
6. **ACWR chip in DriverRow when > 1.3** — the hub absorbs `recoveryCard` where the acwrGauge lives today; the load half of the tripwire must not become invisible until it fires.

### 11.2 Signal & chart completeness (adds ride on P1's history-query infrastructure)

1. **HRR trend chart → Progress → Trends** (new `TrendChartCard` in ProTrendsSection, NOT the hub — the hub answers "am I ready today"; HRR answers "am I getting fitter"). Weekly best/median of `.heartRateRecoveryOneMinute`, 12 weeks. Copy: *"How fast your heart settles after hard work — one of the most honest fitness signals there is. Watch it climb across a block."* (Fixes the plan's orphaned read.)
2. **Measured VO₂max trend — upgrade the existing Progress VO₂ card** (ProgressView:515). Today the headline can be device-measured while the sparkline silently charts the pace-ESTIMATED series — an honesty gap by our own standards. Chart the measured HK history when present, estimated as fallback. Copy: *"Your engine size, measured by your watch on real runs — the slowest-moving number you own, and the most worth moving."*
3. **VitalsBoard adaptive 4th tile:** wrist temp has no writer for Garmin/Oura/Whoop users (Apple keeps it S8+; vendors keep temp proprietary) — when the temp tile would be permanently empty, slot **walking HR** (baseline already specced) instead. Copy: *"Your heart's everyday cruising speed. Drifting up while training is flat is fatigue whispering before it shouts."* Tile priority: HRV, RHR, respiratory, temp-or-walkingHR.
4. **RhythmCard monotony footer** — `RecoveryModel.monotony` is computed and never rendered; the 4-week grid is a monotony visualization missing its conclusion. Worded, never the internal name: *"Good variety this week — hard days hard, easy days easy"* vs *"Days are blurring to medium — that's where strain builds quietly."*
5. **HRV reduction rule (§3 fix):** per-day median must prefer samples overlapping the sleep window (fallback all-day) — Watch writes daytime SDNN spot-checks that bias the baseline; Oura/Whoop are overnight-only for exactly this reason. Cheap now, a rebaseline event later.
6. **RhythmCard day-summary spec:** tap dot → "Strain 62 — mostly the tempo, plus a 14k-step day" (`DayStrain.workoutLoad`/`ambientLoad` split).
7. **ReadinessHeroCard confidence:** the engine's confidence tier renders in the partial-data footnote — that footnote is confidence's home; don't drop it in build.

### 11.3 Explicit additional rejections (append to §8 so they're never re-litigated)

- **`.appleSleepingBreathingDisturbances`** (iOS 18) — sleep-apnea-adjacent; invites "is something wrong with me" with zero training action. Violates never-a-diagnosis.
- **`.physicalEffort`** — duplicates `TrainingLoad` with an opaque Apple number; two strain currencies is the "two strains, one word" hazard squared.
- **Body-mass trend chart** — the read stays (calories/profile), but a weight trend line is diet-culture surface area in a "fueling, not dieting" app.
- (Blood pressure, daytime respiratory/skin-temp: no consumer-wearable HK source — correctly absent.)

### 11.4 Resolved open questions

- **OQ1 (name): RESOLVED** — segment "Health", score word "Readiness". Band-word softening (Strained/Depleted → warmer) still open, decide before P3.
- **OQ3 (ghost bars): RESOLVED — committed** via `PlannedLoad` (11.1.1).
- **OQ4 (manual sleep entry), OQ5 (post-workout dip expectation), OQ6 (cycle context): still open**, unchanged. Sleep latency + iOS 18 State of Mind: reviewed, correctly deferred past P4.

### 11.5 Phase impact

- **P1** unchanged + the HRV sleep-window median rule.
- **P2** + `PlannedLoad` + `RecoverySignals` illness fields + the two `decide()` lines (+ fixtures for all).
- **P3** = `HealthSegmentView` (segment, not pushed) + `ReadinessStrip` in Trends + `AppRouter`/`pendingNav.viewHealth` + `--progress-health` + truthfulness copy + overreaching proposal + VitalsBoard adaptive tile + monotony footer + ACWR chip.
- **P4** + race-day Form projection + ghost bars + HRR Trends card + measured-VO₂ upgrade.
