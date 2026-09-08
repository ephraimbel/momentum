# Community reliability recheck — 2026-09-08

This follows the route realism audit and Community polish pass. It tests a broader set of interactions; it is not a claim that every production device/network/account combination is perfect.

## Additional fixes

- Scroll pauses now belong to the actual ScrollView/List and release when that surface disappears or the app leaves the foreground. Previously the route browser cleared its pause only when its enclosing sheet disappeared: removing the results List could leave the snapshot queue paused.
- Saved-route detail removal now handles persistence failures, restores the previous state and keeps the route visible with a retry message. Its close/bookmark targets are 44 points. Collection creation is disabled for blank names.
- Both user-data deletion paths now delete saved posts/routes too. Regression tests insert saved routes and assert that deletion removes them while preserving the exercise catalog.
- Malformed saved coordinates reject the whole map rather than crash or join valid fragments into an invented shortcut. Adjacent duplicates are removed; fewer than two distinct points do not expose an unusable map action. This changes computed accessors, not the SwiftData schema.
- Community controls, tiles and pager use the app's shared Reduce Motion reader, which honors the system setting and supports the existing DEBUG verification flag.
- A route browser with no route posts explains the empty wall and disables inapplicable filters. A filtered search with no matches still offers Clear filters.

## Verification

- **218 unit tests passed**, zero failures/skips: all Community suites, data management, feed assembly, earned context, comments, moderation, follows, privacy, reactions, social interactions, activity inbox and sync-engine tests.
- **22 broader UI tests passed**, zero failures/skips: Community browsing and lifecycle, saved routes/collections, search, follow/list consistency, blocking, comment persistence, photo lightboxes, media switching and welcome handoffs.
- The added fast-scroll/background-return test exercises the reduced-motion branch and verifies the route browser remains operable. Saved-detail removal and blank collection-name checks passed. The initial largest-text test also passed reachability, but screenshot review revealed truncated filter labels; the browser now stacks its filters at accessibility sizes and uses a shorter scope explanation. The rebuilt largest-text test and normal dark-mode browser test both passed (two executed cases, zero failures/skips), and the corrected screenshot was visually reviewed. That makes **23 distinct UI cases passed**, with focused repeats after the layout correction. See [large-text result](audits/community-recheck-2026-09-08/route-browser-large-text-fixed.png).
- Scope checks: no route dataset or athlete identity changes; no schema migration; no reset of the shared working tree. Builds use the isolated `/tmp/momentum-community-work` copy, generated with XcodeGen. Results live in `/tmp/momentum-community-final-audit`.

## What remains unverified

The paired iPhone 15 Pro still required its passcode when checked. These simulator results do not establish a physical-device FPS, hitch rate or thermal/memory behavior over a long real-world session.

The isolated interaction build has its Supabase URL and key disabled (confirmed in its built Info.plist), while retaining Mapbox. Comment/follow tests therefore cannot write to real users. Local persistence and the sync-engine tests are covered; signed-in interactions between two real backend accounts are not verified by this run. Production configuration is unchanged.

The wider app's Plan work is separate. This run does not replace a whole-app release test or the backend's RLS/integration checks. The previous water audit's sampling limits still apply.

Result summaries are preserved in `docs/audits/community-recheck-2026-09-08/`. Builds used build-for-testing followed by test-without-building; result-bundle counts confirmed every selected run executed tests. Scoped `git diff --check` passed. The 12 affected source/test files matched the isolated validation copy at the final comparison.

## Follow-up: network ordering and image recovery

The next pass found four additional failure modes in the remote Community path:

- Reaction and follow writes could overlap for the same post/person. The first response could clear the newer tap's pending flag, and the server could receive the writes out of order. Each identity now has one writer, which drains the latest persisted intent after its current request completes. The UI still changes immediately. Sample follows no longer attempt an unnecessary server lookup.
- A delayed feed or follow response could restore a choice made while it was loading. Remote publication checks request ownership/cancellation before merging reaction state, and local intent revisions protect taps made during the request. Cancelled athlete/profile materialization also discards its result.
- Duplicate IDs within one remote page could produce duplicate SwiftUI identities, even though pagination removed IDs already on the wall. Materialization now keeps the first occurrence in server order, and signs each distinct photo path once. Pages without photos skip signing.
- The image cache accepted non-image error bodies and registered in-flight ownership only after its disk lookup. It now coalesces the entire read/download/write operation, rejects unsuccessful HTTP responses and invalid image metadata, and removes invalid legacy cache entries so the next valid fetch can recover. Disk pruning remains batched on writes, not cache hits.

New regression cases cover delayed reaction/follow acknowledgements with rapid retaps, stale and cancelled image requests, a local un-react during image loading, a local unfollow during a graph pull, duplicate rows across pages, 24 concurrent requests sharing one image download, and recovery from invalid response/cache bytes. The rebuilt unit run passed **227 tests in 23 suites**, with zero failures or skips, including all nine new cases. The concurrency fixture verified 24 requests returned the same image with exactly one download, and reopening the cache reused the disk entry without a second fetch. The seven changed source/test files were byte-compared with the isolated build. This remains a simulator/stub-backend verification, not a claim of live account-to-account delivery.


Follow-up evidence: `docs/audits/community-network-2026-09-08/`; full local logs and result bundles: `/tmp/momentum-community-network-audit/`. The isolated app's built Info.plist was rechecked: both Supabase configuration values remain empty, so interaction tests cannot write to production. The iPhone was checked again and still required its passcode.

The rebuilt follow-up UI smoke run passed **3 tests**, zero failures/skips: follow count/list consistency, blocking plus unfollow persistence across relaunch, and full-screen photo opening. Both the unit and UI schemes used build-for-testing followed by test-without-building; result-bundle summaries confirmed the selected tests actually executed. Scoped whitespace checks passed.
