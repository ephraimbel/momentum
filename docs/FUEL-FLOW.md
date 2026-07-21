# FUEL — the complete flow (locked 2026-07-16)

> The fueling tracker's canonical UX spec. Amy Food Journal is the fit-and-finish bar ("calorie
> tracking as easy as Apple Notes"); momentum's edge is that fueling is judged **against the
> athlete's training** — floors, never ceilings; fueling, not dieting (ENDURANCE-FOCUS guardrail).

## The loop, end to end

**0 · Aim (optional)** — the **fueling adjuster** (top-left sliders, `FuelGoalsSheet`) sets how the
daily energy target works: *Fuel for training* (classic floors, default) · *Leaner* (Mifflin-St Jeor
maintenance − 400 with the RED-S guard: never below 1.1 × basal, the day's real burn always funds,
deficit pauses on race-eve/long days with a note) · *Build* (+300) · *Custom* (own numbers, prefilled
from the computed targets). Protein rises in a deficit (1.9 g/kg); **carbs stay keyed to training
unless custom overrides — that's the moat.** Body inputs (weight/height/age/sex, unit-aware) save to
the one profile; the preview is the same engine the page runs. Goal energy reads "kcal today"; the
classic floor keeps its "+".

**0 · Arrive** — the dashboard reads top-down: the day's **energy** as a perfectly centered
display numeral (caption "kcal" / "kcal goal" beneath — no clause beside it), then the **On-track
strip** (it judges the whole day, so it caps the dashboard), then **one row of four rings**:
carbs · protein · fat · sodium — the numbers an athlete acts on TODAY. Each ring wears its
metric's ink with a soft color-matched glow (Theme.Fuel: honey gold, bright azure, peach, lilac)
and draws toward its FLOOR with a staggered trim-in, earning iridescence exactly when the floor
is met; a landing estimate rolls rings and numerals together. Iron/calcium/potassium/magnesium
are estimated and stored but NOT displayed (slow-moving health markers on the AI's roughest
numbers — the future surface is a monthly coach insight, never near-empty daily gauges). Then the page opens on the **composer**
(Amy: entry first — the journal is the point, the dashboard is not): one clean 26-pt
continuous-corner pill (the ChatGPT read) holding field + mic + send, waking with the coach
composer's iridescent ring + glow the moment you type or dictate. No disclaimer chrome. The
**calendar button (top right) opens History** — the day-by-day journal built for months of data:
always-visible search (words, item names, notes), sticky month headers with a logged-days count,
day sections with Σ trailers, iridescent dot on days that met the easy carb floor, same portion
editor on tap, one-year window (`--seed-fuel-history` exercises it at scale).
One glance below the composer sits the **readout strip**, deliberately quiet: a
no-shame status word ("Building" / "On track" / "Fueled" — never "behind"), the carb numbers in
caption type, a 5-pt band bar (iridescent exactly when the floor is met — earned), a one-line
floors readout, and the optional TIP line (`FuelTips` — deterministic, one sentence, never
nagging). **Tap the strip → the full story** (`FuelReadoutSheet`, medium detent): the engine's
plain-words headline, display-size carb number, full bar, floor cells, and what session the
target is keyed to. One engine, two zoom levels.

**1 · Capture** — one composer, two ways in, zero friction:
- **Type** it like a note: "2 eggs, toast with butter, coffee".
- **Speak** it: the mic button live-transcribes (on-device `SFSpeechRecognizer`) into the same
  field — tap to talk, tap to stop, words appear as you say them; review, then send. Voice is
  input-only sugar: everything downstream is identical.

**2 · Understand (the searching beat)** — on send the meal row lands **instantly** (offline-first,
nothing ever blocks) with the athlete's words and a **shimmer skeleton** where the numbers will
be — a soft gradient sweep (transform-only, Reduce Motion → static "Estimating…"). Meanwhile the
`meal-estimate` Edge Function (Gemini Flash primary, Claude fallback) parses the sentence.

