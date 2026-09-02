#!/bin/bash
# The auth E2E orchestrator.
#
# `AuthFlowsUITests` and `EmailAuthUITests` are the only tests that exercise REAL authentication —
# sign-up, the momentum://auth-callback confirmation, password reset, guest upgrade, account
# deletion. They have always failed by default, not because anything is broken but because each one
# needs a server-side precondition that nothing set up: a user in a particular state, and a deep
# link fired into the simulator at the right moment. This script is that missing half.
#
#   scripts/e2e_auth.sh signup [udid]   # EmailAuthUITests — real in-app sign-up + confirmation
#   scripts/e2e_auth.sh flows  [udid]   # AuthFlowsUITests 1–4, each with its own precondition
#   scripts/e2e_auth.sh all    [udid]   # both, then clean up
#   scripts/e2e_auth.sh clean           # delete every leftover e2e.* user
#
# NO MAILBOX IS INVOLVED. Every link is minted through the admin API (`generate_link`) and opened
# straight on the simulator, so a run costs zero emails against the built-in mailer's tight hourly
# budget — which is also why these tests must never be pointed at a real inbox.
#
# Credentials: a Supabase personal access token, from $SUPABASE_ACCESS_TOKEN if set, otherwise the
# Supabase CLI's keychain entry. The env var is what lets this run in CI, or in any sandbox that
# cannot read the keychain.
set -euo pipefail

CMD="${1:?usage: e2e_auth.sh <signup|flows|all|clean> [sim-udid]}"
UDID="${2:-}"
PROJECT_REF="hhhlrqngutmyccfpgdoq"
SCHEME="Momentum"
# Reuse an already-built test bundle when the caller provides one. Keeping the historical local
# default preserves direct usage while CI/release hardening can avoid a second multi-gigabyte build.
DERIVED="${DERIVED_DATA_PATH:-build/dd}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# A password that satisfies the app's own 8-character floor at both ends of the reset.
E2E_PASS="e2e-first-pass-1"
E2E_NEWPASS="e2e-second-pass-2"
ACTIVE_E2E_EMAIL=""
ACTIVE_RECOVERY_PID=""

# ── credentials ──────────────────────────────────────────────────────────────────────────────
token() {
  if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then printf '%s' "$SUPABASE_ACCESS_TOKEN"; return; fi
  local t
  t=$(security find-generic-password -s "Supabase CLI" -w 2>/dev/null) || {
    echo "No Supabase token. Export SUPABASE_ACCESS_TOKEN, or log in with the Supabase CLI." >&2
    exit 1
  }
  [[ "$t" == go-keyring-base64:* ]] && t=$(echo "${t#go-keyring-base64:}" | base64 -d)
  printf '%s' "$t"
}

SERVICE="${SUPABASE_SERVICE_ROLE_KEY:-}"
if [ -z "$SERVICE" ]; then
  SERVICE=$(curl -fsS "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true" \
    -H "Authorization: Bearer $(token)" \
    | python3 -c "import json,sys; print(next(k['api_key'] for k in json.load(sys.stdin) if k['name']=='service_role'))")
