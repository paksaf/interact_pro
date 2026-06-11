#!/usr/bin/env bash
# deploy-pro-api-from-mac.sh — ship the pro-api Express server changes to
# /srv/interact-pro-api/ on the VPS, apply ALL migrations (idempotent, in
# order), restart the systemd unit, and smoke-probe.
#
# 2026-06-10: generalized from the 006-only version — now ships every
# server .js + ALL migrations/*.sql and applies them in order (each file
# is IF NOT EXISTS-idempotent), so adding e.g. 007_iap_canonical_txn.sql
# needs no script edit.
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

echo ">> Shipping pro-api updates to ${SSH_HOST}:${REMOTE_ROOT}/ ..."
(
  cd "$SRC"
  rsync -avR --no-perms --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \
    ./*.js \
    ./migrations/*.sql \
    "$SSH_HOST":"$REMOTE_ROOT/"
)

echo ">> Applying ALL migrations (in order, idempotent) + restart ..."
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

for m in ${REMOTE_ROOT}/migrations/*.sql; do
  echo ">> Applying \$(basename "\$m") ..."
  psql "\$DB" -v ON_ERROR_STOP=1 -f "\$m"
done

echo ">> Restarting service ..."
systemctl restart interact-pro-api.service
sleep 2
systemctl --no-pager --lines=10 status interact-pro-api.service | head -20

echo ""
echo ">> Loopback probe — health/open route:"
curl -sS -o /dev/null -w 'HTTP %{http_code}  /api/notify/ios-waitlist (expect 400 on empty body = route alive)\n' \
  -X POST http://127.0.0.1:3050/api/notify/ios-waitlist \
  -H 'Content-Type: application/json' -d '{}'
curl -sS -o /dev/null -w 'HTTP %{http_code}  /api/iap/verify (expect 401 unauth = route alive)\n' \
  -X POST http://127.0.0.1:3050/api/iap/verify \
  -H 'Content-Type: application/json' -d '{}'
REMOTE

echo ""
echo ">> Done. The IAP anti-replay hardening (007) is live once status shows active."