**The searching beat only happens when the meal is genuinely new.** Before the composer touches the
network, the typed text is canonicalized (`MealTextKey`) and looked up against the athlete's own
recent meals (`FuelLocalResolver`). An exact-normalized hit resolves the meal **instantly, offline,
for free** — the same path the usuals chip takes, reached by typing. No shimmer, no badge, no toast:
the absence of the searching beat *is* the feedback. The hit carries the numbers and the itemized
breakdown but **never the old coach note** (it narrated a different day's session — carrying it
forward would be a fabricated claim). The athlete's own words for today stay theirs. The matcher is
biased hard toward precision: quantities stay welded to their food ("2 eggs, 1 slice toast" never
matches "1 egg, 2 slices toast"), digits and duplicates are preserved, plurals are deliberately not
stemmed. A miss costs one cheap estimate; a wrong match would silently write someone else's
nutrition into the day, so it must never happen.

If an estimate genuinely can't be parsed, the retry is **capped** (3 attempts per meal, persisted on
the model). Past that the meal rests honestly on its "Couldn't estimate — tap to set the numbers"
line instead of re-billing an API call on every tab visit, forever. Long-press → **Estimate again**
always overrides the cap: the limit is the app's, never the athlete's.

**3 · Resolve (itemized)** — the shimmer crossfades into the result:
- **Per-item breakdown** (the Amy move): `2 eggs · toast, 1 slice · butter · coffee` — each item
  carries qty, unit, and its own kcal/carbs/protein/fat/sodium/fluids.
- Meal totals = Σ items (computed client-side so they always agree).
- One coach-toned **note**, session-aware ("Solid carb load before your 71-minute effort today").
- The day readout rolls live: numerals roll (`numericText`), the rings and bar grow by
  transform, the status flips.

**4 · Refine (portions)** — tap the meal → the detail sheet:
- Each item is a row with **qty steppers** (±½ serving, floor ½): numbers scale linearly from the
  item's per-unit values and roll as they change. Portion truth belongs to the athlete.
- Stepping **− at the ½ floor removes the item** (the natural "actually, none of that");
  long-press → Remove item works too. Totals recompute instantly.
- "Set totals by hand" swaps an itemized meal to the five direct fields (prefilled with Σ) for
  athletes who'd rather own the numbers outright.
- Any numbers change marks the meal `manual` — a later re-estimate never overwrites it. (A
  time-only edit doesn't: a pending meal whose clock you fix can still estimate.)
- No items (offline log that never estimated)? The sheet opens on the direct total fields.
- Eaten-at time is editable; Delete meal lives here too.

**5 · The day understands you** — every change re-runs the deterministic `FuelReadiness` judge:
carb target keyed to the biggest session in ~36 h (race-eve = the classic load), energy floor =
baseline + the day's real burn, protein 1.4 g/kg, sodium baseline + sweat add-on, day-paced status,
90-minute refuel window (banner slides in only while it's open).

**6 · The app understands you** — fueling flows outward:
- **Today**: the plan row's fuel line on long-run mornings (tap-through = full guidance).
- **Post-run summary**: the REFUEL card in the recovery window.
- **Coach**: the chat's context carries a one-line fueling digest (today's ≈carbs vs target +
  status), so "should I eat more before tomorrow?" gets a personal answer.
- **Race briefing**: race-week fueling was already woven in (Riegel-predicted finish → plan).

## Rules that make it feel right
- A log NEVER waits on the network; a meal the athlete has logged before resolves locally with no
  network at all; estimates self-heal on page appear, up to a bounded 3 attempts per meal.
- Every number reads ≈; the athlete's hand always outranks the AI's.
- Tips are one line, deterministic, and often absent — silence is a feature.
- Motion: transforms only, reveal-cascade entry, reduce-motion honored everywhere.
- No calories-left, no deficits, no diet or weight language, ever.

**1.5 · Repeat (the usuals)** — under the composer, up to five chips of the athlete's
most-repeated meals (recency breaks ties; new users see recents — same rule, no cliff). One tap
re-logs it instantly: numbers and items copy over, the clock is now, the stale session note stays
behind. No AI round-trip, no waiting — the daily-logger's path is one tap.

**Typing a usual takes the same instant path** (see §2): chips and typed matches are grouped and
ranked by one shared rule (`MealTextKey.outranks` — the athlete's hand beats the estimate, then most
recent) and copied by one shared definition (`FuelLocalResolver.copyNumbers`), so tapping the chip
and re-typing the meal produce byte-identical rows. Correct a bad estimate once and every future
match of that text inherits the correction.

## Later (explicitly deferred)
Add-an-item inside an existing meal · widgets/streak flair · fueling in MorningReadiness ·
fueling trends in Progress · refuel push notification · pre-race dinner reminder.
*(Day-history browsing + quick-repeat shipped 2026-07-16.)*
