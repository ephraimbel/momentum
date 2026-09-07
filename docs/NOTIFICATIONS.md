# Notifications

> The notification system as shipped in the 2026-09-06 pass. PRD §24 is the original spec; this
> page is authoritative where they differ. Every number here is pinned by
> `MomentumTests/NotificationPlannerTests.swift` and `NotificationRouteTests.swift`.

## Principles

1. **A notification opens what it is about.** Every one carries a `NotificationRoute`, and every
   route resolves through one mailbox (`AppRouter.pendingNotificationRoute`) that `RootView`
   consumes. A push, the in-app toast and a bell inbox row for the same event all land in the
   same place. Opening the app and leaving the athlete on Today is a bug.
2. **The plan is the source of every schedule.** `NotificationPlanner` decides the whole plan
   schedule in one pure pass; `NotificationService.schedulePlannedReminders` replaces every
   `momentum.plan.` request with the result. A moved, eased, completed or deleted session can never
   leave a stale line behind, because the next resync (Today's bootstrap, a save, a Settings
   change, onboarding, Life happens) rewrites all of it.
3. **Never annoying.** One reminder per training day. One catch-up per absence. One win-back per
   absence. One coaching push per day. Quiet families carry no sound. A logged workout withdraws
   the day's nudges on the spot.
4. **No shame, no dashes.** Missed sessions "move forward, nothing is lost". Copy is plain
   sentences with no dash marks of any kind; `NotificationCopy.clean` scrubs assembled text and the
   tests assert `isClean` over every producer.

## Families

| Family | When | Sound | Opens | Toggle |
| --- | --- | --- | --- | --- |
| Session reminder | Each training day at the learned or custom time, 7 days ahead. A run and a lift on one day share one line. | yes | That session's sheet on the Plan board | Session reminders |
| Catch-up | The morning after the next session, only if that morning has no reminder of its own. At most one per resync. Withdrawn when the session is logged. | no | Plan board (the moved session carries its rationale) | Session reminders |
| Win-back | Ten days out, replaced on every resync, so it fires only after ten days away. | no | Plan board | Session reminders |
| Race eve / race morning | 19:00 the day before and 06:00 on the day, from the plan's own race sessions (goal race and tune-ups). | eve yes, morning no | The race session | Session reminders |
| Weekly review | The coming Sunday 18:00. The body previews the seven days ahead from the plan ("Next week: 4 runs, 38 km, and 2 lifts. Long run Saturday."). | yes | Progress · Trends | Week in review |
| Streak | 18:30 on a planned day with a real streak (3+) at risk and nothing logged. | yes | Today | Streak check-ins |
| First run | 17:30 on a day whose plan holds an undone run, only until the first workout exists. | yes | Today | Session reminders |
| Coaching | A `CoachingEvent` recorded while backgrounded, one per day (`CoachPushBudget`). Foreground shows the toast instead. | yes | Ease/recover: Progress · Health. Recalibrate: Plan. Moved: the moved session. | Coaching updates |
| Morning readiness | BGAppRefresh around 06:30. | no | Progress · Health | Morning readiness |
| Trial ending | Two days before a trial bills. | yes | Settings | none (a purchase promise) |
| Rest timer | When a rest ends while backgrounded. | yes | The live session (an overlay, so opening the app is landing on it) | none |
| Siri meal receipt | After a "log a meal" intent. Carries an Undo action. | yes | Fuel | none |
| Refuel cue | 25 minutes after a long run, a race, a quality or hard-rated cardio session (30 min+), an hour of any cardio, a lift of 40 min+ or 12+ working sets, or a 90 min+ walk (`PostWorkoutFuelCue`). Never an amount, never a food. Withdrawn the moment any meal is logged. Also mirrored to the inbox and said once as a toast after the save receipt. | yes | Fuel | Refuel reminders |

Worst case on a training day: one reminder plus the evening streak line, plus a coaching push if
a decision was made in the background. A rest day is silent unless a catch-up is owed.

## Fuel integration

