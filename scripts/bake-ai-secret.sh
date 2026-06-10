#!/usr/bin/env bash
#
# bake-ai-secret.sh — one-shot fetcher for INTERACT_PRO_AI_SECRET.
#
# Pulls the shared secret from the VPS file `/etc/interact/pro-ai.env`
# and writes it into the local `dart_defines.json`, so the next
# `bash scripts/build-and-upload.sh` produces an APK whose
# `String.fromEnvironment('INTERACT_PRO_AI_SECRET')` is non-empty
# and the advanced OCR + multi-voice TTS features actually work.
#
# Without this, the bottom banner in BookViewer reads:
#   "Read-aloud needs the Advanced OCR backend. This build doesn't
#    have the AI secret baked in."
# and read-aloud silently falls back to local Tesseract OCR, which
# produces visible errors on dense pages (e.g. "Vo Icanoes" instead
# of "Volcanoes").
#
# Run from project root:
#
#   bash scripts/bake-ai-secret.sh
#   bash scripts/bake-ai-secret.sh --print     # just print the secret, don't write
#   bash scripts/bake-ai-secret.sh --clear     # blank the value
#
# Requires: ssh access to root@178.105.73.238 (or PRO_SSH_ALIAS=interact
# in .env.local), jq for the JSON merge.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

MODE="bake"
for arg in "$@"; do
  case "$arg" in
    --print) MODE="print" ;;
    --clear) MODE="clear" ;;
    -h|--help)
      sed -n '3,28p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown arg: $arg (try --help)"; exit 2 ;;
  esac
done

DEFINES="$PROJECT_DIR/dart_defines.json"
if [ ! -f "$DEFINES" ]; then
  echo "ERROR: $DEFINES not found. Copy dart_defines.example.json first." >&2
  exit 1
fi

# Clear mode — wipe the value and exit
if [ "$MODE" = "clear" ]; then
  jq '.INTERACT_PRO_AI_SECRET = ""' "$DEFINES" > "$DEFINES.tmp"
  mv "$DEFINES.tmp" "$DEFINES"
  echo "✓ Cleared INTERACT_PRO_AI_SECRET in $DEFINES"
  exit 0
fi

# Resolve SSH target (same logic as build-and-upload.sh)
if [ -f "$PROJECT_DIR/.env.local" ]; then
  # shellcheck disable=SC2046
  export $(grep -E '^(PRO_VPS|PRO_SSH_ALIAS)' "$PROJECT_DIR/.env.local" | xargs)
fi

PRO_ALIAS="${PRO_SSH_ALIAS:-}"
PRO_HOST="${PRO_VPS_HOST:-178.105.73.238}"
PRO_USER="${PRO_VPS_USER:-root}"
PRO_KEY="${PRO_VPS_KEY:-$HOME/.ssh/interactpak}"

if [ -n "$PRO_ALIAS" ]; then
  SSH_TARGET="$PRO_ALIAS"
  SSH_OPTS=()
elif [ -f "$PRO_KEY" ]; then
  SSH_TARGET="$PRO_USER@$PRO_HOST"
  SSH_OPTS=(-i "$PRO_KEY" -o "StrictHostKeyChecking=accept-new")
else
  SSH_TARGET="$PRO_USER@$PRO_HOST"
  SSH_OPTS=()
fi

echo "→ Fetching INTERACT_PRO_AI_SECRET from $SSH_TARGET:/etc/interact/pro-ai.env"

# Grep the secret out of the env file without printing it to the
# script's own stdout. The env file has the shape:
#   INTERACT_PRO_AI_SECRET=hexbytes...
# We use `grep | cut` instead of `source` to avoid the bash <> trap
# documented in memory bash_source_envfile_trap.
SECRET="$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "grep '^INTERACT_PRO_AI_SECRET=' /etc/interact/pro-ai.env | cut -d= -f2- | tr -d '\"'" 2>/dev/null || true)"

if [ -z "$SECRET" ]; then
  echo "✗ Couldn't read INTERACT_PRO_AI_SECRET from the VPS." >&2
  echo "  Check that /etc/interact/pro-ai.env exists and your SSH access works:" >&2
  echo "    ssh ${SSH_TARGET} 'ls -la /etc/interact/pro-ai.env'" >&2
  exit 1
fi

if [ "$MODE" = "print" ]; then
  # Print to stdout but mask the middle of the value
  LEN=${#SECRET}
  if [ "$LEN" -gt 12 ]; then
    echo "Secret length: $LEN bytes. Preview: ${SECRET:0:4}…${SECRET: -4}"
  else
    echo "Secret length: $LEN bytes (too short to mask safely)."
  fi
  exit 0
fi

# Bake into dart_defines.json via jq so we don't lose formatting or
# accidentally drop a key. Atomic rename.
jq --arg s "$SECRET" '.INTERACT_PRO_AI_SECRET = $s' "$DEFINES" > "$DEFINES.tmp"
mv "$DEFINES.tmp" "$DEFINES"

LEN=${#SECRET}
echo "✓ Baked INTERACT_PRO_AI_SECRET into $DEFINES (${LEN} bytes)"
echo "  Next: bash scripts/build-and-upload.sh --android-only"
