#!/usr/bin/env bash
#
# build-and-upload.sh — produce Interact Pro distributables and ship
# them to BOTH download endpoints in one command:
#
#   1. downloads.interactpak.com/interactpro/  — Hetzner Webhosting S
#      at 157.90.191.190. Apache vhost. Path matches the prepared
#      `server/downloads-site/apache.conf.snippet` (no hyphen). Same
#      FTP account every other INTERACT app uses.
#
#   2. pro.interactpak.com/  — Hetzner VPS at 178.105.73.238 (rsync
#      over SSH). Caddy block already in place; serves /var/www/interactpro/
#      at the root path with proper APK / plist MIME types. Files end
#      up directly under https://pro.interactpak.com/<filename>.
#
# Both targets serve the same files; either URL works. Failure on one
# is non-fatal — the script prints a warning and continues so a
# pro.* DNS hiccup doesn't block the public-facing downloads.* push.
#
# Run this from the project root:
#
#   bash scripts/build-and-upload.sh                     # all platforms
#   bash scripts/build-and-upload.sh --android-only      # APK + AAB only
#   bash scripts/build-and-upload.sh --skip-pro          # only downloads.*
#   bash scripts/build-and-upload.sh --skip-downloads    # only pro.*
#   bash scripts/build-and-upload.sh --no-build          # upload prebuilt
#
# Required tools (installed on your Mac, NOT on the VPS):
#   • flutter, dart       — for build:apk / build:appbundle / build:ios
#   • lftp                — for FTP upload to Webhosting (`brew install lftp`)
#   • rsync, ssh          — for the VPS push
#   • Apple Developer cert + provisioning profile (only if iOS builds)
#
# Required secrets (in `.env.local` at project root, gitignored):
#   HETZNER_FTP_HOST        — defaults to 9rkp.your-vhost.de
#   HETZNER_FTP_USER        — defaults to zrkpsy
#   HETZNER_FTP_PASS        — REQUIRED, no default
#   PRO_VPS_HOST            — defaults to 178.105.73.238
#   PRO_VPS_USER            — defaults to root
#   PRO_VPS_KEY             — path to SSH private key, defaults to ~/.ssh/interactpak
#
# Build defines that get baked in (see core/config/api_config.dart):
# All come from `dart_defines.json` at the project root (gitignored,
# already populated with real values). Edit that file, not this one.
# Convention matches every other build command in the project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# ─── Args ────────────────────────────────────────────────────────────
ANDROID_ONLY=false
IOS_ONLY=false
SKIP_PRO=false
SKIP_DOWNLOADS=false
NO_BUILD=false
# IOS_MODE values:
#   "appstore"   — flutter build ipa with App Store distribution
#                  signing. Default. Requires the project's
#                  DEVELOPMENT_TEAM to be a paid Apple Developer
#                  Program account this Mac is signed in to.
#   "dev"        — flutter build ipa --export-options-plist
#                  ios/ExportOptions-development.plist. Personal
#                  team. Installs only on registered devices, expires
#                  in 7 days. Good for testing on your own iPhone.
#   "unsigned"   — flutter build ios --no-codesign, then we hand-zip
#                  a Payload/Runner.app/ structure into an IPA. End
#                  users re-sign on their own Mac/PC via Sideloadly
#                  or AltStore using their own free Apple ID.
IOS_MODE="appstore"

for arg in "$@"; do
  case "$arg" in
    --android-only) ANDROID_ONLY=true ;;
    --ios-only) IOS_ONLY=true ;;
    --ios-dev) IOS_ONLY=true; IOS_MODE="dev" ;;
    --ios-unsigned) IOS_ONLY=true; IOS_MODE="unsigned" ;;
    --skip-pro) SKIP_PRO=true ;;
    --skip-downloads) SKIP_DOWNLOADS=true ;;
    --no-build) NO_BUILD=true ;;
    -h|--help)
      sed -n '3,55p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg (try --help)"; exit 2 ;;
  esac
done