Fuel is wired to the workout, not the other way round. A saved session runs through
`WorkoutCompletion.adapt`, which asks `PostWorkoutFuelCue` whether it was exerting (a planned long
run or race; a quality or hard-rated cardio session of 30 min or more; an hour of any cardio; a lift
of 40 min or 12 working sets; a walk of 90 min). If so, one refuel cue is scheduled 25 minutes after
the finish, mirrored into the inbox, and said once as a toast after the save receipt, and every one
of those opens Fuel. The words are deliberately unspecific: carbs and protein in the next hour, and
"what and how much is your call". No grams, no calories, no foods; that is the athlete's and their
goals' business (fueling, not dieting). Logging any meal, from Fuel or from Siri, withdraws the cue.
A workout logged long after it ended (90 minutes or more) earns none: there is no window left to
talk about. The planned-session sheet keeps its existing before/during/after guidance from
`FuelingGuide`.

Every save path reaches the cue: the live finish and crash recovery (`WorkoutCompletion.adapt`),
and both hand-logged paths (`LogWorkoutView`, `LogActivityView`). The Fuel page's own refuel
banner uses the SAME law (`FuelReadiness.WorkoutInput.exerting`, fed by `FuelReadoutBuilder`),
so a tap on "Refuel after that run" lands on a page whose banner says "Refuel after that run.
What and how much is your call." The onboarding permission beat names the refuel nudge in its
promise. Verification hooks: `--seed-refuel` seeds a 75 minute run that ended eight minutes ago
(Fuel opens with the window); `--refuel-fire` schedules the cue through the production path with
the lead cut to seconds, and `testARefuelCueFiresThroughTheProductionPathAndOpensFuel` taps the
real banner and asserts the landing.

## Grouping and ordering

`threadIdentifier` groups the lock screen by family thread: the plan's own lines (`momentum.plan`),
the coach's (`momentum.coach`), account, rest, fuel. `relevanceScore` orders a Notification Summary:
race day 1.0, coaching 0.9, first run 0.9, session 0.8, readiness 0.7, streak 0.7, catch-up 0.6,
weekly 0.5, win-back 0.4.

## Routing

`NotificationRoute` (string-coded, survives `userInfo` and UserDefaults, unknown strings decode to
nil):

- `today`, `plan`, `plan.week:<epoch>`, `plan.session:<uuid>`, `progress:<Segment>`, `coach`,
  `fuel`, `settings`.
- `NotificationService` (the `UNUserNotificationCenterDelegate`) decodes the tapped notification's
  route, logs `notification_opened(family, routed)`, and writes `router.pendingNotificationRoute`.
- `RootView.follow` switches the tab and fills the per-tab mailboxes: `pendingPlanSessionID` /
  `pendingPlanWeek` (`PlanView` lands on the week and opens the sheet), `pendingProgressSegment`
  (`ProgressScreen`), `pendingSettings` (`ProfileScreen` pushes Settings). The coach opens as a
  cover after a beat. A route is dropped while a workout is live or before a profile exists.
- The bell inbox keeps a route per row in `NotificationRouteStore` (UserDefaults, id-keyed, capped
  at 300) because `AppNotification` is a released schema. Rows without one fall back to their
  kind's door.
- The toast capsule carries `.deepLink(route)` and writes the same mailbox on tap.

## Permission

The system prompt is asked at onboarding's reminders beat and never repeated. Settings →
Notifications shows an honest "off in iOS Settings" row with a Turn on button when the athlete
said no there (`NotificationPermissionRow`). Scheduling while unauthorized is harmless.

## Verification

- Unit: `NotificationPlannerTests`, `NotificationRouteTests` (route, store, copy),
  `StreakNudgeTests`, `NotificationPrefsTests`, the reminder contract in `PlanCoachingTests`.
- UI: `NotificationRoutingUITests` drives `--notify-open=<route>`, which goes through
  `NotificationService.open` exactly as a tap does, and asserts the session sheet, the Health
  segment, Settings, and Fuel each appear. `testATappedBannerRoutesThroughTheDelegate` is the
  end-to-end proof: `--notify-authorize --notify-fire=<route>` asks permission, fires a real local
  notification, the test backgrounds the app, taps the banner on SpringBoard, and asserts the
  landing. It needs a fresh install (`simctl uninstall`) because iOS asks once per install.
- The two banner tests schedule their notification on the app's first backgrounding (the debug
  hooks arm `debugBackgroundFire`), so they can wait for the permission alert at their own pace,
  press Home, and read the banner on SpringBoard whether or not permission was already granted.
- Verified 2026-09-06: 7/7 routing UI tests (two real banner taps, the refuel cue through the
  production path, the Fuel window) twice in a row, and 2068/2068 unit tests, on a dedicated
  iPhone 17 Pro simulator.
