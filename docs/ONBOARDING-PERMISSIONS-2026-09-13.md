# Onboarding permission verification — September 13, 2026

Resetting Momentum's local store/auth does not reset iOS Health or location consent. The simulator opened for the initial 1.9.0 walkthrough retained those choices. Apps cannot force the first-use location alert to repeat after a denial; Settings is the recovery path.

## Changes

- Health/location page tasks retry after foreground activation and consume their automatic-request latch only after the page has settled. Cancellation and step changes are rechecked after the asynchronous Health status query.
- A Health status-query error or unknown result no longer suppresses the authorization request. Only a definite `unnecessary` result does.
- Pending requests block backward navigation; a late callback cannot advance a different step.
- Location completion waits for the app's active scene and a short presentation-settling interval. The new denial test reproduced a primer left onscreen after the native denial; the same unchanged completion assertion passes with the deferred handoff.
- Previously answered Health consent is explained on the page. Location denial provides an Open Settings button, and continuing without access remains supported.
- Added a DEBUG Health-step deep link and stricter permission UI coverage. Neither the plan engine nor Health workout-import policy changed.

## Verification

Xcode 26.2; iPhone 17 Pro / iOS 26.2; simulator `1DAC0CED-067B-437C-8127-9A19C63624D1`; derived data `/tmp/momentum-activation-v2-build`.

Ran `build-for-testing`, then `test-without-building` with `-only-testing:MomentumUITests/OnboardingLocationHandoffUITests -only-testing:MomentumTests/HealthSignalConnectionTests -parallel-testing-enabled NO`.

Final result: `/tmp/momentum-permissions-handoff.xcresult`. xcresulttool confirms **4 passed, 0 failed, 0 skipped**:

1. Real Health sheet and real location alert appear automatically in sequence after the review; accepting enters Today.
2. Denying location completes onboarding; revisiting offers Settings, returning works, and Continue completes.
3. Backgrounding and returning during the Health sheet works; a subsequent visit respects existing consent and both Continue actions work.
4. Connecting Health reads scalar signals without saving or creating a Workout.

The initial new denial-test selector used an ASCII apostrophe where iOS exposed “Don’t Allow”; corrected the selector and added app termination around permission resets to isolate system alerts. The subsequent denial completion failure was retained and addressed in production code, not by loosening its assertion. Earlier failed result bundles remain under `/tmp/momentum-permissions-fixed.xcresult` and `/tmp/momentum-permissions-retest.xcresult`.

Manual walkthrough simulator: **Momentum 1.9.0 — Fresh Onboarding**, `267C2B26-8CC4-425F-B939-2BF2C419765F`. This is a new device with untouched permission choices, opened at welcome with the updated simulator binary. Existing test devices and user data were not erased.

## Build 48 release verification

The release version is **1.9.0 (48)**, replacing build 47, which predates the permission fixes.

Added a fifth distinct check: declining both Health and location opens a responsive checkout in both normal-motion and Reduce Motion modes. The passing result is `/tmp/momentum-190-48-checkout.xcresult` (one test, zero failures or skips). Both screenshots were inspected; the checkout controls are visible and Restore is hittable after the native dialogs leave.

The other four checks also passed against the build-48 simulator binary in `/tmp/momentum-190-48-final-permissions.xcresult`. That entire bundle is **not** a green run: the new fifth test originally targeted Apple's Health confirmation through the wrong application process. iOS presents an additional “Health Access” / “OK” dialog after “Don't Allow”; the test now completes that dialog through Momentum's window before checking the next page. This was a test-harness correction, with no production assertion loosened and no additional production code change. Both earlier failed build-48 result bundles are retained.

Five distinct focused checks now have passing evidence. No full-suite, physical-device frame-rate, or App Store validation claim is made here.
