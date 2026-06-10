#!/usr/bin/env bash
#
# debug-phone-handwriting.sh — capture the adb logcat trace of a failed
# non-English handwriting model download. ML Kit Digital Ink loads its
# language packs from Google's CDN on demand; English usually works,
# other languages have been timing out.
#
# Saves filtered output to /tmp/handwriting-debug-<timestamp>.log.
#
# Usage:
#   bash scripts/debug-phone-handwriting.sh             # USB
#   bash scripts/debug-phone-handwriting.sh wireless    # Wi-Fi

set -euo pipefail

MODE="${1:-usb}"
LOG_FILE="/tmp/handwriting-debug-$(date +%Y%m%d-%H%M%S).log"

if ! command -v adb >/dev/null 2>&1; then
  echo "✗ adb not installed. Run: brew install --cask android-platform-tools"
  exit 1
fi

if [ "$MODE" = "wireless" ]; then
  read -rp "Phone IP:PORT for connect (Wireless debugging screen): " PHONE_CONN
  adb connect "$PHONE_CONN"
  DEVICE="$PHONE_CONN"
else
  echo "Plug the phone into the Mac via USB. Press Enter when connected..."
  read -r
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [ -z "$DEVICE" ]; then
    echo "✗ No device detected."
    exit 1
  fi
fi

echo "✓ Connected to $DEVICE"

if ! adb -s "$DEVICE" shell pm list packages | grep -q com.interactpak.interactpro; then
  echo "✗ Interact Pro is not installed on this device."
  exit 1
fi

# Force-stop the app so the model registry starts clean
adb -s "$DEVICE" shell am force-stop com.interactpak.interactpro
adb -s "$DEVICE" logcat -c

cat <<INSTRUCTIONS

────────────────────────────────────────────────────────────────────
NOW REPRODUCE THE HANDWRITING DOWNLOAD FAILURE:

  1. Open Interact Pro (it just got force-stopped, so cold launch)
  2. Open any PDF
  3. Open the Handwriting tool
  4. Pick a non-English language (Urdu / Arabic / Chinese — whichever
     was failing before)
  5. Wait for the model download. Note the timeout / error.

Capturing logs to:  $LOG_FILE
Press Ctrl+C once the failure appears.
────────────────────────────────────────────────────────────────────

INSTRUCTIONS

adb -s "$DEVICE" logcat -v time \
  | grep -iE "handwrit|mlkit|digitalink|model|RemoteModelManager|gms.mlkit|download|ConnectivityManager|HostnameVerifier|SSLHandshakeException|interact_pro|FATAL|AndroidRuntime" \
  | tee "$LOG_FILE"
