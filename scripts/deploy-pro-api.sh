#!/usr/bin/env bash
#
# deploy-pro-api.sh — one command to ship server/pro-api/ to the VPS.
#
# What it does:
#   1. rsyncs server/pro-api/ to /opt/interact/pro-api/ via the `interact`
#      SSH alias (or PRO_SSH_ALIAS env var if you've set a different one).
#   2. Runs `npm ci --omit=dev` on the VPS.
#   3. Reloads / restarts the systemd unit.
#   4. Smoke-tests the /api/healthz endpoint.
#
# What it does NOT do:
#   • First-time setup (Postgres, the systemd unit file, the env file,
#     the Caddyfile splice). Those live in DEPLOY.md and run once.
#
# Usage:
#   bash scripts/deploy-pro-api.sh
#   bash scripts/deploy-pro-api.sh --no-restart   # rsync only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

NO_RESTART=false
for arg in "$@"; do
  case "$arg" in
    --no-restart) NO_RESTART=true ;;
    -h|--help)
      sed -n '3,18p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

if [ -f "$PROJECT_DIR/.env.local" ]; then
  # shellcheck disable=SC2046
  export $(grep -E '^PRO_SSH_ALIAS' "$PROJECT_DIR/.env.local" | xargs)
fi
PRO_ALIAS="${PRO_SSH_ALIAS:-interact}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$PRO_ALIAS" 'true' 2>/dev/null; then
  echo "ERROR: ssh $PRO_ALIAS isn't working. Set PRO_SSH_ALIAS=<host> in"
  echo "       .env.local or fix your ~/.ssh/config first."
  exit 1
fi

echo "→ rsyncing server/pro-api/ to $PRO_ALIAS:/opt/interact/pro-api/"
rsync -avz --delete \
  --exclude node_modules \
  --exclude .DS_Store \
  server/pro-api/ \
  "$PRO_ALIAS:/opt/interact/pro-api/"

echo
echo "→ npm install on VPS"
ssh "$PRO_ALIAS" '
  set -e
  cd /opt/interact/pro-api
  # `npm install` not `npm ci` because we don'\''t ship a lockfile —
  # the first install on the VPS creates one. Subsequent deploys see
  # the lockfile and behave deterministically.
  npm install --omit=dev --no-audit --no-fund
  chown -R interact:interact /opt/interact/pro-api 2>/dev/null || true
'

if ! $NO_RESTART; then
  echo
  echo "→ restarting interact-pro-api service"
  ssh "$PRO_ALIAS" 'systemctl restart interact-pro-api && sleep 1'
  echo
  echo "→ smoke-test /api/healthz"
  if ssh "$PRO_ALIAS" 'curl -fsS http://127.0.0.1:3050/api/healthz'; then
    echo
    echo "  ✓ pro-api healthy"
  else
    echo
    echo "  ✗ /api/healthz failed — see logs:"
    echo "    ssh $PRO_ALIAS 'journalctl -u interact-pro-api -n 30 --no-pager'"
    exit 1
  fi
fi

echo
echo "=== Done ==="
echo "  https://pro.interactpak.com/api/healthz"
echo "  ssh $PRO_ALIAS 'journalctl -u interact-pro-api -f'"
