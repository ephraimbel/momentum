# Onboarding: a personal training introduction

Owner direction, 2026-09-04: shorten onboarding while keeping useful planning inputs, the iPhone
preview pages, premium materials, and subtle page animations. Present Momentum as a professional
training platform. Do not introduce it as a "paid training app." The hard paywall remains.

This supersedes the longer quiz / commitment-beat proposals in ONBOARDING-MOTION-PLAN.md.

## Experience arc

1. **Welcome: the brand.** Keep the full-screen film and its original MOMENTUM / KEEP MOVING
   closing frame. No additional headline or supporting paragraph competes with the film's
   typography. Only "Build my plan" and the quieter returning-account link sit at the bottom;
   the lower scrim protects those controls while leaving the film clear above them.
2. **Your profile, then your goal.** Name and @username share the first setup page. Suggest a
   username from the name; retain a deliberate edit and show advisory availability. Goal,
   supporting activities, and race details follow. Optional finish time opens a matching sheet.
   Distance units live in the question header after profile setup.
3. **Your starting point: understanding.** Running level and optional recent result; current volume
   and longest run for non-beginners; injury history; optional personal details. Name and username are already
   complete from the first page. Weight and height retain independent unit controls. Strength experience
   and muscle emphasis remain conditional. Do not infer today's recovery from Health connection.
4. **Your training week: fit.** Frequency and preferred weekdays share an interactive week page.
   Session length stays a separate, focused question. Equipment retains a lifting-split
   menu. Hybrid emphasis remains explicit because it changes the number of running days.
5. **Your approach: confidence.** The existing Health iPhone preview explains future recovery
   signals. The feasibility assessment uses the supplied goal, baseline, and schedule before
   recommending intensity. Preserve the reminder and route iPhone previews, with system prompts
   resolved before generation. These pages demonstrate capabilities and change the visual rhythm.
6. **Build and reveal: ownership.** Preserve the animated build and named plan arrival. Show the
   volume curve, training briefing, complete first week with every session open, statistics, and
   later weeks on one scrollable page. The membership CTA stays pinned; no extra details sheet.
   The curve animates when reached. A finite, multicolored paper burst marks the named arrival;
   Reduce Motion uses a short static crossfade.
   Read the opening schedule from generated sessions, including any constraints; do not repeat
   requested availability as if it were guaranteed to match the output.
7. **Membership: continuity.** "Continue with Momentum Pro" opens personalized checkout directly.
   The goal remains visible. No second welcome or mandatory generic feature tour. Existing live
   pricing, eligibility, Restore, persisted hard gate, and narrow store-outage deferral remain.
   Account setup follows entitlement. Profile photos remain in Edit Profile; name and handle are collected first.

## Length and information

A non-beginner running-only athlete without a race answers **10 question pages, previously 14**.
A beginner omits current-volume entry. Race setup adds one page. Strength adds only applicable
equipment, emphasis, and muscle-focus pages. Health, reminders, location, build, reveal, checkout,
and optional account are additional stages; the ten-page count does not hide those stages.

Shortening comes from grouping related decisions and removing decorative setup. Baseline, volume,
longest run, volume ceiling, injury history, body estimates, availability, session length, equipment,
strength split, hybrid emphasis, race date/time, and intensity remain available. The separate
motivation question is removed; it did not determine the training prescription.

## Motion and interaction

- Primary choices fit the compact iPhone viewport at standard text size, with one pinned CTA.
  Overflow scrolling stays available for accessibility text and the keyboard. Optional details
  use consistent native sheets rather than expanding the question into a long page.
- White cards share a 16-point radius, restrained shadow, and consistent type and selection states.
  Directional page transitions travel 20 points over 360 ms; presses scale to 98%.
- A stable header names the chapter; forward/back navigation retains direction. The progress fill
  scales horizontally rather than animating layout width, with a small marker at the tip of the fill.
- Headings arrive first. Onboarding uses its own soft 460 ms arrival with 18-point lifts (10 for
  the opening heading, 26 for the iPhone preview), independently of everyday screen transitions.
  Option entrances stagger by 45 ms, capped at 285 ms so long lists do not
  make the last choices wait. Continue stays pinned and never waits for decorative motion.
- A pressed card yields slightly; selection changes its indicator and gives a light haptic.
  The chosen icon and indicator settle with a small spring. Preferred days respond the same way;
  number steppers have press feedback and rolling values, scoped to the numeral rather than the row.
  Continue has a quiet forward arrow and fades into readiness when required input becomes valid.
  Remove random "Nice pick" toasts. Explanations should describe the decision being made.
- Keep the iPhone frames and existing permission previews. They have one clear purpose per page;
  none is an extra marketing interruption after the personal plan reveal.
- The reveal retains its more expressive earned animation, but the settled page prioritizes useful
  training. No review solicitation interrupts that moment.
- Honor Reduce Motion. Content and selected values must remain visible without motion. No repeated
  celebration, flashing, or extra delays are added to make the interview feel longer.

## Integrity and verification

Retain historical step IDs for analytics. Migrate saved drafts from removed pages to their combined
destinations without dropping answers. Use live flow order for progress and resumed intensity
choices. An old draft with an unselected race must revisit race setup before proceeding. A draft missing
name or username returns to the first profile page without losing training answers.

Verify the complete unit suite plus focused simulator checks for the combined pages, required
baseline, reveal-to-checkout handoff, purchase/account handoff, hard-gate relaunch, and store outage.
Inspect the real screens in light/dark appearance and with Reduce Motion. Conversion improvement
is a hypothesis; evaluate it with onboarding completion, checkout conversion, and first-session
completion after release.

### Interface artwork guard

