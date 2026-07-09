# Running-excellence audit — findings & status (2026-07-06)

Audit of the parallel R1 (guided run) / R2 (post-run charts) / R4 (race predictor) / R3 (HR zones) work.
Build green, all 289 unit tests pass, and the key flows verified end-to-end in the sim (guided interval
run advances through steps; run detail shows charts; profile grid + immersive pager; projected-races card).
This is a coordination note so both terminals share one picture.

## Fixed in this pass
- **HIGH — guided run could stall on GPS auto-pause.** `CardioViewModel.tickStructured` drove the tracker
  off `elapsed()`, which freezes on *auto*-pause — exactly what happens when you slow to a walk during a
  timed **recovery**, so the recovery never counted down. Added a **manual-only** clock
  (`structuredElapsed()`, frozen only when *you* tap Pause) and switched the tracker + step-remaining +
  step-progress + skip re-anchor to it. Moving-time (`elapsed()`) is unchanged for the run's saved duration.
- **MED — `parseIntervals` misread km rep distances** ("5×1km" → 1 m). Now unit-aware (`km`/`k` → meters);
  regression tests added (`StructuredWorkoutTests.parsesIntervalStrings`). Foundation for the roadmap's
  km/hill-rep variety (RUNNING-EXCELLENCE R2/R4, ROADMAP P1 #5).
- **MED — splits bar chart read "up = slower," opposite the pace line above it.** `RunCharts.splitsCard`
  now plots inverted magnitude so **taller = faster** (subtitle says so; m:ss labels carry exact values;
  iridescent stays on the best *full* split). Matches the pace line's up-is-faster reading.
- **LOW — dead `durationS` param** on `RunAnalysisSection` removed; **splits/pace gated off rides**
  (pace-per-mile splits are the wrong metric for cycling; elevation still shows).
- **LOW — first guided step now fires `Haptics.medium()`** at "go," matching every later transition.
- **Docs** — reconciled the `COACHING-LOOP-AUDIT.md` status (the loop is *closed* now; that doc's status
  table is stale — noted in `RUNNA-COMPETITIVE-ROADMAP.md`, which is now a stated companion to
  `RUNNING-EXCELLENCE.md`).

## Verified working (no change needed)
- Guided-run banner, rep dots, skip, completion, audio cues — solid and on-brand.
- Post-run pace / splits / elevation charts.
- **Race-predictor card renders** on Progress → Trends for runners (5K/10K/half/marathon from
  `AthleteModel` snapshot p5k, else plan p5k). An earlier "missing" reading was a scrolled screenshot.

## Open — for the R1/R3 owner (not touched, to avoid clobbering active work)
- **`HeartRateZones` is fully built + tested but wired nowhere.** Expected (HR capture is R3-pending). Add an
  HR-zone section to `RunAnalysisSection` once runs capture HR, or hold the engine out of the target.
- **`SessionDetailSheet` structured preview assumes a single rep group** (`:169` skips contiguous
  work+recovery after the first). Latent — the generator emits one group today; a future "3×800 then 4×400"
  would render only the first block.
- **`stepProgressBar` / `goalBar` animate `.frame(width:)` without gating on Reduce Motion**
  (`CardioTrackingView`). CLAUDE.md wants transform/opacity animations only, gated on
  `accessibilityReduceMotion`. Prefer a scaleX transform gated on `reduceMotion`.

## Accepted (design convention, not fixing unilaterally)
- **Iridescent glyph tile** (`WorkoutTileMedia.glyphMedia`) for photo-less/timed workouts — flagged as
  decorative iridescence, but it matches the existing `CompletedWorkoutCard` glyph-banner convention.
  Change both or neither; leaving consistent for now.
- **Iridescent underline on the Highlights profile tab** — a selection indicator, but that tab holds PRs, so
  it's a defensible earned accent.

## Product direction (shared understanding)
Both docs agree: **structured workouts + live guided execution is Runna's core moat and our #1 gap** — now
built (R1). Our edges over Runna: automatic no-shame adaptation, the Athlete Model long-term memory, hybrid
run/lift sequencing, and the monochrome-iridescent design. One framing to align on: ROADMAP says running is
"first-among-equals, keep the hybrid wedge"; RUNNING-EXCELLENCE sets the bar at "a pure runner would still
choose us." Same direction — build running to Runna-grade — just calibrate how absolutist to be. Known
unfixed quality gap in both: intervals are prescribed at exactly 5K pace (no VO2/threshold split) — a real
P1 improvement, not yet done.
