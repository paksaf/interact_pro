#!/usr/bin/env bash
#
# debug-phone-cast.sh — capture an adb logcat trace of a failed
# "Send to Device" / LAN cast attempt from one phone to another (or
# phone → TV). Saves the filtered log to /tmp/cast-debug-<timestamp>.log
# so you can paste it back without scrolling through pages of unrelated
# Android noise.
#
# Prereqs (one-time):
#   1. Install adb on Mac:    brew install --cask android-platform-tools
#   2. On the phone:          Settings → About phone → tap "Build number" 7 times
#                             → unlocks Developer Options
#   3. Developer Options:     enable "USB debugging"  AND  "Wireless debugging"
#
# Usage:
#   bash scripts/debug-phone-cast.sh             # USB-connected phone
#   bash scripts/debug-phone-cast.sh wireless    # phone on same Wi-Fi (slightly slower)

set -euo pipefail

MODE="${1:-usb}"
LOG_FILE="/tmp/cast-debug-$(date +%Y%m%d-%H%M%S).log"

# Verify adb exists
if ! command -v adb >/dev/null 2>&1; then
  echo "✗ adb not installed. Run: brew install --cask android-platform-tools"
  exit 1
fi

# Connect mode
if [ "$MODE" = "wireless" ]; then
  echo "Wireless ADB pairing:"
  echo "  1. On the phone: Settings → System → Developer options → Wireless debugging"
  echo "  2. Tap 'Pair device with pairing code' — phone shows IP:PORT + 6-digit code"
  read -rp "Phone IP:PORT (e.g. 192.168.1.42:37251): " PHONE_PAIR
  read -rp "6-digit pairing code: " PAIR_CODE
  adb pair "$PHONE_PAIR" "$PAIR_CODE"
  echo
  echo "Now the IP:PORT shown in the main 'Wireless debugging' screen (not pair):"
  read -rp "Phone IP:PORT for connect: " PHONE_CONN
  adb connect "$PHONE_CONN"
  DEVICE="$PHONE_CONN"
else
  echo "Plug the phone into the Mac via USB."
  echo "When the phone shows 'Allow USB debugging?' tap Allow."
  read -rp "Press Enter once connected..."
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [ -z "$DEVICE" ]; then
    echo "✗ No device detected. Check the USB cable supports data (some are charge-only)."
    exit 1
  fi
fi

echo
echo "✓ Connected to $DEVICE"
echo

# Confirm the app is installed
if ! adb -s "$DEVICE" shell pm list packages | grep -q com.interactpak.interactpro; then
  echo "✗ Interact Pro is not installed on this device. Install the APK first."
  exit 1
fi

# Clear any stale logs so we capture a clean trace
adb -s "$DEVICE" logcat -c

cat <<INSTRUCTIONS

────────────────────────────────────────────────────────────────────
NOW REPRODUCE THE CAST FAILURE on your phone:

  1. Open Interact Pro
  2. Open a PDF
  3. Tap the share icon → "Send to Device"
  4. Try to pair / cast to your TV (or other phone)
  5. Wait for the failure to appear (TLS handshake error, "no devices found",
     or pairing dialog freeze)

Capturing logs to:  $LOG_FILE
Press Ctrl+C in this terminal once you see the failure on the phone.
────────────────────────────────────────────────────────────────────

INSTRUCTIONS

# Filtered logcat — narrowly scoped to:
#   - Interact Pro app (package: com.interactpak.interactpro)
#   - mDNS / NSD / Bonsoir (LAN device discovery)
#   - Wi-Fi P2P / Wi-Fi Direct (peer pairing)
#   - TLS handshake errors during cast pairing
#   - Samsung's share stack (QuickShare / ShareStar / Smart View) — these
#     fire when the user tapped Android's system share instead of Pro's
#     own "Send to Device" button, and seeing them tells us the wrong
#     entry point was used
#   - Crashes (FATAL / AndroidRuntime)
#
# Updated 2026-05-11 — old filter used "interact_pro" with underscore
# which never matched the real package name; also caught false positives
# like "Pair{...}" structs from WindowManager and "broadcast" from
# ActivityManager. New filter is tighter.
adb -s "$DEVICE" logcat -v time \
  | grep -iE "interactpro|interactpak|com\.interactpak|NsdManager|NsdService|mdnsd|mDNSResponder|bonsoir|WifiP2p|WifiDirect|wifi_direct|SSLHandshake|TrustManager|x509|CertificateException|QuickShare|ShareStar|SmartView|share_plugin|MethodChannel.*cast|MethodChannel.*share|FATAL|AndroidRuntime" \
  | tee "$LOG_FILE"
