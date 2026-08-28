# Build-in-public clips

`scripts/make_clip.py` turns one shot recipe into one X-ready vertical `.mp4`: a real
Simulator screen recording, composited into the same titanium iPhone the website uses,
sitting on the app's own warm-charcoal ground (`#1E1D1B`).

Output is **1080×1920, H.264 High, 60fps, with a silent AAC track** — X's preferred
vertical shape, and the largest 9:16 it never re-scales on the way in. The silent audio
track is deliberate: X handles a video with no audio stream inconsistently.

```
scripts/make_clip.py --list                  # what recipes exist
scripts/make_clip.py live-run                # record + compose one
scripts/make_clip.py --all --build           # build, install, then every recipe
scripts/make_clip.py live-run --recompose    # re-cut the last take, no re-record
scripts/make_clip.py community --raw-only    # record only, judge it, then --recompose
scripts/make_clip.py save-screen --sheet     # also write a contact sheet next to the clip
```

Clips land in `build/clips/momentum-<recipe>.mp4`. Raw takes stay in `build/clips/raw/`
so `--recompose` can re-cut them for free; plates are cached in `build/clips/plates/`.

Requires `ffmpeg` + `ffprobe` (`brew install ffmpeg`) and Python with Pillow + numpy.
The script exits with a clear message if ffmpeg is missing.

## The loop that actually works

Recording is the slow part and trimming is the part you get wrong, so split them:

1. `scripts/make_clip.py <recipe> --raw-only` — one long take, 20-40s.
2. Look at `build/clips/raw/<recipe>.mp4` and pick your in and out points.
3. Set `trim_start` / `duration` in the recipe.
4. `scripts/make_clip.py <recipe> --recompose --sheet` and **look at the sheet**.

Never ship a clip you have not looked at. `--sheet` writes `sheet-<recipe>.png`, a 5×3
tile of stills — it is there so "it looks good" is a thing you can check.

## Adding a recipe

Recipes are `scripts/clip_recipes.json`, keyed by name:

| key | meaning |
| --- | --- |
| `title` | one line, shown by `--list` |
| `args` | DEBUG launch args for the take (required) |
| `record` | seconds to record, launch to cut (required) |
| `appearance` | `light` or `dark` — the simulator's system appearance |
| `prewarm` | warm the app once before the take (default `true`) |
| `prewarm_args` | args for the warm-up when the take's own args have side effects |
| `prewarm_wait` | seconds to leave the warm-up running (default 10) |
| `pre` | shell commands run before the take, app dead (`$UDID`, `$BUNDLE_ID`) |
| `interact` | `[{"at": 6.0, "run": "…"}]` — scripted shell during the take |
| `trim_start` / `duration` / `trim_end` | the cut, in raw-take seconds |
| `push` | slow zoom on the finished canvas, e.g. `0.05` (5%) |
| `phone_height` / `phone_y_bias` | phone size and vertical placement on the canvas |

The launch args come from the app itself. `grep -rn "arguments.contains" --include="*.swift" .`
lists every one. Prefer a launch arg over anything that needs a tap.

## Gotchas, in the order they will bite you

**Never record under XCUITest.** XCUITest fast-forwards animations, so any motion captured
under it is a lie. This pipeline is a plain `simctl launch` plus `simctl io recordVideo`,
which is why the run timer ticks at one second per second.

**You cannot tap.** `simctl` has no touch injection, and driving the Simulator window with
cliclick/AppleScript is the flakiest thing in this repo. Every shot here is staged by a
DEBUG launch arg. If a shot needs a tap you cannot stage, it needs a new `#if DEBUG` arg in
the app, not a synthetic click.

**Mapbox needs a warm tile cache or the map records as a black rectangle.** On a container
that has never rendered a map, the first style + tile fetch takes ~45s, and a 20s prewarm is
not enough — the first live-run take came out with a pure black map page. `prewarm_wait` on
the map-heavy recipes is 35-40s for this reason. The tile store lives in the app's data
container, so it survives a `simctl terminate` but **not** a `simctl uninstall`. Reinstalling
means paying the cold cache again.

**"Unfinished run found" will sit on top of the next shot.** Every live-run take ends by
killing the app mid-recording, which leaves `momentum.activeWorkoutID` in UserDefaults, and
the next launch of *any* recipe opens behind a modal alert. `make_clip.py` now clears it
before every take (`CLEAR_RUN_MARKER`). Two traps in that one line:

- `xcrun simctl spawn <udid> defaults delete <bundle> <key>` does **not** work. The spawned
  tool cannot resolve a sandboxed app's domain by name; it reports "Domain not found" and
  changes nothing. Go at the plist inside `simctl get_app_container <udid> <bundle> data`.
- `plutil -remove momentum.activeWorkoutID` also does nothing — plutil reads `a.b` as a
  nested key path. The dot must be escaped: `plutil -remove 'momentum\.activeWorkoutID'`.

**The killed run also leaves a workout row.** A live-run take writes a ~0.03 mi stub run into
SwiftData, and anything that reads "the newest workout" then films it: the save screen showed
`0.03 mi`, and the share composer built a card around it. Every recipe passes `--reset-store`
ahead of `--seed-demo` so each take starts from the same seeded store. Don't drop it.

**Permission dialogs.** `stage_device` pre-grants location, motion, photos and microphone
before anything launches. A SpringBoard alert sits above the app and ruins the take silently.

**`--ui-test-social` is for tests, not for film.** It short-circuits the Mapbox route
snapshots so XCUITest isn't starved, which leaves the community wall as grey silhouettes.
The community recipes deliberately do not pass it.

**`simctl recordVideo` only writes frames when the screen changes.** A still screen produces
no frames, so a 28s record of a static page can land as a 13s file — that is the take, just
without the dead air. It also means a static shot has no motion of its own, which is what
`push` is for. The container's timestamps are also not strictly monotonic (there is a
negative-pts segment near the head of every take); ffmpeg's `-ss` handles it, but a
hand-rolled frame-time `select` filter will pick nonsense frames. Trim with `-ss`, judge with
`--sheet`.

**Which screens move on their own.** Live run (the timer, the drawing route, the scripted
page flip) and the save screen (the count-up hero) carry themselves. The community wall, an
athlete's profile and the share composer settle within a second or two and then hold — those
recipes stay short and carry a 4-5% `push`. Never put a `push` on a shot that already moves.

**Always pass an explicit UDID.** `booted` resolves arbitrarily when more than one simulator
is up, and other sessions share this checkout. Default is the iPhone 17 Pro
`EC8B432A-B25A-4771-BFB9-4C65BEB3DDBF`; override with `--udid` or `CLIP_UDID`.

**Dark appearance needs its OWN Mapbox warm.** The light basemap and the dark/night preset are
different styles with separate caches, so warming Today in light does nothing for a `dark` recipe.
A container warmed only in light films `today-deck`/`live-run`/`strength-live` as black rectangles.
Warm both: `simctl ui <udid> appearance dark`, launch, wait ~90s, then record.

**Never film on a simulator another session is using.** `simctl` has no per-session ownership: a
parallel Claude session running `simctl terminate` + `launch` on the same UDID kills your app
mid-take, and its launch lands in your footage. The symptom is a take that cuts to SpringBoard and
then to a screen your recipe never asked for. Create a dedicated device
(`simctl create momentum-clips …`) and pass `--udid`. This cuts both ways, your takes corrupt
their screenshots too.

**`--build` costs you the tile cache AND the tuned trims.** Installing replaces the data container,
so Mapbox goes cold and every first launch is slow enough that `trim_start` lands in the splash.
After a `--build`, warm the maps and re-judge the trims before believing a take.

**A shot that needs a tap only films its first beat.** `--award-unlock` queues three medallions but
advances on "Tap for the next one", so the clip is one medallion holding still. Keep tap-gated
recipes short and give them a `push`.

**Clips are big and the disk is not.** A 14-recipe pass writes ~30 MB of raw per take. A full disk
surfaces as `ffmpeg compose failed / No space left on device` after several clips have already
succeeded, so check `df -h` before a long batch.

## The chassis

`scripts/clipkit/frame.py` renders two cached plates — a backdrop and an RGBA chassis
overlay — from the website's `.phone` CSS at its 336px reference width, so the video and
momentumco.app show the product in the same phone. The recording is overlaid *under* the
chassis and the bezel masks the screen's corners for free.

One correction lives at the end of `render_frame`: the recording is overlaid as a plain
rectangle, and a rounded screen inset by a uniform pad has square bounding-box corners that
poke outside the phone's own outline. That showed as four small white tabs at the screen
corners. The guard paints those slivers back to exactly what the backdrop has under them.
