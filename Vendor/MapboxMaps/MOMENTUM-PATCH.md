# Momentum Mapbox maintenance note

This local Swift package is Mapbox Maps iOS **11.25.0**, upstream commit
`8f8eec8cdc91a629404f04d2dd30eb5109fca8e8` from
https://github.com/mapbox/mapbox-maps-ios.

`Package.swift`, `LICENSE.md`, `Sources/`, and `Tests/` are copied from that checkout.
The original license and acknowledgements are preserved. The Swift package still pins
MapboxCommon 24.25.0, MapboxCoreMaps 11.25.0, and Turf 4.0.0; the binary SDKs continue to
resolve from their official packages. The app's XcodeGen `project.yml` uses this local package.
Do not patch Xcode's shared package cache.

## Local change

Only `Sources/MapboxMaps/Ornaments/ScaleBar/MapboxScaleBarOrnamentView.swift` differs
from the upstream runtime sources. `docs/patches/mapbox-11.25.0-lazy-scale-label.patch`
in the app repository records the exact change.

MOMENTUM-IOS-G sampled a 7.1–7.9 second main-thread stall while the SDK rendered a
UILabel layer during MapView initialization. Momentum hides this ornament, but the
upstream initializer rasterizes it before application options can take effect.

The patch defers label and formatter creation, performs label rasterization only in
visible layout, preserves the bare zero label, and invalidates label images after unit
and locale changes. Revealing an ornament schedules pending layout; measured label widths
still update its intrinsic size. It does not alter maps, attribution, telemetry, billing,
location collection, or any public API.

The image-rendering helper becomes internal for regression-test observation. Tests live in
`MomentumTests/MapboxScaleBarRegressionTests.swift`; retain the upstream scale tests too.

## Updating

Replace these upstream directories and manifest from one known Mapbox release, preserve
its license, and reapply/review the recorded patch. Check the binary dependency pins.
Run the hidden/visible, cache, zero-label, unit-change and locale-change regressions plus
the upstream scale-bar fixtures. Build the Momentum app against the updated local package.
Remove the patch/local fork once an upstream version contains an equivalent verified fix.
