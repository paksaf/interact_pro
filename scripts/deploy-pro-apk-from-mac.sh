#!/usr/bin/env bash
# deploy-pro-apk-from-mac.sh
#
# Builds, versions, uploads Interact Pro APK(s) to pro.interactpak.com
# AND writes version.json so the in-app update checker picks up the
# new build. Modeled on scripts/deploy-sahulat-apk.sh.
#
# Public URLs after a successful run:
#   https://pro.interactpak.com/InteractPro.apk             (universal)
#   https://pro.interactpak.com/InteractPro-arm64.apk       (modern phones / TV)
#   https://pro.interactpak.com/InteractPro-arm.apk         (older phones)
#   https://pro.interactpak.com/version.json                (manifest)
#
# Usage:
#   cd /Users/muzafar/Documents/INTERACT/interact_pro
#   scripts/deploy-pro-apk-from-mac.sh                 # bump + build all + upload
#   scripts/deploy-pro-apk-from-mac.sh --skip-build    # upload existing builds
#   scripts/deploy-pro-apk-from-mac.sh --skip-bump     # don't increment versionCode
#   scripts/deploy-pro-apk-from-mac.sh --universal     # only universal APK

set -euo pipefail

APP_DIR="${APP_DIR:-/Users/muzafar/Documents/INTERACT/interact_pro}"
SSH_HOST="${SSH_HOST:-interact}"
VPS_DEST="${VPS_DEST:-/var/www/interactpro}"
PUBLIC_BASE="https://pro.interactpak.com"

SKIP_BUILD=0
SKIP_BUMP=0
UNIVERSAL_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-bump)  SKIP_BUMP=1 ;;
    --universal)  UNIVERSAL_ONLY=1 ;;
    -h|--help)
      sed -n '1,28p' "$0"; exit 0 ;;
  esac
done

cd "$APP_DIR"

# ── Version bump ────────────────────────────────────────────────
VERSION_LINE=$(grep "^version:" pubspec.yaml | head -1)
VERSION_FULL="${VERSION_LINE#version: }"
VERSION_NAME="${VERSION_FULL%%+*}"
VERSION_BUILD="${VERSION_FULL##*+}"
if [ "$SKIP_BUMP" != "1" ]; then
  NEW_BUILD=$((VERSION_BUILD + 1))
  NEW_FULL="${VERSION_NAME}+${NEW_BUILD}"
  echo "→ Bumping version: $VERSION_FULL → $NEW_FULL"
  sed -i.bak "s/^version: .*/version: $NEW_FULL/" pubspec.yaml && rm pubspec.yaml.bak
else
  NEW_BUILD=$VERSION_BUILD
  echo "→ Keeping version: $VERSION_FULL"
fi

# ── Build ───────────────────────────────────────────────────────
if [ "$SKIP_BUILD" != "1" ]; then
  echo "→ flutter pub get"
  flutter pub get

  echo "→ dart run build_runner build (drift + riverpod + freezed)"
  dart run build_runner build --delete-conflicting-outputs

  if [ "$UNIVERSAL_ONLY" = "1" ]; then
    echo "→ flutter build apk --release (universal only)"
    flutter build apk --release
  else
    echo "→ flutter build apk --release --split-per-abi"
    flutter build apk --release --split-per-abi
    echo "→ flutter build apk --release (universal)"
    flutter build apk --release
  fi
fi

# ── Stage ───────────────────────────────────────────────────────
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

UNIVERSAL_SRC="build/app/outputs/flutter-apk/app-release.apk"
ARM64_SRC="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
ARM_SRC="build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk"

[ -f "$UNIVERSAL_SRC" ] || { echo "ERROR: $UNIVERSAL_SRC missing — build failed?"; exit 1; }
cp "$UNIVERSAL_SRC" "$STAGE/InteractPro.apk"
if [ "$UNIVERSAL_ONLY" != "1" ] && [ -f "$ARM64_SRC" ]; then
  cp "$ARM64_SRC" "$STAGE/InteractPro-arm64.apk"
fi
if [ "$UNIVERSAL_ONLY" != "1" ] && [ -f "$ARM_SRC" ]; then
  cp "$ARM_SRC" "$STAGE/InteractPro-arm.apk"
fi

# Compute sizes + sha256 for the manifest.
sha_universal=$(shasum -a 256 "$STAGE/InteractPro.apk" | awk '{print $1}')
size_universal=$(stat -f%z "$STAGE/InteractPro.apk")
sha_arm64=""; size_arm64=0
sha_arm=""; size_arm=0
if [ -f "$STAGE/InteractPro-arm64.apk" ]; then
  sha_arm64=$(shasum -a 256 "$STAGE/InteractPro-arm64.apk" | awk '{print $1}')
  size_arm64=$(stat -f%z "$STAGE/InteractPro-arm64.apk")
fi
if [ -f "$STAGE/InteractPro-arm.apk" ]; then
  sha_arm=$(shasum -a 256 "$STAGE/InteractPro-arm.apk" | awk '{print $1}')
  size_arm=$(stat -f%z "$STAGE/InteractPro-arm.apk")
fi

# ── Manifest ────────────────────────────────────────────────────
RELEASED_AT=$(date -u +%FT%TZ)
cat > "$STAGE/version.json" <<JSON
{
  "version":      "$VERSION_NAME",
  "build":        $NEW_BUILD,
  "released_at":  "$RELEASED_AT",
  "channel":      "public",
  "url_universal": "$PUBLIC_BASE/InteractPro.apk",
  "url_arm64":    "$PUBLIC_BASE/InteractPro-arm64.apk",
  "url_arm":      "$PUBLIC_BASE/InteractPro-arm.apk",
  "size_universal": $size_universal,
  "size_arm64":   $size_arm64,
  "size_arm":     $size_arm,
  "sha256_universal": "$sha_universal",
  "sha256_arm64": "$sha_arm64",
  "sha256_arm":   "$sha_arm"
}
JSON

# ── Upload ──────────────────────────────────────────────────────
echo "→ scp $(ls -1 $STAGE | wc -l | xargs) files to ${SSH_HOST}:${VPS_DEST}/"
scp "$STAGE"/* "$SSH_HOST":/tmp/pro-deploy/  2>/dev/null || {
  ssh "$SSH_HOST" 'mkdir -p /tmp/pro-deploy'
  scp "$STAGE"/* "$SSH_HOST":/tmp/pro-deploy/
}

ssh -t "$SSH_HOST" "sudo install -m 0644 /tmp/pro-deploy/* ${VPS_DEST}/ && sudo ls -la ${VPS_DEST}/"

# ── Verify ──────────────────────────────────────────────────────
echo ""
echo "→ Public reachability check:"
for path in InteractPro.apk InteractPro-arm64.apk InteractPro-arm.apk version.json; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$PUBLIC_BASE/$path" || echo 000)
  echo "   $code  $PUBLIC_BASE/$path"
done

echo ""
echo "→ /api/version (Pro update checker — should reflect $VERSION_NAME+$NEW_BUILD):"
curl -sS "$PUBLIC_BASE/api/version" | head -c 400 ; echo

echo ""
echo "DONE. Version $VERSION_NAME+$NEW_BUILD published at:"
echo "  $PUBLIC_BASE/InteractPro.apk"
echo "  $PUBLIC_BASE/InteractPro-arm64.apk"
echo ""
echo "Sony Bravia install command (after adb connect 192.168.100.4:5555):"
echo "  adb -s 192.168.100.4:5555 install -r $STAGE/InteractPro-arm64.apk"
