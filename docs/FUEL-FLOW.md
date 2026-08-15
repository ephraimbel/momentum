# FUEL — the complete flow (locked 2026-07-16)

> The fueling tracker's canonical UX spec. Amy Food Journal is the fit-and-finish bar ("calorie
> tracking as easy as Apple Notes"); momentum's edge is that fueling is judged **against the
> athlete's training** — floors, never ceilings; fueling, not dieting (ENDURANCE-FOCUS guardrail).

## The loop, end to end

**0 · Aim (optional)** — the **fueling adjuster** (top-left sliders, `FuelGoalsSheet`) sets how the
daily energy target works: *Fuel for training* (classic floors, default) · *Leaner* (Mifflin-St Jeor
maintenance − 400 with the RED-S guard: never below 1.1 × basal, the day's real burn always funds,
deficit pauses on race-eve/long days with a note) · *Build* (+300) · *Custom* (own numbers, prefilled
from the computed targets). Protein rises in a deficit (1.9 g/kg); **carbs stay KEYED to training,
and the goal now tunes the g/kg within the tier** (2026-07-22, user call): Leaner trims easy 3→2.5
and moderate 5→4 g/kg, Build adds half a gram to each — **long runs and race eve never move for any
goal** (the same protection as the energy-deficit pause: the goal must never raid the work). Custom
still overrides carbs outright. Body inputs (weight/height/age/sex, unit-aware) save to
the one profile; the preview is the same engine the page runs. Goal energy reads "kcal today"; the
classic floor keeps its "+".

