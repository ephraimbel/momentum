#!/usr/bin/env python3
"""Where people drop off in momentum — one command, a readable answer.

    python3 scripts/analysis/dropoff.py            # the whole report
    python3 scripts/analysis/dropoff.py --days 14  # only the last 14 days of session shape
    python3 scripts/analysis/dropoff.py --screen plan   # everything about one screen
    python3 scripts/analysis/dropoff.py --check    # just say whether the pipeline is alive

WHY THIS FILE EXISTS AT ALL. The read side is where this has died twice. `funnel_dropoff.sql` was
written on 2026-08-22 to answer exactly this question and, as of today, has never been run: it needs
somebody to open the Supabase dashboard, find the SQL editor, and paste six blocks in. Nobody does
that on a Tuesday. So the queries live in a migration (20260907000001_screen_dropoff.sql) as views,
and this script reads them and prints the answer. If running it is one command, it gets run.

CREDENTIALS, in order: $SUPABASE_SERVICE_ROLE_KEY, then the authenticated Supabase CLI, then
the management API using an environment/keychain token as a fallback. The service role is required —
these views are deliberately revoked from anon and authenticated, because the anon key ships inside
the app binary.

Nothing here writes. It is a reader, top to bottom.
"""

import argparse
from datetime import datetime, timedelta, timezone
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROJECT_REF = "hhhlrqngutmyccfpgdoq"
BASE = f"https://{PROJECT_REF}.supabase.co"


# ── credentials ──────────────────────────────────────────────────────────────────────────────

def management_token():
    """The Supabase personal access token: env first, then the CLI's keychain entry."""
    import os
    if os.environ.get("SUPABASE_ACCESS_TOKEN"):
        return os.environ["SUPABASE_ACCESS_TOKEN"]
    out = subprocess.run(["security", "find-generic-password", "-s", "Supabase CLI", "-w"],
                         capture_output=True, text=True)
    token = out.stdout.strip()
    if not token:
        return None
    # The Go keyring the CLI uses base64s the value under this prefix.
    if token.startswith("go-keyring-base64:"):
        token = base64.b64decode(token[len("go-keyring-base64:"):]).decode().strip()
    return token


def service_key():
    import os
    if os.environ.get("SUPABASE_SERVICE_ROLE_KEY"):
        return os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    # Let the CLI use its own credential storage and HTTPS DNS resolver. Direct urllib access to
    # the management API can fail even while this authenticated CLI path works. Never print keys.
    try:
        result = subprocess.run(
            ["supabase", "projects", "api-keys", "--project-ref", PROJECT_REF,
             "--dns-resolver", "https", "--output", "json"],
            capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            keys = json.loads(result.stdout)
            key = next((k.get("api_key") for k in keys if k.get("name") == "service_role"), None)
            if key:
                return key
    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError, AttributeError):
        pass
    token = management_token()
    if not token:
        die("No credentials.\n"
            "  Either:  export SUPABASE_SERVICE_ROLE_KEY=<the service_role key from the dashboard>\n"
            "  Or:      supabase login     (then re-run; the token is read from the keychain)")
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{PROJECT_REF}/api-keys?reveal=true",
        headers={"Authorization": f"Bearer {token}"})
    try:
        keys = json.loads(urllib.request.urlopen(req, timeout=30).read())
    except urllib.error.HTTPError as e:
        die(f"Could not read the project's API keys ({e.code}). "
            "The CLI token may be expired or lack project access — refresh `supabase login`.")
    return next(k["api_key"] for k in keys if k["name"] == "service_role")


KEY = None


def die(msg):
    print(f"\n{msg}\n", file=sys.stderr)
    sys.exit(1)


