# Community polish — 2026-09-08

Latest broader recheck: [COMMUNITY-RELIABILITY-RECHECK.md](COMMUNITY-RELIABILITY-RECHECK.md).

Follow-up to `COMMUNITY-REALISM-AUDIT.md`. The route dataset and identity/follow contracts remain those audited there. This pass implements the approved interaction and discovery improvements; the globe remains separate.

## Changes

- The compact **Find people** header now ships for an empty follow list. Accounts with follows keep their people strip.
- Full-screen posts immediately reuse an available wall map while their detailed snapshot or interactive map loads. Full-size requests still run; thumbnail availability does not prevent the upgrade. View-local snapshots are keyed to the post, appearance, size and interactive state.
- Scrolling pauses new ordinary snapshot engines. Existing images and active renders continue; opened posts receive priority. A set of scrolling owners avoids one surface accidentally unpausing another. Tapping a post also promotes an already queued prefetch for that same map.
- Standalone controls use a restrained 0.985 press scale and opacity feedback. Reduce Motion suppresses scale; mosaic tiles retain their dim-only press to avoid gaps. Existing post transitions, reaction feedback and scroll restoration remain in place.
- **Browse routes** filters available wall posts by displayed distance and location. Metric and imperial ranges have explicit, nonoverlapping boundaries. The location selector uses available metros, falling back to a post's location; it does not claim GPS-based proximity. Results open the original post and retain example disclosure.
- **Saved collections** organize bookmarked posts without changing the shipped SwiftData model. Collection membership persists in profile-scoped UserDefaults on this device. A route can belong to multiple collections; deleting a collection preserves its saved posts. Removing a saved post prunes membership. Account/data wipes clear this metadata. Collections do not sync across devices.
- Cardio, strength and timed save screens place the existing audience control beside the optional caption. Photo/note prompts remain optional, and existing visibility defaults are preserved.
- Bookmark success feedback follows a successful SwiftData save. Fetch/save failures restore the previous state and show a retry message. Saved-list removals also handle save failures.

## Verification

Validation uses `/tmp/momentum-community-work` and the explicit simulator `A48F1439-691B-4437-A020-F2FB20E2DB40`, with artifacts under `/tmp/momentum-community-polish`. XcodeGen generates the isolated project. Each test run uses build-for-testing followed by test-without-building, with result-bundle counts checked to rule out a zero-test green.

- Final targeted unit run: **104 tests passed** (105 executions including a parameterized case), zero failures/skips. This includes 99 Community tests and five data-management tests.
- Initial UI run: **eight tests passed**, zero failures/skips: live maps/deep browsing, compact header, route filtering/post opening, collection relaunch/deletion, handle lookup and three welcome handoff checks.
- Final rebuilt UI follow-up: **five Community UI tests passed**, zero failures/skips. It includes the promoted queue behavior during live browsing, a visible/tappable compact-header assertion, dark-mode distance/location filters and post opening, saved-collection persistence/deletion, and handle identity navigation. The correct suite identifier selected five tests, not zero.
- Reviewed final screenshots: [header](audits/community-polish-2026-09-08/header.png), [dark route browser](audits/community-polish-2026-09-08/route-browser-dark.png), [saved collection](audits/community-polish-2026-09-08/saved-collection.png). The route browser's small placeholders show the route silhouette without crowding it with repeated loading text; the main wall retains map-loading status. Saved subtitles wrap to preserve author/location context.
- Machine-readable result summaries are saved beside those screenshots. Final UI verification includes the final visual-only refinements made after the unit run.
- `git diff --check` passed for the scoped changes. The whole app test suite was not rerun in this polish pass; the earlier audit reports its separate Plan failures and snapshot date. These targeted greens are not a release-wide certification.

## Limits

Filtering covers posts already assembled for the current wall, not a global route search service. Collections are local organization, not a cloud backup. Cached previews improve perceived loading when present; a completely cold Mapbox/network cache still needs to load. No new athlete photos or generated faces were added, and existing display names/handles were preserved.

The paired iPhone 15 Pro was reachable but required its passcode during this pass. Physical-device profiling requires it to be unlocked; simulator checks do not establish a device FPS or hitch-rate guarantee. No production app was replaced or user workout posted during verification.

## Re-running the isolated validation

Both schemes use the app sources from the isolated copy. `CommunityValidation` includes the Community test files plus `DataManagementTests.swift`; `CommunityVisualValidation` includes `CommunityRealismUITests.swift` and `WelcomeSmoothnessUITests.swift`.

```sh
xcodegen generate --spec /tmp/momentum-community-work/project.yml
xcodebuild build-for-testing \
  -project /tmp/momentum-community-work/Momentum.xcodeproj \
  -scheme CommunityValidation \
  -destination 'platform=iOS Simulator,id=A48F1439-691B-4437-A020-F2FB20E2DB40' \
  -derivedDataPath /tmp/momentum-community-derived \
  -clonedSourcePackagesDirPath /Users/ephraimbelachew/Library/Developer/Xcode/DerivedData/Momentum-almqrkgljnlezkfmtbmqcivzvfxq/SourcePackages \
  -disableAutomaticPackageResolution
```

Then use the same command with `test-without-building` and a fresh `-resultBundlePath`. Repeat build-for-testing/test-without-building with `CommunityVisualValidation` for all eight UI cases. The final targeted UI repeat used `-only-testing:MomentumCommunityVisualTests/CommunityRealismUITests`, and the result bundle confirmed five executed cases.
