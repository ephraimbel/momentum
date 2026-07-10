#!/bin/bash
# Companion to MomentumUITests/EmailAuthUITests: while the test waits at the "check your email"
# beat, this polls the live project for the newest unconfirmed e2e.* user, generates its
# confirmation link via the admin API (no inbox needed), and opens it on the simulator —
# momentum://auth-callback signs the athlete in and the test resumes its onboarding walk.
#
# Usage: scripts/e2e_email_confirm.sh <sim-udid>
# Needs: the Supabase CLI logged in on this Mac (token in the keychain) — nothing is printed.
set -euo pipefail

UDID="${1:?usage: e2e_email_confirm.sh <sim-udid>}"
PROJECT_REF="hhhlrqngutmyccfpgdoq"

TOKEN=$(security find-generic-password -s "Supabase CLI" -w)
[[ "$TOKEN" == go-keyring-base64:* ]] && TOKEN=$(echo "${TOKEN#go-keyring-base64:}" | base64 -d)
SERVICE=$(curl -s "https://api.supabase.com/v1/projects/$PROJECT_REF/api-keys?reveal=true" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import json,sys; print(next(k['api_key'] for k in json.load(sys.stdin) if k['name']=='service_role'))")

echo "waiting for a fresh unconfirmed e2e.* signup…"
EMAIL=""
for _ in $(seq 1 60); do
  EMAIL=$(curl -s "https://$PROJECT_REF.supabase.co/auth/v1/admin/users?per_page=10" \
    -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" \
    | python3 -c "
import json, sys
users = json.load(sys.stdin).get('users', [])
fresh = [u for u in users if (u.get('email') or '').startswith('e2e.') and not u.get('email_confirmed_at')]
fresh.sort(key=lambda u: u['created_at'], reverse=True)
print(fresh[0]['email'] if fresh else '')")
  [ -n "$EMAIL" ] && break
  sleep 3
done
[ -n "$EMAIL" ] || { echo "no unconfirmed e2e.* user appeared — is the UI test running?"; exit 1; }
echo "confirming $EMAIL"

# type=signup needs the password; magiclink avoids it and signs in just the same.
LINK=$(curl -s -X POST "https://$PROJECT_REF.supabase.co/auth/v1/admin/generate_link" \
  -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" \
  -d "{\"type\":\"magiclink\",\"email\":\"$EMAIL\",\"options\":{\"redirect_to\":\"momentum://auth-callback\"}}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('action_link',''))")
[ -n "$LINK" ] || { echo "generate_link failed"; exit 1; }

# Resolve the verify hop OUTSIDE the sim browser: curl follows nothing, just captures the
# Location header, which is the momentum:// URL carrying the session tokens.
APP_URL=$(curl -s -o /dev/null -w '%{redirect_url}' "$LINK")
case "$APP_URL" in momentum://*) ;; *) echo "unexpected redirect: $APP_URL"; exit 1;; esac

sleep 3   # let the gate settle on its "check your email" beat before the deep link arrives
xcrun simctl openurl "$UDID" "$APP_URL"
echo "opened confirmation deep link on $UDID ✓"