def get(view, params=None):
    """Read all result pages; explicit limits (the health check) remain bounded."""
    ordering = {"app_journey": "cohort_day.desc", "screen_reach": "installs.desc,screen",
                "session_dropoff": "sessions.desc,last_screen", "screen_exit_rate": "session_exit_pct.desc,screen",
                "screen_paths": "screen,transitions.desc,next_screen", "churn_screen": "installs_last_seen_here.desc,last_screen",
                "session_shape": "day.desc"}
    query = {"order": ordering[view], **(params or {})}
    bounded = "limit" in query
    query.setdefault("limit", 1000)
    rows = []
    while True:
        query["offset"] = len(rows)
        url = f"{BASE}/rest/v1/{view}?" + urllib.parse.urlencode(query)
        req = urllib.request.Request(url, headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                page = json.loads(response.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode()[:300]
            if e.code in (404, 400) and ("PGRST205" in body or "does not exist" in body):
                return None
            die(f"{view}: HTTP {e.code}\n{body}")
        if not isinstance(page, list):
            die(f"{view}: expected a row array")
        rows.extend(page)
        if bounded or not page:
            return rows


# ── rendering ────────────────────────────────────────────────────────────────────────────────

def table(rows, cols, limit=None, indent="  "):
    """Fixed-width table. Columns are (key, header, align)."""
    if not rows:
        print(indent + "(no rows yet)")
        return
    rows = rows[:limit] if limit else rows
    widths = []
    for key, header, _ in cols:
        w = max(len(header), *(len(fmt(r.get(key))) for r in rows))
        widths.append(w)
    line = indent + "  ".join(h.ljust(w) if a == "l" else h.rjust(w)
                              for (_, h, a), w in zip(cols, widths))
    print(line)
    print(indent + "  ".join("-" * w for w in widths))
    for r in rows:
        print(indent + "  ".join(fmt(r.get(k)).ljust(w) if a == "l" else fmt(r.get(k)).rjust(w)
                                 for (k, _, a), w in zip(cols, widths)))


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


def heading(n, text):
    print(f"\n\n{n}. {text.upper()}")
    print("─" * (len(text) + 4))


def bar(pct, width=28):
    filled = int(round((pct or 0) / 100 * width))
    return "█" * filled + "·" * (width - filled)


# ── the report ───────────────────────────────────────────────────────────────────────────────

def report(days, only_screen):
    journey = get("app_journey")
    if journey is None:
        die("The drop-off views are not on this project yet.\n"
            "Apply supabase/migrations/20260907000001_screen_dropoff.sql — paste it into the SQL\n"
            f"editor at https://supabase.com/dashboard/project/{PROJECT_REF}/sql/new and run it.\n"
            "(Do NOT use `supabase db push`: it would also apply whatever else is pending in\n"
            " supabase/migrations/, which may include another session's in-progress work.)")

    if not journey:
        print("\nNo instrumented installs yet.\n")
        print("  Nothing has fired a `screen_view` — expected until a build carrying the screen")
        print("  tracking pass reaches real devices. DEBUG builds never egress (AnalyticsSink")
        print("  .egressAllowed); run with `--telemetry-live` to test the pipeline end to end.")
        return

    if only_screen:
        return screen_detail(only_screen)

    print("\n" + "=" * 74)
    print("  MOMENTUM — WHERE PEOPLE DROP OFF")
    print("=" * 74)

    # 1. The whole journey, collapsed across cohorts, as a funnel with drops.
    heading(1, "the journey")
    steps = [("installs", "installed"), ("acted_at_gate", "acted at the welcome"),
             ("began_onboarding", "began onboarding"), ("built_plan", "built a plan"),
             ("saw_paywall", "saw the paywall"), ("subscribed", "purchase / trial conversion"),
             ("reached_the_app", "reached the app"), ("opened_plan", "opened Plan"),
             ("opened_progress", "opened Progress"), ("opened_fuel", "opened Fuel"),
             ("started_a_workout", "started a workout"),
             ("completed_a_workout", "finished a workout"),
             ("returned_on_later_day", "returned on a later UTC day")]
    totals = {k: sum(r.get(k) or 0 for r in journey) for k, _ in steps}
    base = totals["installs"] or 1
    print("  New installs whose first launch was build 44+. Upgraded installs are excluded from this acquisition cohort.\n")
    for key, label in steps:
        n = totals[key]
        pct = 100.0 * n / base
        print(f"  {label:<24} {n:>6}  {bar(pct)} {pct:5.1f}%")
    print("\n  Independent milestone reach, NOT sequential funnel steps. Optional tabs need not be visited in order.")

    # 2. Where sessions end.
    heading(2, "where sessions end  (the drop-off map)")
    print("  The screen they were on when they put the phone down.\n")
    table(get("session_dropoff") or [],
          [("last_screen", "screen", "l"), ("sessions", "sessions", "r"),
           ("pct_of_sessions", "% of all", "r"), ("avg_seconds", "avg secs", "r"),
           ("avg_screens", "avg screens", "r"), ("abandoned_pct", "% recovered", "r")],
          limit=20)

    # 3. Exit rate — the same data, normalised, which is what actually finds a bad screen.
    heading(3, "exit rate per screen")
    print("  Among visits with an observed session end, how often was this screen the LAST thing they")
    print("  looked at. Ranked by exit rate, so a rarely-seen screen that always ends the session")
    print("  Per-view and per-visit rates are descriptive, not proof of dissatisfaction.\n")
    exits = [r for r in (get("screen_exit_rate") or []) if (r.get("views") or 0) >= 5]
    table(exits,
          [("screen", "screen", "l"), ("views", "views", "r"),
           ("times_it_was_the_last_screen", "was last", "r"), ("exit_pct", "view exit %", "r"),
           ("session_exit_pct", "visit exit %", "r")],
          limit=20)
    print("\n  (screens with fewer than 5 views are hidden — too few to read)")

    # 4. Churn.
    heading(4, "last screen before seven-day inactivity")
    print("  The last screen of the last session, for installs with no event for 7+ days.\n")
    churn = get("churn_screen") or []
    table(churn, [("last_screen", "screen", "l"),
                  ("installs_last_seen_here", "installs", "r"),
                  ("pct_of_churned", "% of churned", "r")], limit=15)
    if churn:
        top = churn[0]
        print(f"\n  → {top['pct_of_churned']}% of installs with seven days of observed silence were last")
        print(f"    standing on `{top['last_screen']}`.")

    # 5. Reach.
    heading(5, "reach  (which rooms get found)")
    print("  A screen near the bottom is one people never discover — a navigation problem, which")
    print("  is a different fix from a screen people reach and then leave.\n")
    table(get("screen_reach") or [],
          [("screen", "screen", "l"), ("installs", "installs", "r"),
           ("pct_of_installs", "% reached", "r"), ("views", "views", "r"),
           ("views_per_install", "per install", "r")],
          limit=40)

    # 6. Session shape over time.
    heading(6, f"session shape  (last {days} days)")
    since = (datetime.now(timezone.utc).date() - timedelta(days=days - 1)).isoformat()
    shape = get("session_shape", {"day": f"gte.{since}", "order": "day.desc"}) or []
    table(shape,
          [("day", "day", "l"), ("installs", "installs", "r"), ("sessions", "sessions", "r"),
           ("sessions_per_install", "per install", "r"), ("avg_screens", "screens", "r"),
           ("median_seconds", "median secs", "r"), ("measured_sessions", "measured", "r"),
           ("sessions_without_end", "no end", "r"), ("abandoned", "recovered", "r")])
    print("\n  Foreground visits include brief app switches. Session counts are not retention; use later-day")
    print("  returns with matured cohorts. Unknown durations are excluded from duration averages.")

    print("\n\nOne screen in detail:  python3 scripts/analysis/dropoff.py --screen <name>")
    print("Screen names come from AppScreen in Momentum/Services/ScreenTracking.swift\n")


def screen_detail(screen):
    print(f"\n{'=' * 74}\n  SCREEN: {screen}\n{'=' * 74}")

    reach = [r for r in (get("screen_reach") or []) if r["screen"] == screen]
    if not reach:
        names = sorted({r["screen"] for r in (get("screen_reach") or [])})
        die(f"No data for `{screen}`.\nKnown screens: {', '.join(names) or '(none yet)'}")
    r = reach[0]
    print(f"\n  {r['installs']} installs reached it ({r['pct_of_installs']}% of all), "
          f"{r['views']} views, {r['views_per_install']} per install.")

    ex = [x for x in (get("screen_exit_rate") or []) if x["screen"] == screen]
    if ex:
        print(f"  It was the last screen of a session {ex[0]['times_it_was_the_last_screen']} times "
              f"— an exit rate of {ex[0]['exit_pct']}%.")

    heading(1, "where they go from here")
    paths = [p for p in (get("screen_paths") or []) if p["screen"] == screen]
    table(paths, [("next_screen", "next", "l"), ("transitions", "times", "r"),
                  ("pct_of_screen", "% of exits from here", "r")], limit=20)

    heading(2, "how they arrive")
    incoming = [p for p in (get("screen_paths") or []) if p["next_screen"] == screen]
    incoming.sort(key=lambda p: -p["transitions"])
    table(incoming, [("screen", "from", "l"), ("transitions", "times", "r")], limit=20)
    print()


def check():
    """Is the pipeline alive at all? Cheap, and the first thing to run after a release."""
    print()
    missing = False
    for view in ("app_journey", "screen_reach", "session_dropoff", "screen_exit_rate",
                 "screen_paths", "churn_screen", "session_shape"):
        rows = get(view, {"limit": 1})
        if rows is None:
            missing = True
            print(f"  MISSING  {view}   ← migration 20260907000001 not applied")
        else:
            print(f"  ok       {view}   ({'has rows' if rows else 'empty'})")
    print("  View availability only; empty views do not prove device delivery.")
    if missing:
        raise SystemExit(1)
    print()


def main():
    global KEY
    ap = argparse.ArgumentParser(description="Where people drop off in momentum.")
    ap.add_argument("--days", type=int, default=14, help="days of session shape to show")
    ap.add_argument("--screen", help="drill into one screen (AppScreen raw value, e.g. plan)")
    ap.add_argument("--check", action="store_true", help="only verify the views exist")
    args = ap.parse_args()

    if args.days < 1 or args.days > 3650:
        ap.error("--days must be between 1 and 3650")
    KEY = service_key()
    if args.check:
        check()
    else:
        report(args.days, args.screen)


if __name__ == "__main__":
    main()
