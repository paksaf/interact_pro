#!/usr/bin/env bash
# deploy-landing-from-mac.sh — uploads the Pro landing pages (index.html
# + ios.html) to /var/www/interactpro/ on the VPS, where Caddy already
# serves pro.interactpak.com as a static document root alongside
# InteractPro.apk.
#
# Existing memory (interact_pro_deployment.md):
#   APK served at https://pro.interactpak.com/InteractPro.apk
#   APK dir on VPS: /var/www/interactpro/

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SSH_HOST="${SSH_HOST:-interact}"
REMOTE_ROOT="${REMOTE_ROOT:-/var/www/interactpro}"

for f in index.html ios.html; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f"; exit 1; }
done

echo ">> Shipping landing pages + icon to ${SSH_HOST}:${REMOTE_ROOT}/ ..."
ssh "$SSH_HOST" "sudo mkdir -p ${REMOTE_ROOT}"
scp "$SRC"/index.html "$SRC"/ios.html "$SSH_HOST":/tmp/
# Icon is optional — only ship it if it's been generated.
if [ -f "$SRC/icon-180.png" ]; then
  scp "$SRC/icon-180.png" "$SSH_HOST":/tmp/icon-180.png
fi

ssh -t "$SSH_HOST" "sudo install -m 0644 /tmp/index.html ${REMOTE_ROOT}/index.html && sudo install -m 0644 /tmp/ios.html ${REMOTE_ROOT}/ios.html && ([ -f /tmp/icon-180.png ] && sudo install -m 0644 /tmp/icon-180.png ${REMOTE_ROOT}/icon-180.png || true) && sudo ls -la ${REMOTE_ROOT}/index.html ${REMOTE_ROOT}/ios.html ${REMOTE_ROOT}/icon-180.png 2>/dev/null"

echo ""
echo ">> Verifying public reachability:"
curl -sS -o /dev/null -w 'HTTP %{http_code}  https://pro.interactpak.com/\n'         https://pro.interactpak.com/         || true
curl -sS -o /dev/null -w 'HTTP %{http_code}  https://pro.interactpak.com/ios.html\n' https://pro.interactpak.com/ios.html || true

echo ""
echo "On iPhone Safari, hitting https://pro.interactpak.com/ should"
echo "auto-redirect to /ios.html (user-agent check in the index page)."
echo "Android users see the APK download CTA."
