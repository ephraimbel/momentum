# FUEL — the complete flow (locked 2026-07-16)

> The fueling tracker's canonical UX spec. Amy Food Journal is the fit-and-finish bar ("calorie
> tracking as easy as Apple Notes"); momentum's edge is that fueling is judged **against the
> athlete's training** — floors, never ceilings; fueling, not dieting (ENDURANCE-FOCUS guardrail).

## The loop, end to end

**0 · Arrive** — the **five fuel rings** sit on top (carbs · kcal · protein · fat · sodium), each
drawing toward its FLOOR with a staggered trim-in and earning iridescence exactly when a floor is
met; a landing estimate rolls ring and numeral together. Then the page opens on the **composer**
(Amy: entry first — the journal is the point, the dashboard is not): one clean 26-pt
continuous-corner pill (the ChatGPT read) holding field + mic + send, waking with the coach
composer's iridescent ring + glow the moment you type or dictate. No disclaimer chrome. The
**calendar button (top right) opens History** — the day-by-day journal (Σ line + meals per day,
iridescent dot on days that met the easy carb floor, same portion editor on tap, 60-day window).
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

**3 · Resolve (itemized)** — the shimmer crossfades into the result:
- **Per-item breakdown** (the Amy move): `2 eggs · toast, 1 slice · butter · coffee` — each item
  carries qty, unit, and its own kcal/carbs/protein/fat/sodium/fluids.
- Meal totals = Σ items (computed client-side so they always agree).
- One coach-toned **note**, session-aware ("Solid carb load before your 71-minute effort today").
- The day readout rolls live: numerals roll (`numericText`), the bar grows by transform, the
  status flips, the week dot fills.

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
- A log NEVER waits on the network; estimates self-heal on page appear.
- Every number reads ≈; the athlete's hand always outranks the AI's.
- Tips are one line, deterministic, and often absent — silence is a feature.
- Motion: transforms only, reveal-cascade entry, reduce-motion honored everywhere.
- No calories-left, no deficits, no diet or weight language, ever.

## Later (explicitly deferred)
Quick-repeat ("your usual breakfast") · add-an-item inside an existing meal · widgets/streak
flair · fueling in MorningReadiness. *(Day-history browsing shipped 2026-07-16 — `FuelHistoryView`.)*