fi
AUTH_URL="https://$PROJECT_REF.supabase.co/auth/v1"
ADMIN=(-H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json")

# ── admin helpers ────────────────────────────────────────────────────────────────────────────
# Every e2e user is minted under a domain we own, with a run-scoped local part, so `clean` can
# recognise them and a half-finished run can never leave a real-looking account behind.
mint_email() { echo "e2e.$(date +%s).$RANDOM@momentumco.app"; }

user_id() {  # user_id <email>
  curl -fsS "$AUTH_URL/admin/users?per_page=200" "${ADMIN[@]}" | python3 -c "
import json,sys
want = sys.argv[1].lower()
print(next((u['id'] for u in json.load(sys.stdin).get('users', [])
            if (u.get('email') or '').lower() == want), ''))" "$1"
}

create_user() {  # create_user <email> <password> <confirmed:true|false>
  curl -fsS -X POST "$AUTH_URL/admin/users" "${ADMIN[@]}" \
    -d "{\"email\":\"$1\",\"password\":\"$2\",\"email_confirm\":$3}" >/dev/null
}

update_user() {  # update_user <id> <json-body>
  curl -fsS -X PUT "$AUTH_URL/admin/users/$1" "${ADMIN[@]}" -d "$2" >/dev/null
}

delete_user() { curl -fsS -X DELETE "$AUTH_URL/admin/users/$1" "${ADMIN[@]}" >/dev/null || true; }

# Mint a link and resolve its verify hop OUTSIDE the sim browser: curl follows nothing and just
# reports the Location header, which is the momentum:// URL carrying the session tokens.
open_link() {  # open_link <type> <email>
  local link app_url
  link=$(curl -fsS -X POST "$AUTH_URL/admin/generate_link" "${ADMIN[@]}" \
    -d "{\"type\":\"$1\",\"email\":\"$2\",\"options\":{\"redirect_to\":\"momentum://auth-callback\"}}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('action_link',''))")
  [ -n "$link" ] || { echo "generate_link($1) failed for $2" >&2; return 1; }
  app_url=$(curl -s -o /dev/null -w '%{redirect_url}' "$link")
  case "$app_url" in momentum://*) ;; *) echo "unexpected redirect: $app_url" >&2; return 1;; esac
  xcrun simctl openurl "$UDID" "$app_url"
}

# ── simulator ────────────────────────────────────────────────────────────────────────────────
resolve_udid() {
  [ -n "$UDID" ] && return
  UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d = json.load(sys.stdin)['devices']
for runtime, devices in sorted(d.items(), reverse=True):
    for dev in devices:
        if dev['name'].startswith('iPhone'):
            print(dev['udid']); raise SystemExit
")
  [ -n "$UDID" ] || { echo "no iPhone simulator found" >&2; exit 1; }
  echo "simulator: $UDID"
}

# One test at a time. These walks share a local store on purpose (a signed-out athlete keeps their
# profile, which is what makes the returning-athlete door reachable), so they must not interleave.
run_test() {  # run_test <Suite/method> [extra TEST_RUNNER_ env assignments...]
  local target="$1"; shift
  echo "── $target"
  # Keep the compact console view, but return xcodebuild's status rather than grep's. The old
  # trailing `|| true` made a red UI walk look green to both CI and this orchestrator.
  set +e
  env "$@" xcodebuild test-without-building \
    -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" -only-testing:"$target" \
    ENABLE_DEBUG_DYLIB=NO 2>&1 | grep -E "Test Case.*(passed|failed)|error:"
  local xcode_status=${PIPESTATUS[0]}
  set -e
  return "$xcode_status"
}

# Failed live-auth walks must not strand test accounts or a delayed recovery-link process. This
# trap is deliberately narrow: it knows only about the one user minted by `run_flows`.
cleanup_active_flow() {
  if [ -n "$ACTIVE_RECOVERY_PID" ]; then
    kill "$ACTIVE_RECOVERY_PID" 2>/dev/null || true
    wait "$ACTIVE_RECOVERY_PID" 2>/dev/null || true
    ACTIVE_RECOVERY_PID=""
  fi
  if [ -n "$ACTIVE_E2E_EMAIL" ]; then
    local id
    id=$(user_id "$ACTIVE_E2E_EMAIL" 2>/dev/null || true)
    [ -n "$id" ] && delete_user "$id"
    ACTIVE_E2E_EMAIL=""
  fi
}
trap cleanup_active_flow EXIT INT TERM

# ── flows: AuthFlowsUITests 1–4 ──────────────────────────────────────────────────────────────
# Each test wants the account in a DIFFERENT state, and test2 deliberately changes the password
# out from under test4 — so the state is rebuilt between tests rather than assumed.
run_flows() {
  local email id
  email=$(mint_email)
  ACTIVE_E2E_EMAIL="$email"
  echo "e2e user: $email"

  # 1 — unconfirmed, so the "confirm your email first" nudge is the honest answer.
  create_user "$email" "$E2E_PASS" false
  run_test "MomentumUITests/AuthFlowsUITests/test1_messagingWrongPasswordAndUnconfirmed" \
    "TEST_RUNNER_E2E_EMAIL=$email" "TEST_RUNNER_E2E_PASS=$E2E_PASS"

  # 2 — confirm, then fire the recovery link WHILE the test waits on the New password sheet.
  id=$(user_id "$email")
  update_user "$id" '{"email_confirm":true}'
  ( sleep 20; open_link recovery "$email" ) &
  local recovery_pid=$!
  ACTIVE_RECOVERY_PID="$recovery_pid"
  run_test "MomentumUITests/AuthFlowsUITests/test2_passwordResetSignOutSignIn" \
    "TEST_RUNNER_E2E_EMAIL=$email" "TEST_RUNNER_E2E_PASS=$E2E_PASS" \
    "TEST_RUNNER_E2E_NEWPASS=$E2E_NEWPASS"
  wait $recovery_pid 2>/dev/null || true
  ACTIVE_RECOVERY_PID=""

  # 3 — guest upgrade signs in with the password test2 just set.
  run_test "MomentumUITests/AuthFlowsUITests/test3_guestUpgradeViaEmail" \
    "TEST_RUNNER_E2E_EMAIL=$email" "TEST_RUNNER_E2E_NEWPASS=$E2E_NEWPASS"

  # 4 — deletion signs in with E2E_PASS, which test2 replaced. Put it back rather than letting the
  # test fail on a stale credential; the account state is the fixture, not the thing under test.
  id=$(user_id "$email")
  [ -n "$id" ] && update_user "$id" "{\"password\":\"$E2E_PASS\"}"
  run_test "MomentumUITests/AuthFlowsUITests/test4_deleteAccount" \
    "TEST_RUNNER_E2E_EMAIL=$email" "TEST_RUNNER_E2E_PASS=$E2E_PASS"

  # test4 deletes the account itself; this is the belt-and-braces for a run that fell over first.
  id=$(user_id "$email"); [ -n "$id" ] && delete_user "$id"
  ACTIVE_E2E_EMAIL=""
  echo "flows done"
}

# ── signup: EmailAuthUITests + the confirmation companion ────────────────────────────────────
# This one signs up THROUGH THE APP (the only test that does), so the user does not exist until
# the walk creates it. The companion polls for it and opens the link.
run_signup() {
  echo "── MomentumUITests/EmailAuthUITests (+ confirmation companion)"
  # FRESH CONTAINER, not just a fresh launch. This walk asserts it lands in ONBOARDING after the
  # confirmation link, which only happens with no local profile and no stored session — a sim that
  # has ever run --seed-demo has both, so the link signs the athlete straight into the tabs and the
  # test times out looking for "What should we call you?". Uninstalling is the only reliable reset;
  # xcodebuild reinstalls the app and the runner on the next line.
  xcrun simctl uninstall "$UDID" com.ephraimbel.momentum.app 2>/dev/null || true

  ./scripts/e2e_email_confirm.sh "$UDID" &
  local confirm_pid=$!
  run_test "MomentumUITests/EmailAuthUITests"
  wait $confirm_pid 2>/dev/null || true
}

# ── clean ────────────────────────────────────────────────────────────────────────────────────
# A failed run leaves its user behind, and a stale unconfirmed e2e.* user makes the NEXT run's
# confirmation companion latch onto the wrong account. Cleaning is part of the contract.
run_clean() {
  local ids
  ids=$(curl -fsS "$AUTH_URL/admin/users?per_page=200" "${ADMIN[@]}" | python3 -c "
import json,sys
for u in json.load(sys.stdin).get('users', []):
    if (u.get('email') or '').startswith('e2e.'): print(u['id'])")
  if [ -z "$ids" ]; then echo "no e2e.* users to clean"; return; fi
  local n=0
  while read -r id; do [ -n "$id" ] && delete_user "$id" && n=$((n+1)); done <<< "$ids"
  echo "deleted $n e2e.* user(s)"
}

case "$CMD" in
  signup) resolve_udid; run_signup ;;
  flows)  resolve_udid; run_flows ;;
  all)    resolve_udid; run_signup; run_flows; run_clean ;;
  clean)  run_clean ;;
  *) echo "usage: e2e_auth.sh <signup|flows|all|clean> [sim-udid]" >&2; exit 1 ;;
esac