# ─── Env ─────────────────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/.env.local" ]; then
  # shellcheck disable=SC2046
  export $(grep -E '^(HETZNER_FTP|PRO_VPS|PRO_SSH_ALIAS|AUTH_BASE_URL|DEEPSEEK)' \
    "$PROJECT_DIR/.env.local" | xargs)
fi

FTP_HOST="${HETZNER_FTP_HOST:-www682.your-server.de}"
FTP_USER="${HETZNER_FTP_USER:-zrkpsy}"
FTP_PASS="${HETZNER_FTP_PASS:-}"

# SSH access to the VPS. Prefer an alias from ~/.ssh/config (so the
# user's existing `ssh interact` muscle-memory just works), and fall
# back to explicit IP + user + key only when no alias is configured.
# `PRO_SSH_ALIAS=interact` in .env.local is all that's usually needed.
PRO_ALIAS="${PRO_SSH_ALIAS:-}"
PRO_HOST="${PRO_VPS_HOST:-178.105.73.238}"
PRO_USER="${PRO_VPS_USER:-root}"
PRO_KEY="${PRO_VPS_KEY:-$HOME/.ssh/interactpak}"

# Resolve the actual SSH target string + ssh/rsync flag set we'll use.
if [ -n "$PRO_ALIAS" ]; then
  # Alias path — defer everything (host, user, key, port) to ~/.ssh/config.
  PRO_SSH_TARGET="$PRO_ALIAS"
  PRO_SSH_OPTS=()
  PRO_RSYNC_E=()
elif [ -f "$PRO_KEY" ]; then
  PRO_SSH_TARGET="$PRO_USER@$PRO_HOST"
  PRO_SSH_OPTS=(-i "$PRO_KEY" -o "StrictHostKeyChecking=accept-new")
  PRO_RSYNC_E=(-e "ssh -i $PRO_KEY -o StrictHostKeyChecking=accept-new")
else
  # Neither alias nor key — pro.* push will be skipped at runtime
  # with a clear warning. We still set values so the script doesn't
  # explode on unbound vars under `set -u`.
  PRO_SSH_TARGET=""
  PRO_SSH_OPTS=()
  PRO_RSYNC_E=()
fi

# ─── Stage dir ───────────────────────────────────────────────────────
# All built binaries land here first so the upload step doesn't have
# to know about Flutter's nested output paths. In --no-build mode we
# leave any existing staged files in place (they were copied here by
# the previous build); otherwise we wipe and rebuild.
STAGE="$PROJECT_DIR/build/dist"
if ! $NO_BUILD; then
  rm -rf "$STAGE"
fi
mkdir -p "$STAGE"