**0 · Arrive** — the dashboard reads top-down: the day's **energy** as a perfectly centered
display numeral with its target in the caption beneath ("of 2,650+ kcal" for the classic floor,
"of 2,347 kcal today" for a chosen goal — same phrasing as the sheet's floor cell, still no clause
beside the numeral; 2026-07-22, the target used to live only in the tap-through), then the
**On-track strip** (it judges the whole day, so it caps the dashboard), then **one row of four rings**:
carbs · protein · fat · sodium — the numbers an athlete acts on TODAY. Each ring wears its
metric's ink with a soft color-matched glow (Theme.Fuel: honey gold, bright azure, peach, lilac)
and draws toward its FLOOR with a staggered trim-in, earning iridescence exactly when the floor
is met; a landing estimate rolls rings and numerals together. Iron/calcium/potassium/magnesium get
no daily RINGS (slow-moving markers don't belong on the dashboard) — but as of **2026-07-22 they
display in the Today card's MICROS grid** (tap the strip → sex-aware RDA/AI floors per micro), and
they are **estimated again**: they were cut 2026-07-21 while nothing rendered them (~¼ of every
response's tokens), and the card meeting the stated re-add condition brought them back. The staples
table carries curated micro values too, so a composed banana reports its potassium. Totals stay
nil-preserving, so meals from the brief no-micros window read honestly as "not estimated" rather
than zero. Then the page opens on the **composer**
(Amy: entry first — the journal is the point, the dashboard is not): one clean 26-pt
continuous-corner pill (the ChatGPT read) holding field + mic + send, waking with the coach
composer's iridescent ring + glow the moment you type or dictate. No disclaimer chrome. The
**calendar button (top right) opens History** — the day-by-day journal built for months of data:
always-visible search (words, item names, notes), sticky month headers with a logged-days count,
day sections with Σ trailers, iridescent dot on days that met the easy carb floor, same portion
editor on tap, one-year window (`--seed-fuel-history` exercises it at scale).
Directly under the energy numeral sits the **readout strip**, deliberately quiet: a
no-shame status word ("Building" / "On track" / "Fueled" — never "behind"), the carb numbers in
caption type (past the floor the fraction gives way to "≈390 g carbs banked" — a floor is not a
denominator to overshoot), a 5-pt band bar (iridescent exactly when the floor is met — earned),
the **FOR line** naming the session the carb target is keyed to ("FOR tomorrow's long session
(1h 45m)" — hidden on an easy horizon; race eve reads half a voice louder; 2026-07-22, the
plan↔fuel link used to live only in the tap-through), and the optional TIP line (`FuelTips` —
deterministic, one sentence, never nagging). **Tap the strip → the full story**
(`FuelReadoutSheet`, medium detent): the engine's plain-words headline, display-size carb number,
full bar, floor cells, and what session the target is keyed to. One engine, two zoom levels.

**1 · Capture** — one composer, two ways in, zero friction:
- **Type** it like a note: "2 eggs, toast with butter, coffee".
- **Speak** it: the mic button live-transcribes (on-device `SFSpeechRecognizer`) into the same
  field — tap to talk, tap to stop, words appear as you say them; review, then send. Voice is
  input-only sugar: everything downstream is identical.

**2 · Understand (the searching beat)** — on send the meal row lands **instantly** (offline-first,
nothing ever blocks) with the athlete's words and a **shimmer skeleton** where the numbers will
be — a soft gradient sweep (transform-only, Reduce Motion → static "Estimating…"). Meanwhile the
`meal-estimate` Edge Function (Gemini Flash primary, Claude fallback) parses the sentence.

**The searching beat only happens when the meal is genuinely new — resolution is a three-rung
ladder (2026-07-22), and the AI is the LAST rung.** On send:
1. **History** — the typed text is canonicalized (`MealTextKey`) and looked up against the
   athlete's own recent meals (`FuelLocalResolver`). Their (possibly hand-corrected) numbers
   outrank every table and every model.
2. **Staples** — no history hit, but every food phrase is in `FoodStaples`' curated deterministic
   table (gels, bananas, eggs, toast, sports drinks — countable, standard-portion foods only):
   the meal composes locally, itemized, confidence 0.9. "2 gels and a banana" never costs an API
   call, even on day one. One unresolved phrase kills the whole compose — plated meals ("big
   pasta dinner") are deliberately absent; guessing portions is the AI's job.
3. **AI** — the estimator, for everything the first two rungs honestly can't answer.
Rungs 1–2 resolve **instantly, offline, for free** — no shimmer, no badge, no toast: the absence
of the searching beat *is* the feedback. The hit carries the numbers and the itemized
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

**Only a call that was actually made can spend an attempt.** The attempt is taken at fire time (a
request that never returns — app killed, connection hung — has to burn one or the cap bounds
nothing) and handed straight back when the estimator reports it never reached the function:
unconfigured, no route to the host, or rate-limited before sending. Otherwise an hour in airplane
mode would exhaust a meal's whole budget on calls that cost nothing and were never made, and
landing would never bring the estimate back. A timeout deliberately still counts — those bytes went
out, and a meal that times out every visit is exactly the standing tax the cap is here to stop.

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
90-minute refuel window (banner slides in only while it's open — and it's an affordance, not a
statement: tapping it opens the composer with the keyboard up; 2026-07-22).

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
**Before any usuals exist, the row holds the staples starters** (2026-07-22): five
`FoodStaples.starters` quick-log chips ("banana", "energy gel", "sports drink"…) in the same chip
anatomy. Affordances, not sample data — nothing logs until tapped, every one composes
deterministically ($0, instant; a unit test pins it), and the row hands over to the athlete's own
usuals the moment they have any. They also carry the teaching-by-example the composer placeholder
used to (badly — it truncated).

**Typing a usual takes the same instant path** (see §2): chips and typed matches are grouped and
ranked by one shared rule (`MealTextKey.outranks` — the athlete's hand beats the estimate, then most
recent), drawn from one shared population (`FuelLocalResolver.candidates`) and copied by one shared
definition (`FuelLocalResolver.copyNumbers`), so tapping the chip and re-typing the meal produce
byte-identical rows. All three have to be shared: with two windows over the journal, a correction
the athlete made by hand can be visible to the typed lookup and invisible to the chip, and the same
words resolve differently depending on how you asked. Correct a bad estimate once and every future
match of that text inherits the correction.

## Spoken portions (2026-07-24)
Dictation never says "1/2" — it says "half of a rice krispie treat". `MealTextKey` v3
canonicalizes exact spoken cardinalities into the numeric forms the whole ladder already
understands, in one pre-pass before segmentation: "half (of) (a/an/the)" → `1/2`, "a quarter
(of)" → `1/4`, "three quarters" → `3/4`, "N and a half" → `N.5`. Only unambiguous amounts map —
"a couple"/"a few" stay unmatched (precision doctrine), a trailing "half" is a position not a
portion, and "half and half" (the creamer) is protected as one food before any rule runs. Net
effect: "half of a rice crispy treat" hits the same history/staples key as "1/2 rice crispy
treat" and scales every number by 0.5, offline, for free. Sized portions ("half of a LARGE
rice crispy treat") deliberately miss the table and go to the estimator, whose prompt now
carries a PORTIONS ARE EXACT contract (fractions scale, size words scale, "40g protein shake"
reads as nutrient content — deployed to `meal-estimate` 2026-07-24).

## The barcode lane (2026-07-24)
The one estimate-free path: scan a wrapper, read the LABEL. Deliberately **not** photo-calorie
guessing — we never estimate food from images. `BarcodeScanView` (full-screen camera,
monochrome chrome, torch, honest denied/miss/offline states) → `OpenFoodFactsService` (v2 API,
no key, nothing sent but the barcode) → the pure `BarcodeFood` engine decodes label JSON
(per-serving wins over per-100 g; kJ→kcal and salt→sodium ladders for EU labels; micros stay
nil when undeclared) and scales by the servings stepper with FoodStaples' rounding rule. Logs
as `source = "manual"`, confidence 1 — a label is ground truth, so it outranks any earlier AI
guess when the same words come back typed (`MealTextKey.outranks`). The scan button lives in
the composer beside the mic, behind the same Pro gate as send; `--barcode-demo` lands a canned
product for sim/UI-test coverage. Engine + decode fixtures pinned in `BarcodeFoodTests`.

## The health score (2026-08-15)
Every food gets a **0–100 health score** — computed by the deterministic `HealthScore` engine,
on-device, from facts the meal already carries. The AI's role stays facts-only: the estimate
schema grew four per-item quality fields (`fiber_g`, `sugar_g` total sugars, `satfat_g`, and
`nova` — the NOVA processing class 1–4), the staples table and the barcode lane (OFF declares
all four) carry the same fields, and the SCORE is pure client math (`HealthScoreTests` pins it).
Per-serving nutrient-profile model (all terms energy-density, since we have no gram weights):
sugars drag (softened by NOVA class — intrinsic fruit/dairy sugar is not added sugar), refined
carbs in processed foods drag, saturated fat past a 10%-of-energy grace band drags,
ultra-processing drags hardest; fiber, protein density, mineral richness (potassium proxy) and
whole-food class lift. **Sodium never counts against a food** (floors doctrine — it's a training
target; only an outsized >600 mg single-item load registers). Bands are descriptive, never
shaming: Whole (80+, mint) · Solid (60+, honey) · Mixed (40+, peach) · Processed (<40, garnet
rose — never alarm red). Race fuel scores low ON PURPOSE and the analysis says so out loud.

Surfaces: journal + history rows wear a **score chip**; the detail sheet leads with a live
**score gauge** (steppers roll it) + drivers line + the complete NUTRITION facts panel (macros,
fiber/sugars/sat-fat, all micros, fluids — "—" for not-estimated, never a fabricated zero); the
**masthead gauge (top right)** shows the day's energy-weighted score and opens **`FuelHealthView`**:
hero day verdict + plain-words headline, WHAT SHAPED IT driver rows, the race-fuel caveat,
LAST 7 DAYS band-colored bars with the week average, and TODAY'S FOOD, RANKED. Same
action-gated Pro door as History/Goals. A whole-food score (80+) earns iridescence on the gauge.
Old meals without the quality fields still score from macros+micros alone, just more roughly.
Recipes: `--fuel-health` self-pushes the page; `--meal-detail` opens the first today-meal's sheet.

## Later (explicitly deferred)
Add-an-item inside an existing meal · widgets/streak flair · fueling in MorningReadiness ·
fueling trends in Progress · refuel push notification · pre-race dinner reminder ·
off-label serving sizes for scans ("3 crackers" of a 30 g serving).
*(Day-history browsing + quick-repeat shipped 2026-07-16.)*
