# Sentry setup — free, error-only, privacy locked

Momentum uses Sentry only for crash, hang, watchdog and a few static operational-error events.
Supabase remains the product/conversion analytics source of truth. MetricKit remains the native
aggregate quality monitor.

## Free-plan guardrails

- Choose **Developer — $0**. Do not add a card, Team trial, pay-as-you-go budget or Seer.
- The app sends errors and release-health sessions only.
- Tracing, profiling, logs, Session Replay, screenshots, view hierarchy, automatic UI/network
  breadcrumbs, failed-request capture and raw MetricKit payloads are disabled in code.
- Production records 100% of errors until Sentry's included quota is reached; the free plan then
  drops over-quota events rather than becoming a paid integration.

## Create and connect the project

1. Sign in at https://sentry.io and remain on the **Developer — $0** plan.
2. Create an Apple/iOS project named `momentum-ios`.
3. Copy its **DSN** (not an auth token).
4. In the untracked `Secrets.xcconfig`, add the DSN using xcconfig-safe URL syntax:

   `SENTRY_DSN = https:/$()/PUBLIC_KEY@o123.ingest.us.sentry.io/456`

5. Run `xcodegen generate` and make a Release/TestFlight build. Release builds enable Sentry when
   the DSN is valid. Debug builds remain dark unless launched with `--enable-sentry`.

## Debug symbols

- `scripts/upload_sentry_dsyms.sh` runs only for Release builds and uploads the archive's dSYMs to
  organization `momentum-l6`, project `momentum-ios`.
- It uses the official `sentry-cli` and the `org:ci`-only token in the ignored
  `Secrets.xcconfig` (`SENTRY_AUTH_TOKEN`). The token is never copied into Info.plist or the app.
- Source context is intentionally not uploaded. The script uploads symbols only.
- Sentry requires Release script sandboxing off so its scanner can read the complete dSYM bundle;
  Debug and every other target keep `ENABLE_USER_SCRIPT_SANDBOXING = YES`.
- Missing CLI/token or a network failure emits a build warning. Preserve the `.xcarchive` so its
  dSYMs can be uploaded manually if needed.

## Dashboard privacy settings

Before production traffic, open **Project Settings → Security & Privacy** and enable:

- Prevent storing IP addresses
- Default data scrubbing
- Enhanced privacy controls

Do not enable Replay, profiling, logs, request-body capture or user feedback attachments.

## Verification

1. Launch a Debug build with `--enable-sentry`; confirm a normal launch still works.
2. Capture a temporary static test message or trigger Sentry's sample error, then remove the test.
3. Test a crash without the debugger attached and relaunch so the cached crash uploads.
4. Confirm the event contains release/build/device/OS and only `app.event` breadcrumbs—no athlete
   name, email, HealthKit value, meal, route coordinate, workout payload, screenshot or view tree.
5. Confirm crash symbols resolve before App Store release. dSYM upload credentials are build-time
   secrets and must never be placed in the app or committed.

## Monthly check

In **Settings → Subscription**, verify the organization still says **Developer — $0** and has no
pay-as-you-go budget. Review error usage; 5,000 errors/month is the current free allowance.