# In --no-build mode, also pull in the canonical Flutter outputs in
# case the previous run was run with --skip-pro / different flags and
# the stage was wiped without a follow-up upload. This makes
# `--no-build` mean "use whatever the latest `flutter build` produced",
# not "use whatever's in the stage dir".
if $NO_BUILD; then
  if [ -f build/app/outputs/flutter-apk/app-release.apk ]; then
    cp build/app/outputs/flutter-apk/app-release.apk \
       "$STAGE/InteractPro.apk"
  fi
  if [ -f build/app/outputs/bundle/release/app-release.aab ]; then
    cp build/app/outputs/bundle/release/app-release.aab \
       "$STAGE/InteractPro.aab"
  fi
  for ipa in build/ios/ipa/*.ipa; do
    [ -f "$ipa" ] && cp "$ipa" "$STAGE/InteractPro.ipa" && break
  done
fi

VERSION="$(grep -E '^version:' pubspec.yaml | awk '{print $2}')"
echo "=== Interact Pro $VERSION ==="
echo

# ─── Build ───────────────────────────────────────────────────────────
# Use the project's existing dart_defines.json convention rather than
# passing inline --dart-define flags. dart_defines.json is gitignored,
# already contains DEEPSEEK_PROXY_URL / APP_TRANSLATE_TOKEN /
# GOOGLE_WEB_CLIENT_ID values, and is what `flutter run` and the user's
# muscle-memory build commands already point at.
DEFINES_FILE="$PROJECT_DIR/dart_defines.json"
if [ ! -f "$DEFINES_FILE" ]; then
  echo "WARN: $DEFINES_FILE not found — copying from dart_defines.example.json."
  echo "      Edit it to fill in DEEPSEEK_API_KEY / APP_TRANSLATE_TOKEN."
  cp "$PROJECT_DIR/dart_defines.example.json" "$DEFINES_FILE"
fi

# ─── Preflight: refuse to ship without the AI secret ────────────────
# An empty INTERACT_PRO_AI_SECRET ships an APK whose BookViewer shows
# "This build doesn't have the AI secret baked in" and silently falls
# back to Tesseract OCR + no karaoke. This was the root cause of the
# 2026-05-20 user-reported bug batch (issues #248-#258). Refuse to
# build unless the secret is present, with a one-line fix command.
if command -v jq >/dev/null 2>&1; then
  AI_SECRET_VAL="$(jq -r '.INTERACT_PRO_AI_SECRET // ""' "$DEFINES_FILE")"
else
  # Fallback: python3 is on every dev machine that has flutter
  AI_SECRET_VAL="$(python3 -c "import json; print(json.load(open('$DEFINES_FILE')).get('INTERACT_PRO_AI_SECRET',''))" 2>/dev/null || true)"
fi
if [ -z "$AI_SECRET_VAL" ]; then
  echo
  echo "❌ INTERACT_PRO_AI_SECRET is empty in $DEFINES_FILE."
  echo
  echo "   Shipping this APK would break read-aloud + advanced OCR + karaoke."
  echo "   Fix in one command:"
  echo
  echo "       bash scripts/bake-ai-secret.sh"
  echo
  echo "   Then re-run this script. To explicitly override (NOT recommended),"
  echo "   set ALLOW_MISSING_AI_SECRET=1 and run again."
  if [ "${ALLOW_MISSING_AI_SECRET:-0}" != "1" ]; then
    exit 1
  fi
  echo "   ⚠ ALLOW_MISSING_AI_SECRET=1 set — proceeding without secret."
fi

build_android() {
  # Warn loudly if no permanent release keystore is configured. Without
  # one, build.gradle.kts falls back to the debug keystore which is
  # auto-regenerated by the SDK and changes whenever Android Studio
  # updates — silently breaking upgrade-installs on every device that
  # already has the previous APK. Run scripts/create-release-keystore.sh
  # once to set this up; from then on every build is signed with the
  # same stable cert and upgrades work forever.
  if [ ! -f "$PROJECT_DIR/android/key.properties" ]; then
    echo
    echo "⚠⚠⚠ NO RELEASE KEYSTORE CONFIGURED ⚠⚠⚠"
    echo "Building with debug keystore. Existing installs will refuse"
    echo "to upgrade if your debug.keystore changed since the last build"
    echo "(typical after an Android Studio update)."
    echo "Fix permanently: bash scripts/create-release-keystore.sh"
    echo
    sleep 3
  fi


  # macOS extended attributes on the bundled fonts (especially the Apple
  # system fonts copied from /Library/Fonts/) periodically reappear after
  # an iCloud Drive sync or a finder re-touch and break Flutter's asset
  # bundler with `errno 93 ENOATTR`. Strip recursively before every build
  # — fast and idempotent, no harm if there's nothing to strip.
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr assets/ 2>/dev/null || true
  fi

  # Regenerate launcher icons + native splash whenever the source PNGs
  # under assets/icon/ are newer than the generated mipmap launcher PNG.
  # Without this hook, swapping the brand artwork in
  # assets/icon/icon.png leaves the OLD icon baked into every APK
  # because flutter_launcher_icons is a manual `dart run` step the user
  # always forgets. Idempotent and fast (<5 s) when up-to-date.
  local SRC_ICON="$PROJECT_DIR/assets/icon/icon.png"
  local GEN_ICON="$PROJECT_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"
  if [ -f "$SRC_ICON" ] && \
     { [ ! -f "$GEN_ICON" ] || [ "$SRC_ICON" -nt "$GEN_ICON" ]; }; then
    echo "→ Source icon newer than generated — regenerating launcher icons"
    dart run flutter_launcher_icons || \
      echo "  ⚠ flutter_launcher_icons failed — continuing with stale icons"
  fi
  local SRC_SPLASH="$PROJECT_DIR/assets/splash/splash_logo.png"
  local GEN_SPLASH="$PROJECT_DIR/android/app/src/main/res/drawable-xxxhdpi/splash.png"
  if [ -f "$SRC_SPLASH" ] && \
     { [ ! -f "$GEN_SPLASH" ] || [ "$SRC_SPLASH" -nt "$GEN_SPLASH" ]; }; then
    echo "→ Splash source updated — regenerating native splash"
    dart run flutter_native_splash:create || \
      echo "  ⚠ flutter_native_splash failed — continuing with stale splash"
  fi

  # --no-tree-shake-icons is required because we load icons from a
  # non-constant in voice_command_button.dart's command map (Material
  # IconData looked up by string). Without the flag the Flutter font
  # tree-shaker rejects the build with a "non-constant IconData"
  # error during APK + AAB compilation. Adds ~150 KB but unavoidable
  # while we have dynamic icon lookups in the voice command palette.
  echo "→ Building Android APK (dart-defines from $DEFINES_FILE)"
  flutter build apk --release \
    --no-tree-shake-icons \
    --dart-define-from-file="$DEFINES_FILE"

  cp build/app/outputs/flutter-apk/app-release.apk \
     "$STAGE/InteractPro.apk"

  # AAB is best-effort. It's only needed for Play Store submission, not
  # for direct-install distribution which is what our download URLs do.
  # The strip-debug-symbols step on AAB has tripped on NDK / toolchain
  # version mismatches in the past; we let it fail loudly without
  # blocking the APK upload. Same --no-tree-shake-icons rationale
  # applies as above.
  echo "→ Building Android AAB (best-effort)"
  if flutter build appbundle --release \
       --no-tree-shake-icons \
       --dart-define-from-file="$DEFINES_FILE"; then
    if [ -f "build/app/outputs/bundle/release/app-release.aab" ]; then
      cp build/app/outputs/bundle/release/app-release.aab \
         "$STAGE/InteractPro.aab"
      echo "  ✓ AAB built and staged"
    fi
  else
    echo "  ⚠ AAB build failed — continuing with APK-only upload."
    echo "    To fix: see 'NDK toolchain' note in BUILD_AND_RELEASE.md"
  fi
}

build_ios() {
  case "$IOS_MODE" in
    appstore)
      echo "→ Building iOS IPA (App Store distribution)"
      flutter build ipa --release \
        --dart-define-from-file="$DEFINES_FILE"
      cp build/ios/ipa/*.ipa "$STAGE/InteractPro.ipa" 2>/dev/null || \
        echo "  (no IPA produced — App Store provisioning profile not found." \
             "Try --ios-dev or --ios-unsigned for manual install paths.)"
      ;;
    dev)
      echo "→ Building iOS IPA (development — personal team, registered devices only)"
      flutter build ipa --release \
        --dart-define-from-file="$DEFINES_FILE" \
        --export-options-plist="$PROJECT_DIR/ios/ExportOptions-development.plist"
      cp build/ios/ipa/*.ipa "$STAGE/InteractPro.ipa" 2>/dev/null || \
        echo "  (no IPA produced — make sure your iPhone has been plugged" \
             "into this Mac at least once with Developer Mode enabled.)"
      ;;
    unsigned)
      # Build the .app without code signing. flutter build ios produces
      # build/ios/iphoneos/Runner.app — we hand-package it as an IPA by
      # creating a Payload/ folder and zipping it. Sideloadly / AltStore
      # accept this format and re-sign at install time using whatever
      # Apple ID the end user is signed into.
      echo "→ Building iOS .app (unsigned — for Sideloadly/AltStore distribution)"
      flutter build ios --release --no-codesign \
        --dart-define-from-file="$DEFINES_FILE"

      local APP_PATH="$PROJECT_DIR/build/ios/iphoneos/Runner.app"
      if [ ! -d "$APP_PATH" ]; then
        echo "  ✗ Runner.app not found at $APP_PATH — flutter build failed?"
        return 1
      fi

      # Strip simulator-only architectures (arm64 simulator slices) from
      # frameworks. Without this, App Store would reject — but Sideloadly
      # also chokes on fat binaries that include simulator archs. Best
      # effort; failures here are non-fatal.
      echo "  • Cleaning simulator slices from frameworks"
      find "$APP_PATH/Frameworks" -name '*.framework' -type d 2>/dev/null | while read -r fw; do
        local bin
        bin="$fw/$(basename "${fw%.framework}")"
        if [ -f "$bin" ] && lipo -info "$bin" 2>/dev/null | grep -q x86_64; then
          lipo -remove x86_64 "$bin" -output "$bin" 2>/dev/null || true
        fi
      done

      local TMP_PAYLOAD
      TMP_PAYLOAD=$(mktemp -d "${TMPDIR:-/tmp}/interactpro-ipa.XXXXXX")
      mkdir -p "$TMP_PAYLOAD/Payload"
      cp -R "$APP_PATH" "$TMP_PAYLOAD/Payload/"
      ( cd "$TMP_PAYLOAD" && zip -qry "$STAGE/InteractPro.ipa" Payload )
      rm -rf "$TMP_PAYLOAD"
      echo "  ✓ Unsigned IPA: $STAGE/InteractPro.ipa"
      echo "    End-user install: Sideloadly (Mac/PC) or AltStore (Mac/PC)."
      echo "    See landing-page card on https://pro.interactpak.com/ for steps."
      ;;
    *)
      echo "  ✗ Unknown IOS_MODE: $IOS_MODE"
      return 1
      ;;
  esac
}

if ! $NO_BUILD; then
  if $IOS_ONLY; then
    build_ios
  elif $ANDROID_ONLY; then
    build_android
  else
    build_android
    # iOS build is best-effort: most CI environments don't have signing
    # set up. Fall through silently if it errors.
    if ! build_ios; then
      echo "  (iOS build failed — continuing with Android-only upload)"
    fi
  fi
else
  echo "→ Skipping build (--no-build); reusing $STAGE/"
fi

echo
echo "Staged binaries:"
ls -lh "$STAGE" 2>/dev/null || { echo "  (none — nothing to upload)"; exit 1; }
echo

# ─── Upload to downloads.interactpak.com ────────────────────────────
upload_downloads() {
  if [ -z "$FTP_PASS" ]; then
    echo "WARN: HETZNER_FTP_PASS not set — skipping downloads.interactpak.com"
    return 0
  fi

  local LFTP_SCRIPT
  LFTP_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/interactpro-lftp.XXXXXX")"
  trap 'rm -f "$LFTP_SCRIPT"' RETURN

  {
    # Hetzner Webhosting now mandates FTPS — plain FTP control channels
    # are rejected with "550 SSL/TLS required". These three lines turn
    # on TLS for both control and data, and force-fail (no fall-back to
    # cleartext) so a misconfiguration surfaces loudly instead of
    # leaking the password in the clear.
    echo "set ftp:ssl-allow yes"
    echo "set ftp:ssl-force yes"
    echo "set ftp:ssl-protect-data yes"
    echo "set ssl:verify-certificate yes"
    echo "set net:max-retries 2"
    echo "set net:reconnect-interval-base 5"
    echo "open -u \"$FTP_USER\",\"$FTP_PASS\" \"$FTP_HOST\""
    echo "mkdir -p -f /public_html/downloads/interactpro"
    echo "cd /public_html/downloads/interactpro"
    for f in "$STAGE"/*; do
      [ -f "$f" ] || continue
      echo "put -O . \"$f\""
    done
    echo "bye"
  } > "$LFTP_SCRIPT"

  echo "→ Uploading to downloads.interactpak.com/interactpro/"
  if lftp -f "$LFTP_SCRIPT"; then
    echo "  ✓ downloads.interactpak.com push complete"
  else
    echo "  ✗ FTP upload failed — see error above"
    return 1
  fi
}

# ─── Upload to pro.interactpak.com (VPS) ────────────────────────────
# Path matches the user's existing Caddy block:
#
#   pro.interactpak.com {
#       encode zstd gzip
#       root * /var/www/interactpro
#       file_server
#       @apk path *.apk
#       header @apk Content-Type application/vnd.android.package-archive
#       @plist path *.plist
#       header @plist Content-Type application/xml
#   }
#
# So binaries go to /var/www/interactpro/ at the root and resolve
# directly under https://pro.interactpak.com/<filename> — no /downloads
# prefix.
upload_pro() {
  if [ -z "$PRO_SSH_TARGET" ]; then
    echo "WARN: No SSH target for the VPS (set PRO_SSH_ALIAS=interact in"
    echo "      .env.local, OR install a key at $PRO_KEY) — skipping pro.*"
    return 0
  fi

  local REMOTE_DIR="/var/www/interactpro"
  echo "→ Uploading to pro.interactpak.com via ssh $PRO_SSH_TARGET"
  ssh "${PRO_SSH_OPTS[@]}" "$PRO_SSH_TARGET" \
      "mkdir -p $REMOTE_DIR && chown -R caddy:caddy $REMOTE_DIR 2>/dev/null || true"
  if rsync -avz --progress \
       "${PRO_RSYNC_E[@]}" \
       "$STAGE/" \
       "$PRO_SSH_TARGET:$REMOTE_DIR/"; then
    echo "  ✓ pro.interactpak.com binaries push complete"
  else
    echo "  ✗ rsync failed — see error above"
    return 1
  fi

  # Also ship the landing page itself (index.html). It self-updates the
  # version badge from /api/version on each load, but the HTML/CSS still
  # needs to land on the VPS once after each edit. Without this, every
  # deploy would still show the FIRST-EVER landing page even after the
  # APK is replaced. Pushed as a separate rsync so an HTML-only change
  # can be deployed without rebuilding the APK.
  local SITE_DIR="$PROJECT_DIR/server/downloads-site"
  if [ -f "$SITE_DIR/index.html" ]; then
    echo "→ Syncing landing page (index.html) to $REMOTE_DIR/"
    if rsync -avz "${PRO_RSYNC_E[@]}" \
         "$SITE_DIR/index.html" \
         "$PRO_SSH_TARGET:$REMOTE_DIR/index.html"; then
      echo "  ✓ landing page updated"
    else
      echo "  ✗ landing page rsync failed (binaries did upload OK)"
    fi
  fi

  # Push version.json to the pro-api so /api/version returns the new
  # build immediately. The landing page reads this on load (badge +
  # cache-busted APK link), AND the in-app UpdateBanner pings the same
  # endpoint on launch to detect stale installs. Both stay in sync
  # without any manual editing because we derive everything from the
  # canonical pubspec.yaml that flutter just built against.
  #
  # Shape matches what server/pro-api/index.js → /api/version returns
  # by reading version.json: { version, build, latest, apkUrl }.
  local VER_NUM="${VERSION%+*}"
  local BUILD_NUM="${VERSION#*+}"
  if [ "$BUILD_NUM" = "$VERSION" ]; then BUILD_NUM=1; fi
  local VERSION_JSON
  VERSION_JSON=$(cat <<EOF
{
  "version": "$VER_NUM",
  "build": $BUILD_NUM,
  "latest": "$VER_NUM+$BUILD_NUM",
  "apkUrl": "https://pro.interactpak.com/InteractPro.apk",
  "downloadUrl": "https://pro.interactpak.com/InteractPro.apk",
  "releasedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
  echo "→ Updating /api/version manifest (v$VER_NUM build $BUILD_NUM)"
  if ssh "${PRO_SSH_OPTS[@]}" "$PRO_SSH_TARGET" \
       "cat > /opt/interact/pro-api/version.json && chown interact:interact /opt/interact/pro-api/version.json 2>/dev/null || true" \
       <<<"$VERSION_JSON"; then
    echo "  ✓ version.json updated"
  else
    echo "  ✗ version.json push failed"
  fi
}

if ! $SKIP_DOWNLOADS; then upload_downloads || true; fi
if ! $SKIP_PRO; then upload_pro || true; fi

echo
echo "=== Done ==="
echo "  https://downloads.interactpak.com/interactpro/InteractPro.apk"
echo "  https://pro.interactpak.com/InteractPro.apk"
