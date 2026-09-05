# Map picker polish

The existing two-family grid remains. A fixed header explains the app-wide preference and keeps
Done reachable while browsing. Selection uses a lavender outline plus a checkmark (not color
alone); previews use the existing press feedback and opacity-only crossfades. Accessibility text
sizes use two columns, then image-and-label rows at the three largest sizes, with the large sheet
detent. Explanatory text scrolls away so navigation stays reachable. Labels never shrink to fit.

## Interaction guarantees

- A free/entitled selection applies immediately and persists through `MapStyleOption.storageKey`.
- A locked tap leaves the current style unchanged and presents Pro from the picker’s nested host.
  Dismissing Pro returns to the picker, without another paywall waiting behind the sheet.
- Entitlement loss normalizes a locked selection to Realistic, including while the picker is open.
- Realistic follows app appearance. Explicit Light, Dusk and Night choices remain literal.
- Heatmap lighting changes independently of its URI; heat layers and the user’s camera stay intact.
- Today preserves the current center, zoom and bearing across a style change. Existing authorized
  location-following stays on; a panned map never jumps back to the athlete or requests permission.
- Preview failure never disables selection or dismissal. Failed images retry on reopening.

## Preview pipeline

`MapStylePreviews.swift` owns the bounded two-job queue, in-flight sharing, cancellation, memory
cache and disk cache. Requests include rendered lighting, geographic bucket, dimensions, scale
and camera pitch. Invalid coordinates/geometry are normalized before calling Mapbox.

Disk decode/encode/I/O run off the main actor; writes are atomic. NSCache budgets 36 images / 16 MB.
Rendering observes style events before loading, handles fatal style errors and
has a 12-second deadline. Cancelling the last subscriber stops its render; stale callbacks cannot
complete a newer request. Mapbox’s snapshot logo/attribution is retained, not cropped off.

## Verification

`MapStylePreviewTests` covers lighting policy, cache identity, invalid input, entitlement fallback,
concurrency bounds, shared requests, cancellation, stale completions and retry after failure.
It also checks the camera handoff for panned, following and unauthorized viewports.
`MapPickerPolishUITests` exercises every style, relaunch persistence, Pro return, unavailable
previews, Reduce Motion, dark appearance and accessibility text size.

Validated 2026-09-04 on the dedicated iPhone 17 Pro simulator (iOS 26.3.1):

- Build-for-testing succeeded. The complete unit target passed **1,909 tests**, with one
  intentionally skipped diagnostic, before the final camera/layout refinement.
- Rebuilt after that refinement: **12 map-focused unit tests + 7 UI tests passed**, zero failures
  or skips. This includes all nine styles, persistence after relaunch, repeated Pro return,
  unavailable-preview fallback, Reduce Motion, large text and Dusk → Night → Dark heatmap changes.
- Reviewed final screenshots in light/dark appearance and the largest accessibility text size;
  also confirmed distinct Dusk/Night lighting with the heat overlay and camera retained.
- `git diff --check` passed. No training-engine or workout-persistence logic changed.

Physical-device frame timing and real StoreKit purchase/restore remain separate checks; simulator
passes do not prove zero hitches or guarantee every network/device condition. The unavailable
preview test simulates a failed thumbnail loader; it does not disable the device’s network.