Decorative emoji are bundled artwork, never text glyphs. The existing CI SwiftLint step rejects
literal and Unicode-escaped emoji in interface strings; comments and the two dormant conversational
content generators are excluded. User-entered text remains user content.

Paywall flag/apple images use generated asset references, so a missing or renamed asset fails to
compile. Race glyphs are private to the catalog; views use `flagArtworkName`. `InterfaceArtworkTests`
loads every country flag and both paywall images from the compiled app in light and dark appearances.
Adding a country requires running `swift scripts/render_race_flags.swift` and passing that test.

### Verification of the initial restructuring, 2026-09-04

- Full unit suite: 1,900 passed, one skipped, zero failures.
- Focused onboarding UI suite: all 10 passed, including the complete guest interview, name
  persistence, combined schedule and units, direct checkout, purchase/account handoff, gate
  relaunch, and store-outage deferral. Xcode then failed to finalize its result bundle because
  the disk filled; the completed test transcript is saved in
  `work/onboarding-direction/ui-test-results.txt`.
- Inspected the welcome during playback and on its closing frame, plus goal, schedule, personal
  details, race setup, Health preview, and the expanded first session on iPhone 16e. Also checked
  reduced-motion presentation and dark system appearance (onboarding retains its light palette).
- Race flag and apple-scan paywall illustrations use bundled artwork. The simulator runtime's
  missing Apple Color Emoji font caused both text glyphs to fall back to question-mark boxes;
  the illustrations no longer depend on that font. Existing animation timing and overlays remain.

### Verification of the visual polish and identity-first flow

- Full unit suite: 1,914 passed, one skipped. After the final draft-migration adjustment, all
  24 onboarding flow and draft tests passed again, including preservation of an athlete's
  intensity choice when an older draft returns to collect missing identity.
- All 12 focused onboarding UI checks passed, covering name and username persistence, the
  complete guest interview, plan detail presentation, checkout, account handoff, and relaunch.
- The final compact-phone fit check passed across 12 page configurations, including hybrid
  running/strength experience, measurement margins, muscle focus, and a short race timeline. Native picker controls have
  stable accessibility identifiers so layout checks do not depend on their composed labels.
- Standard-size questions keep their controls above the pinned Continue button. Overflow
  remains available for accessibility sizes and keyboard entry; full-plan detail is opt-in.
- Updated screenshots are in `work/onboarding-direction/screenshots/polish/`.

### Verification of artwork protection and livelier interaction

- Rebuilt with `build-for-testing`, then ran those binaries with `test-without-building`.
- 38 unit tests passed: compiled artwork loading in both appearances, race catalog, onboarding
  flow, and draft restoration. All 28 country flags and both animated paywall images loaded.
- Three UI tests passed: selection and back navigation with motion on and with Reduce Motion;
  schedule/units persistence; and all 12 compact-phone question layouts above Continue.
- The emoji lint rule passed across app, watch, and widget UI. Negative probes for literal flag,
  apple, star, and escaped emoji were rejected; comments and bundled images were accepted.
- Changed production files passed SwiftLint. The full repository lint run still reports existing
  violations outside this change, recorded in `/tmp/momentum-interface-lint.log`.
- Inspected the selected goal and schedule screenshots, plus the running paywall's flag and apple.
  Previews and verification summaries are saved under `work/onboarding-direction/`.

### Complete plan reveal — 2026-09-04

- Replaced the compact first-session preview and Explore sheet with one scrollable reveal:
  training curve, briefing, every first-week session open, statistics, personal inputs, and later weeks.
- Chart placement updated 2026-09-05: directly below the plan headline and above the training
  briefing. Its entrance waits for the opening title to clear and for the chart to be visible;
  Reduce Motion shows the finished chart immediately.
- Kept the membership CTA pinned. Session details have no expanding layout; sections enter once
  when reached. The chart now waits until visible, and interrupted arrival state settles on exit.
- The reveal stays restrained: the named arrival, plan-ready seal, earned aurora, and scroll-led
  plan motion carry the moment without a confetti overlay.
- Verified with UI checks covering the complete scroll in both motion modes and the
  reveal-to-hard-paywall handoff/relaunch. Build and changed-file lint passed.
- Simulator captures and arrival video: `work/onboarding-direction/screenshots/full-reveal/`.

### Animation lifecycle review — 2026-09-04

- The welcome film now pauses whenever onboarding covers it or its scene becomes inactive,
  and explicitly tears down its player on removal. Deferred setup reads the current pause state
  and cannot start a player after the view has been dismantled.
- Reduce Motion uses `WelcomeClosingPoster` directly; no video player is created. The still is
  the bundled `WelcomeVideo.mov` closing card at 14.7 seconds, so the wordmark stays identical.
- The reminder banner's delayed entrance is a cancellable page task. Leaving the page cancels
  the entrance and resets its state for a later visit.
- Injury choices keep stable geometry, including space for their coaching note. Selection uses
  a brief color fade. The race-time row no longer animates its layout while editing.
- Plan generation checks task cancellation and the current page after every pacing delay.
  The build screen shares onboarding's display typography and Reduce Motion reader; its
  iridescent ring is static in reduced mode. Checkout uses that same accessibility reader.
- Verification artifacts: `work/onboarding-direction/animation-audit/` (UI screenshots,
  a simulator motion recording, and test-result summaries).
- Final verification passed: 48 distinct unit tests and 13 distinct UI tests, including
  the complete guest journey, both motion modes, double-tap navigation, interrupted building,
  name/handle and schedule persistence, all 12 compact-phone layouts, and hard-gate/outage recovery.
  The final build and changed-file SwiftLint checks passed.
