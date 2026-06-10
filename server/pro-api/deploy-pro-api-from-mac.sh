#!/usr/bin/env bash
# deploy-pro-api-from-mac.sh — ship the pro-api Express server changes
# (ios-waitlist route + migration 006) to /srv/interact-pro-api/ on the
# VPS, then run the migration and restart the systemd unit.
#
# Reads the install location from systemd's environment for the
# interact-pro-api service (per memory: interact-pro-api.service).

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SSH_HOST="${SSH_HOST:-interact}"

# Discover the pro-api deploy root by asking systemd what working
# directory the service uses.
REMOTE_ROOT="${REMOTE_ROOT:-}"
if [ -z "$REMOTE_ROOT" ]; then
  REMOTE_ROOT=$(ssh "$SSH_HOST" "systemctl show -p WorkingDirectory --value interact-pro-api 2>/dev/null")
fi
[ -z "$REMOTE_ROOT" ] && REMOTE_ROOT="/srv/interact-pro-api"
echo "Using REMOTE_ROOT=$REMOTE_ROOT"

# Files to ship.
SYNC_PATHS=(
  ./index.js
  ./ios-waitlist.js
  ./migrations/006_ios_waitlist.sql
)
for f in "${SYNC_PATHS[@]}"; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f"; exit 1; }
done

echo ">> Shipping pro-api updates to ${SSH_HOST}:${REMOTE_ROOT}/ ..."
(
  cd "$SRC"
  rsync -avR --no-perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    "${SYNC_PATHS[@]}" \
    "$SSH_HOST":"$REMOTE_ROOT/"
)

echo ">> Running migration 006 + restarting interact-pro-api.service ..."
ssh -t "$SSH_HOST" 'sudo bash -s' <<REMOTE
set -uo pipefail
cd ${REMOTE_ROOT}

# Pull DATABASE_URL from the pro-api env file (per memory: /etc/interact/pro-api.env).
DB=\$(grep '^DATABASE_URL=' /etc/interact/pro-api.env 2>/dev/null | sed 's/^DATABASE_URL=//' | tr -d '"' )
if [ -z "\$DB" ]; then
  DB=\$(grep '^DATABASE_URL=' ${REMOTE_ROOT}/.env 2>/dev/null | sed 's/^DATABASE_URL=//' | tr -d '"' )
fi
if [ -z "\$DB" ]; then
  echo "FATAL: DATABASE_URL not found in /etc/interact/pro-api.env or ${REMOTE_ROOT}/.env"
  exit 2
fi

echo ">> Applying migration 006 ..."
psql "\$DB" -v ON_ERROR_STOP=1 -f ${REMOTE_ROOT}/migrations/006_ios_waitlist.sql

echo ">> Restarting service ..."
systemctl restart interact-pro-api.service
sleep 2
systemctl --no-pager --lines=10 status interact-pro-api.service | head -20

echo ""
echo ">> Loopback probe — POST a sample to the open route:"
curl -sS -o /dev/null -w 'HTTP %{http_code}  /api/notify/ios-waitlist\n' \
  -X POST http://127.0.0.1:3050/api/notify/ios-waitlist \
  -H 'Content-Type: application/json' \
  -d '{"email":"smoke-test@example.com","name":"deploy-smoke","device":"iPhone smoke"}'
REMOTE

echo ""
echo ">> Done. Public verifier (POSTs a real email; OK to send):"
echo "  curl -sS -X POST https://pro.interactpak.com/api/notify/ios-waitlist \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"email\":\"you@example.com\",\"name\":\"smoke\"}'"
echo ""
echo "  Expected: {\"ok\":true,\"already\":false,\"id\":1} on first run,"
echo "            {\"ok\":true,\"already\":true,\"id\":1}  on re-run."
