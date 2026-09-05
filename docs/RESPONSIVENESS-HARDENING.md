# Responsiveness hardening — 2026-09-04

Preserves the existing Today, Plan and Fuel design. This pass addresses work scheduling,
transition ownership and feedback scope; it does not change training advice or nutrition rules.

## Plan

- Removed the artificial 350 ms wait before the plan arc and coaching readout populate.
- Coaching uses the shared load verdict directly, without constructing the Progress page's
  weekly/daily chart series or decoding old GPS relationships for irrelevant historical loads.
- Acute/chronic math is one pass over scalar inputs; history normalization and decision boundaries
  remain shared with the full dashboard.
- Week paging refreshes week-scoped values only. Saves, plan replacement, session-count changes,
  returning to the tab and foregrounding refresh the wider readout. Equal-count edits no longer
  leave an old arc or proposal cached.
- The global recorder suppresses save-driven refreshes while covering Plan; saving each GPS sample
  must not trigger analytics underneath a live workout. Refresh resumes when the recorder closes.

## Today globe

- A map mounted from the strength home starts its flight on the actual style-ready event.
- Entry prepares the globe projection before flight, waiting for style readiness if the URI
  changes. Return keeps the globe style during camera movement and swaps at Mapbox completion.
- Unique action revisions reject stale callbacks, including enter/exit/enter/exit sequences.
- A cancelled camera flight preserves a user-interrupted camera while finishing the style handoff.
- Tab departure invalidates callbacks and cancels the view-owned presence request.
- Reduce Motion changes camera position directly. Returning without an authorized location never
  enters puck-follow mode or triggers an incidental permission request.
- The return control exposes an accessibility action as well as its map-safe tap gesture.

## Fuel

- Logging, repeating, deleting and applying estimates no longer wrap persistence or whole-page
  refreshes in animation transactions.
- Number transitions belong to individual labels, not surrounding cards or the scroll layout.
  Reduce Motion uses opacity instead of rolling numerals; progress gauges update without travel.
- The composer no longer animates its text layout when focus/dictation changes.
- The estimate status line reserves a Dynamic-Type-scaled minimum height. Long text may still
  grow naturally; no clipping or fixed-height accessibility compromise.
- An estimate must still own its generation token before applying a result or clearing the local
  task. A cancelled predecessor cannot remove a replacement spinner or expose the row for editing.

## Verification

Regression coverage is in `ResponsivenessTests` and `ResponsivenessUITests`, alongside existing
map-picker, coaching, fuel, handoff and scrolling suites. Tests exercise callback ordering,
load-band parity, mixed/large histories, draft retention, persisted local logs and repeated routes.

Run reset-based UI fixtures only on an isolated QA simulator or a separately identified QA build.
Never use `--reset-store` on an athlete's real installation. Simulator timing is diagnostic, not
proof of physical-device frame pacing, energy use, thermal behavior or production crash rate.

### Results and remaining verification

- Standard Debug `build-for-testing` succeeded, followed by `test-without-building` on the
  isolated Momentum Motion QA simulator (iPhone 17 Pro, iOS 26.3.1,
  `D82EC62E-A75E-41CA-8D9F-D6A4D5F5EE58`). No low-disk compiler-setting overrides were used.
- The valid `/tmp/momentum-smooth-resume.xcresult` summary records **1,961 passed, one intentional
  diagnostic skip, zero failures** (1,962 total tests). The unit runner reports 1,949 tests in
  222 suites; the UI runner reports all 13 selected checks passed. Parameterized executions can
  make device-level execution totals differ from the summary's unique-test count.
- All 11 responsiveness unit checks passed. The 10,000-workout in-memory load-only check took
  approximately 12.4 ms in this concurrent run (earlier focused run: 5.7 ms). This excludes database
  materialization and is not a physical-device frame-time claim.
- UI coverage passed for every map style and persistence, five handoff/control checks, Plan/Fuel
  scrolling, three globe round-trip variants (normal, strength-first mount, Reduce Motion),
  long-plan week selection/tab return, and Fuel repeat/draft retention/persistence after relaunch.
  The previously failing globe and time-dependent Fuel fixtures passed after correction.
- Inspected exported screenshots of the ready globe, restored Today map/deck, long-plan board,
  and two local meal rows with the unsent draft retained. Attachments and their manifest are in
  `/tmp/momentum-smooth-resume-attachments`. Screenshots confirm the captured states, not motion
  frame pacing; scrolling measurements have no physical-device regression baseline.
- The owner-approved `build/DerivedData` cache was removed to unblock compilation. This pass's
  temporary compiler intermediates, index and module cache were also discarded after compilation
  to leave room for the report. They are regenerable; sources, built products, reports and app data
  were preserved. `-collect-test-diagnostics never` suppressed verbose failure-time system dumps,
  not assertions or screenshots. Disk space remains constrained for future builds.
- Concurrent Fuel work continued after this binary was built (`FuelView.swift` changed at 22:35,
  after the 22:22 binary). These results apply to the tested build, not to later unbuilt changes.
  This pass's Today/Plan/motion/ownership sources and regression tests remained unchanged; the
  Fuel motion modifiers, composer identifier and estimate ownership guard are still present.
  Later Fuel changes require verification in their own task. `git diff --check` passed.
- A paired iPhone 15 Pro was available, but installation of an isolated QA build was not approved
  during this pass. Physical-device profiling, thermal/energy behavior and outdoor GPS QA remain
  unverified. No claim of bug-free or production-wide performance is made.
