#!/usr/bin/env python3
"""make_clip.py -- build-in-public clips of Momentum, straight off the Simulator.

One shot recipe in, one X-ready vertical .mp4 out: recorded from a DEBUG
deep-link launch, composited into the same titanium iPhone the website uses,
on the app's own warm-charcoal ground.

    scripts/make_clip.py --list
    scripts/make_clip.py live-run
    scripts/make_clip.py --all
    scripts/make_clip.py live-run --recompose        # retrim, no re-record

Recipes live in scripts/clip_recipes.json. See scripts/README-clips.md for how
to add one and for the gotchas this pipeline exists to route around.

Why a deep-link launch and not XCUITest: XCUITest fast-forwards animations, so
motion recorded under it is a lie. Everything here is a real, un-accelerated
launch driven by DEBUG launch args the app already ships.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "clipkit"))
from frame import build_plates  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RECIPES = Path(__file__).resolve().parent / "clip_recipes.json"

BUNDLE_ID = "com.ephraimbel.momentum.app"
SCHEME = "Momentum"

# iPhone 17 Pro. Any device works, but the plate cache keys on the capture size,
# so mixing devices in one batch just means two sets of plates.
DEFAULT_UDID = "EC8B432A-B25A-4771-BFB9-4C65BEB3DDBF"

# X (Twitter) takes vertical video happily at 9:16. Its own guidance caps
# frame rate at 60fps and prefers H.264 High + AAC in an MP4; 1080x1920 is the
# largest 9:16 that never gets downscaled on the way in.
CANVAS_W, CANVAS_H = 1080, 1920
FADE = 0.35
BACKDROP_HEX = "0x1E1D1B"

PRIVACY = ["location-always", "location", "motion", "photos", "photos-add", "microphone"]

# Every live-run take ends by killing the app mid-recording, which leaves
# `momentum.activeWorkoutID` set -- and the NEXT launch, of any recipe, opens
# behind an "Unfinished run found" alert that sits on top of the shot for its
# whole duration. Clear it before every take, with the app dead.
#
# `xcrun simctl spawn <udid> defaults delete <bundle> <key>` does NOT work: the
# spawned tool can't resolve an app's sandboxed domain by name. Go at the plist
# in the data container instead, and escape the dot -- plutil reads `a.b` as a
# nested key path, so an unescaped key silently removes nothing.
CLEAR_RUN_MARKER = (
    'P="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)'
    '/Library/Preferences/$BUNDLE_ID.plist"; '
    "plutil -remove 'momentum\\.activeWorkoutID' \"$P\" >/dev/null 2>&1; true"
)


# ---------------------------------------------------------------------------
# shell helpers
# ---------------------------------------------------------------------------


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def need(tool: str) -> str:
    path = shutil.which(tool)
    if not path:
        sys.exit(
            f"error: `{tool}` not found on PATH.\n"
            f"       ffmpeg/ffprobe come from `brew install ffmpeg`."
        )
    return path


def booted(udid: str) -> bool:
    out = run(["xcrun", "simctl", "list", "devices", "booted"]).stdout
    return udid in out


# ---------------------------------------------------------------------------
# simulator staging
# ---------------------------------------------------------------------------


def stage_device(udid: str, appearance: str) -> None:
    """Put the device in a photogenic, deterministic state before any capture."""
    if not booted(udid):
        print(f"  booting {udid} ...")
        run(["xcrun", "simctl", "boot", udid])
        time.sleep(8)

    # A clean status bar: 9:41, full bars, charged, no carrier name.
    run(
        [
            "xcrun", "simctl", "status_bar", udid, "override",
            "--time", "9:41",
            "--batteryState", "charged", "--batteryLevel", "100",
            "--cellularMode", "active", "--cellularBars", "4",
            "--wifiMode", "active", "--wifiBars", "3",
            "--operatorName", "",
        ]
    )
    run(["xcrun", "simctl", "ui", udid, "appearance", appearance])

    # Pre-grant everything the app asks for. A SpringBoard permission alert sits
    # ON TOP of the app and silently ruins an otherwise perfect take.
    for svc in PRIVACY:
        run(["xcrun", "simctl", "privacy", udid, "grant", svc, BUNDLE_ID])


def install_app(udid: str, derived: Path) -> None:
    app = derived / "Build/Products/Debug-iphonesimulator/Momentum.app"
    if not app.exists():
        sys.exit(f"error: no built app at {app}\n       run with --build first.")
    print(f"  installing {app.name} ...")
    r = run(["xcrun", "simctl", "install", udid, str(app)])
    if r.returncode:
        sys.exit(f"error: install failed\n{r.stderr}")


def build_app(udid: str, derived: Path) -> None:
    print("  xcodebuild (Debug) ...")
    r = subprocess.run(
        [
            "xcodebuild", "-scheme", SCHEME,
            "-destination", f"id={udid}",
            "-configuration", "Debug",
            "-derivedDataPath", str(derived),
            "build",
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if r.returncode:
        tail = "\n".join(r.stdout.splitlines()[-40:])
        sys.exit(f"error: build failed\n{tail}\n{r.stderr[-2000:]}")


# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------


def record(udid: str, recipe: dict, raw: Path, log: Path) -> None:
    """Record the whole take, launch-to-cut. Trimming happens in compose()."""
    args = list(recipe["args"])
    record_s = float(recipe["record"])

    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID])
    time.sleep(1.0)

    # Cleanup, run with the app dead so a defaults write can't be clobbered by
    # the running process: the run-recovery marker (see CLEAR_RUN_MARKER) plus
    # whatever else this recipe asks for.
    def cleanup() -> None:
        for cmd in [CLEAR_RUN_MARKER, *recipe.get("pre", [])]:
            subprocess.run(cmd, shell=True, env={**os.environ, "UDID": udid, "BUNDLE_ID": BUNDLE_ID})

    cleanup()

    # A cold first launch pays for font registration, Mapbox style download and
    # SwiftData container setup on camera. Warm it, then kill.
    #
    # `prewarm_args` exists for the recipes whose own args have a side effect you
    # do not want twice: warming on `--live-run` arms a real recording, and the
    # kill that ends the warm-up leaves exactly the recovery marker above.
    if recipe.get("prewarm", True):
        print("  prewarm ...")
        warm = list(recipe.get("prewarm_args", args))
        run(["xcrun", "simctl", "launch", udid, BUNDLE_ID, *warm])
        time.sleep(float(recipe.get("prewarm_wait", 10)))
        run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID])
        time.sleep(2.0)
        cleanup()

    raw.parent.mkdir(parents=True, exist_ok=True)
    raw.unlink(missing_ok=True)

    print(f"  recording {record_s:.0f}s ...")
    with log.open("w") as lf:
        rec = subprocess.Popen(
            [
                "xcrun", "simctl", "io", udid, "recordVideo",
                "--codec=h264", "--mask=ignored", "--force", str(raw),
            ],
            stdout=lf,
            stderr=subprocess.STDOUT,
        )

    # simctl prints "Recording started" once the first frame lands. Waiting for
    # it is the difference between catching the launch and missing two seconds.
    deadline = time.time() + 25
    while time.time() < deadline:
        if log.exists() and "Recording started" in log.read_text(errors="ignore"):
            break
        time.sleep(0.15)
    else:
        rec.send_signal(signal.SIGINT)
        sys.exit("error: recordVideo never reported 'Recording started'.")

    run(["xcrun", "simctl", "launch", udid, BUNDLE_ID, *args])

    # Optional scripted interaction. Each step is {"at": seconds, "run": "shell"}.
    # Prefer a launch arg over a tap: taps are the flakiest thing in this pipeline.
    steps = sorted(recipe.get("interact", []), key=lambda s: s["at"])
    t0 = time.time()
    for step in steps:
        wait = step["at"] - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        subprocess.run(step["run"], shell=True, env={**os.environ, "UDID": udid})

    time.sleep(max(0.0, record_s - (time.time() - t0)))

    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=60)
    except subprocess.TimeoutExpired:
        rec.kill()
    # simctl flushes in-flight frames after SIGINT; give the file a moment to land.
    for _ in range(40):
        if raw.exists() and raw.stat().st_size > 0:
            break
        time.sleep(0.25)
    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID])


# ---------------------------------------------------------------------------
# compose
# ---------------------------------------------------------------------------


def probe(path: Path) -> tuple[int, int, float]:
    r = run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-show_entries", "format=duration",
            "-of", "json", str(path),
        ]
    )
    if r.returncode:
        sys.exit(f"error: ffprobe failed on {path}\n{r.stderr}")
    d = json.loads(r.stdout)
    st = d["streams"][0]
    return int(st["width"]), int(st["height"]), float(d["format"]["duration"])


def compose(recipe: dict, raw: Path, out: Path, plates_dir: Path, fps: int) -> None:
    src_w, src_h, src_dur = probe(raw)

    start = float(recipe.get("trim_start", 0.0))
    dur = float(recipe.get("duration", 0.0)) or (src_dur - start - float(recipe.get("trim_end", 0.0)))
    dur = max(0.5, min(dur, src_dur - start))

    backdrop, frame, g = build_plates(
        plates_dir,
        CANVAS_W, CANVAS_H, src_w, src_h,
        height_frac=float(recipe.get("phone_height", 0.885)),
        y_bias=float(recipe.get("phone_y_bias", 0.0)),
    )

    # `push`: a slow zoom on the finished canvas -- phone and ground together, as
    # if the camera crept in. Some screens are simply still (a profile, a wall of
    # cards) and a dead frame for eight seconds reads as a broken video; a 4-5%
    # creep gives it a pulse without pretending the app moved. Never put a push on
    # a shot that already moves.
    #
    # zoompan resamples, so feed it a 2x canvas and let it land back on 1080x1920:
    # that makes the move a DOWNsample and the type stays crisp.
    push = float(recipe.get("push", 0.0))
    frames = max(2, int(round(dur * fps)))
    move = (
        f"scale={CANVAS_W * 2}:{CANVAS_H * 2}:flags=lanczos,"
        f"zoompan=z='1+{push:.4f}*on/{frames - 1}':d=1:"
        f"x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s={CANVAS_W}x{CANVAS_H}:fps={fps},"
        if push > 0
        else ""
    )

    fade_out = max(0.0, dur - FADE)
    vf = (
        f"[1:v]fps={fps},scale={g.screen_w}:{g.screen_h}:flags=lanczos,setsar=1[scr];"
        f"[0:v][scr]overlay={g.screen_x}:{g.screen_y}[bg];"
        f"[bg][2:v]overlay=0:0[fr];"
        f"[fr]{move}fade=t=in:st=0:d={FADE}:c={BACKDROP_HEX},"
        f"fade=t=out:st={fade_out:.3f}:d={FADE}:c={BACKDROP_HEX},"
        f"format=yuv420p[v]"
    )

    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-loop", "1", "-framerate", str(fps), "-i", str(backdrop),
        "-ss", f"{start:.3f}", "-t", f"{dur:.3f}", "-i", str(raw),
        "-loop", "1", "-framerate", str(fps), "-i", str(frame),
        "-f", "lavfi", "-t", f"{dur:.3f}", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
        "-filter_complex", vf,
        "-map", "[v]", "-map", "3:a",
        "-c:v", "libx264", "-profile:v", "high", "-level", "4.2",
        "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k", "-ar", "44100",
        "-r", str(fps), "-t", f"{dur:.3f}",
        "-movflags", "+faststart",
        str(out),
    ]
    r = run(cmd)
    if r.returncode:
        sys.exit(f"error: ffmpeg compose failed\n{r.stderr[-3000:]}")

    w, h, d = probe(out)
    mb = out.stat().st_size / 1e6
    print(f"  -> {out}  {w}x{h}  {d:.1f}s  {mb:.1f} MB")


def contact_sheet(clip: Path, sheet: Path, cols: int = 5, rows: int = 3) -> None:
    """A tiled still strip so a take can actually be looked at, not assumed."""
    _, _, dur = probe(clip)
    n = cols * rows
    step = max(dur / (n + 1), 0.05)
    sel = "+".join(f"eq(n\\,{int(i * step * 30)})" for i in range(1, n + 1))
    r = run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(clip),
            "-vf", f"fps=30,select='{sel}',scale=250:-1,tile={cols}x{rows}",
            "-frames:v", "1", str(sheet),
        ]
    )
    if r.returncode:
        print(f"  (contact sheet skipped: {r.stderr.strip()[:200]})")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("recipe", nargs="*", help="recipe name(s) from clip_recipes.json")
    p.add_argument("--list", action="store_true", help="list recipes and exit")
    p.add_argument("--all", action="store_true", help="run every recipe")
    p.add_argument("--udid", default=os.environ.get("CLIP_UDID", DEFAULT_UDID))
    p.add_argument("--out", default=str(REPO / "build/clips"), help="output directory")
    p.add_argument("--fps", type=int, default=60, help="output frame rate (default 60)")
    p.add_argument("--build", action="store_true", help="xcodebuild + install before recording")
    p.add_argument("--install", action="store_true", help="install the existing build before recording")
    p.add_argument("--recompose", action="store_true", help="reuse the last raw take, just re-cut it")
    p.add_argument("--raw-only", action="store_true", help="record only, skip compositing")
    p.add_argument("--sheet", action="store_true", help="also write a contact sheet next to each clip")
    a = p.parse_args()

    recipes = json.loads(RECIPES.read_text())

    if a.list:
        width = max(len(k) for k in recipes)
        for name, r in recipes.items():
            print(f"  {name:<{width}}  {r.get('title', '')}")
        return

    names = list(recipes) if a.all else a.recipe
    if not names:
        p.error("give a recipe name, or --all, or --list")
    for n in names:
        if n not in recipes:
            sys.exit(f"error: unknown recipe '{n}'. try --list")

    need("ffmpeg")
    need("ffprobe")

    out_dir = Path(a.out)
    raw_dir = out_dir / "raw"
    plates = out_dir / "plates"
    derived = REPO / "build/DerivedData"

    if a.build:
        build_app(a.udid, derived)
    if a.build or a.install:
        stage_device(a.udid, "light")
        install_app(a.udid, derived)

    for name in names:
        r = recipes[name]
        print(f"\n[{name}] {r.get('title', '')}")
        raw = raw_dir / f"{name}.mp4"
        out = out_dir / f"momentum-{name}.mp4"

        if not a.recompose:
            stage_device(a.udid, r.get("appearance", "light"))
            record(a.udid, r, raw, raw_dir / f"{name}.log")
        elif not raw.exists():
            sys.exit(f"error: --recompose needs a previous take at {raw}")

        if a.raw_only:
            print(f"  -> raw {raw}")
            continue

        compose(r, raw, out, plates, a.fps)
        if a.sheet:
            contact_sheet(out, out_dir / f"sheet-{name}.png")

    print(f"\nclips in {out_dir}")


if __name__ == "__main__":
    main()
