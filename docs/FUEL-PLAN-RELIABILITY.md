# Fuel and Plan reliability follow-up — 2026-09-07

This change covers estimation and Plan lifecycle safeguards. Training prescription quality and the screen redesign remain separate work.

## Implemented

- Photo instructions no longer add blanket hidden fat on top of prepared-food nutrition or multiply all restaurant portions. Uncertain portions must be disclosed, and training context affects coaching words rather than nutrient estimates.
- Explicit nutrition labels retain their calorie and gram values. Estimated calories allow fibre-related differences from general energy factors. Impossible nutrient masses and contradictory refusals are rejected.
- Request bodies are bounded while streaming, including requests without a Content-Length header. Provider error bodies are excluded from diagnostics.
- The client rejects unusable photos instead of silently estimating their caption, checks cancellation before sending, counts interrupted network requests toward retry limits, and prevents late responses from replacing an already resolved meal.
- Plan adjustment confirmations become stale when the day, athlete settings, completed training, race date or strength targets change. Deleted, detached, unreadable or wrong-athlete shelf records cannot enter the guarded scheduling/activation paths.

## Validation

- `deno test supabase/functions/meal-estimate/validate_test.ts scripts/meal_bench_metrics_test.ts`: **30 passed, 0 failed**.
- `deno check supabase/functions/meal-estimate/index.ts scripts/meal_bench.ts`: passed.
- Swift regression fixtures were added for retry accounting, late responses, stale Plan confirmations and invalid shelf records. Both the initial and corrected isolated iPhone 17 Pro / iOS 26.2 `build-for-testing` runs passed.
- The initial unit run passed FuelEstimatorTests, FuelPhotoJournalTests and PlanLifecycleTests. The new availability-change regression failed: Foundation Data hashing sampled bytes and missed a changed value inside the blueprint. A standalone Swift reproduction confirmed distinct Data values with equal hashes. The fingerprint now feeds every encoded byte to Hasher, and the corrected app/test binary builds. **The corrected regression has not yet rerun.**
- The initial broad run also failed/crashed in the concurrently added CommunityRouteRealismTests because the snapshot lacks the expected anchored/dense/trail route data. The runner recovered; the run was subsequently stopped while spending extended time in RoadPolicyShadowTests' exhaustive seeded matrix. Those unrelated files were not changed here.
- A rerun excluding CommunityRouteRealismTests and RoadPolicyShadowTests could not start: automatic permission approval review timed out twice despite explicit user approval. This is not a test result. Do not call this a clean full-suite run.
- No production Edge Function deployment or live model accuracy evaluation was performed for this change.

### Resume simulator verification

The isolated snapshot is `/var/folders/5_/35n79hj91mb5tn52fpw077_h0000gn/T/momentum-fuel-plan-8itce6_1`; the built products are in `/tmp/momentum-fuel-plan-derived`. The dedicated simulator UDID is `A48F1439-691B-4437-A020-F2FB20E2DB40`. The original checkout continues to change in Claude, so these results apply to the snapshot, not later edits.

Run from the snapshot to verify the corrected binary:

```sh
xcodebuild test-without-building -project Momentum.xcodeproj -scheme Momentum \
  -destination 'platform=iOS Simulator,id=A48F1439-691B-4437-A020-F2FB20E2DB40' \
  -derivedDataPath /tmp/momentum-fuel-plan-derived \
  -clonedSourcePackagesDirPath /Users/ephraimbelachew/Library/Developer/Xcode/DerivedData/Momentum-almqrkgljnlezkfmtbmqcivzvfxq/SourcePackages \
  -disableAutomaticPackageResolution -skip-testing:MomentumUITests \
  -skip-testing:MomentumTests/CommunityRouteRealismTests \
  -skip-testing:MomentumTests/RoadPolicyShadowTests \
  -resultBundlePath /tmp/momentum-fuel-plan-retest.xcresult
```

Verify actual executed test counts and specifically `changingAvailabilityRequiresANewPreviewWithoutChangingThePlan`. Restore full-suite coverage after the Community data work is ready, allowing time for the policy matrix. Initial output: `/tmp/momentum-fuel-plan-tests.log`; corrected build output: `/tmp/momentum-fuel-plan-rebuild.log`.

## Measure accuracy before making an accuracy claim

Repeatability is different from correctness. Use actual package labels or weighed ingredients with cited composition data as references. Do not use another model answer as ground truth. Include plain foods, mixed dishes, sauces, different portions, packaged foods, non-foods and unreadable photos. Retain the actual photos and preparation/portion notes used for each reference.

The benchmark accepts `--truth /path/to/references.json`. It reports all 13 supported nutrient fields, missing observations, repeatability, mean absolute error and percentage error where the reference is nonzero. Missing micros remain unknown rather than becoming zero. A single successful observation cannot establish repeatability. Refusal references are scored separately.

The reference file maps a JPEG basename without its extension to an object with `source` and `nutrients`. Nutrient keys are `kcal`, `carbs_g`, `protein_g`, `fat_g`, `sodium_mg`, `fluids_ml`, `potassium_mg`, `magnesium_mg`, `iron_mg`, `calcium_mg`, `fiber_g`, `sugar_g` and `satfat_g`. Include only values actually known from the reference. For non-food/unreadable images use `source` and `reason` (`not_food` or `unreadable`) instead. Every selected photo must have a reference when `--truth` is supplied.

With `MEAL_BENCH_URL` and `MEAL_BENCH_TOKEN` configured for an authorized canary:

```sh
deno run --allow-net --allow-read --allow-env --allow-write scripts/meal_bench.ts \
  --dir /path/to/reference-photos --truth /path/to/references.json --runs 3 --label candidate
```

Outputs are `bench-candidate.json` (raw responses) and `metrics-candidate.json` (nutrient metrics), inside the photo directory. Compare the same corpus against the current backend and candidate; investigate individual errors rather than relying only on averages. These contain meal data and should remain local evaluation artifacts.

Photos cannot reveal exact ingredient weights or hidden ingredients. These safeguards improve reliability but do not prove clinical accuracy or exact micronutrient measurement. USDA's [Foundation Foods documentation](https://fdc.nal.usda.gov/Foundation_Foods_Documentation/) explains why general and food-specific energy factors can differ; a macro-derived energy check should not rewrite an actual label.
