#!/usr/bin/env bash
#
# build-aab.sh (#163) — produce the Play Store .aab bundle.
#
# Mirrors scripts/build-and-upload.sh but emits .aab instead of .apk
# and uploads to a different VPS path (downloads.interactpak.com/pro/
# stays APK; .aab lives under /pro/aab/ for Play Console pickup).
#
# Preflight: refuses to build with an empty AI secret, same as the
# APK builder. Bake the secret first with scripts/bake-ai-secret.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

DEFINES="$PROJECT_DIR/dart_defines.json"
if [ ! -f "$DEFINES" ]; then
    echo "ERROR: $DEFINES missing. Run scripts/bake-ai-secret.sh first." >&2
    exit 1
fi
SECRET=$(grep -o '"INTERACT_PRO_AI_SECRET"\s*:\s*"[^"]*"' "$DEFINES" \
    | sed -E 's/.*"INTERACT_PRO_AI_SECRET"\s*:\s*"([^"]*)".*/\1/')
if [ -z "$SECRET" ]; then
    echo "ERROR: INTERACT_PRO_AI_SECRET is empty in $DEFINES." >&2
    echo "       Run scripts/bake-ai-secret.sh to populate it." >&2
    exit 1
fi
echo "✓ AI secret found (${#SECRET} bytes)"

echo "→ Building app bundle (release)…"
flutter build appbundle --release --dart-define-from-file=dart_defines.json

AAB="build/app/outputs/bundle/release/app-release.aab"
if [ ! -f "$AAB" ]; then
    echo "ERROR: expected $AAB not produced" >&2
    exit 1
fi
size=$(du -h "$AAB" | cut -f1)
echo "✓ Built $AAB ($size)"

echo
echo "Next steps:"
echo "  1. Upload to Play Console → Internal Testing track:"
echo "     https://play.google.com/console/u/0/developers/-/app-list"
echo "  2. Or stage on the VPS for the manual-install fallback:"
echo "     scp $AAB root@178.105.73.238:/var/www/downloads/pro/aab/"
echo "     (note: .aab won't sideload — must go through Play)"
