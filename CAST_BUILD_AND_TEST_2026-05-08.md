# Interact Pro — LAN Cast Build + Test Runbook

**Date:** 2026-05-08
**Goal:** rebuild the APK with the new LAN cast feature, install on a phone + a TV, pair them once, then share a photo from Samsung Gallery and watch it appear on the TV.

This runbook ends when you've successfully shared a file phone→TV.

---

## What's new in this build

Files changed (already on disk in your `interact_pro/` repo):

```
lib/main.dart                                       ← landscape on TV/tablet
android/app/src/main/AndroidManifest.xml            ← share-sheet image/video/text
lib/core/storage/app_paths.dart                     ← incomingDir + incomingPathFor()
lib/features/lan/data/lan_server.dart               ← /receive ?kind= + IncomingShare events
lib/features/lan/data/lan_repository.dart           ← send() takes kind+filename, exposes incomingSharesProvider
lib/features/lan/domain/entities.dart               ← ShareKind enum + IncomingShare model
lib/features/sharing/presentation/send_to_device_sheet.dart   ← NEW bottom-sheet picker
lib/core/sharing/incoming_file_listener.dart        ← stops ignoring non-PDFs; offers Send-to-TV; auto-opens received PDFs
```

No new pubspec dependencies — the existing `bonsoir`, `shelf`, `shelf_router`, `network_info_plus`, `crypto` cover it.

---

## Step 1 — Local sanity check (your Mac)

```bash
cd ~/Documents/INTERACT/interact_pro

# Refresh Dart deps in case anything's stale
flutter pub get

# Static analyser — should be clean. Warnings about unused imports OK; ERRORS not OK.
flutter analyze

# If analyze flags anything in the files above, paste the output to me; otherwise continue.
```

If `analyze` is clean, build the release APK:

```bash
# Universal APK (single ~80MB file, installs on every Android arch)
flutter build apk --release

# Or, smaller per-arch APKs (recommended for sideloading):
flutter build apk --release --split-per-abi
# Output:
#   build/app/outputs/flutter-apk/app-arm64-v8a-release.apk    (modern phones, modern TVs)
#   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk  (older phones)
#   build/app/outputs/flutter-apk/app-x86_64-release.apk       (emulator + some Fire TVs)
```

The arm64 APK is what you want for both the Samsung phone and a modern Smart TV.

---

## Step 2 — Sideload on the phone (Samsung)

### 2a. Enable Developer Mode on the phone (one-time)

Settings → About phone → Software information → tap **Build number** 7 times → enter PIN.

Then Settings → Developer options → **USB debugging** ON.

### 2b. Install the APK

Connect the phone to your Mac via USB. On the phone, tap "Allow USB debugging" when prompted.

```bash
# Confirm the phone is visible
adb devices
# Expected: one line with the device serial + "device" (not "unauthorized")

# Install (replaces any older Interact Pro)
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

If `adb` isn't installed: `brew install android-platform-tools`.

### 2c. Confirm new SEND filters are live on the phone

```bash
adb shell pm dump com.interactpak.interactpro | grep -A 4 "android.intent.action.SEND" | head -20
```
Expect to see `image/*`, `video/*`, `text/plain` and `application/pdf` listed. If only `application/pdf` is there, the rebuild didn't take — check that you're on the new APK (`adb shell dumpsys package com.interactpak.interactpro | grep versionName`).

---

## Step 3 — Sideload on the TV

The right method depends on what kind of TV you have:

### Android TV / Google TV / Fire TV (most modern smart TVs)

**Option A — adb over network (cleanest):**
1. On TV: Settings → Device Preferences → About → tap **Build** 7 times → Developer options → USB debugging + ADB debugging ON
2. Note the TV's IP from Settings → Network → Status
3. From your Mac:
   ```bash
   adb connect <TV-IP>:5555
   adb -s <TV-IP>:5555 install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
   ```
4. On TV the first install may show "Allow USB debugging from this computer" — accept

**Option B — sideload via Send Files to TV / X-Plore (no Mac needed):**
1. Install "Send Files to TV" on phone AND TV (free on Play Store / Aptoide TV)
2. Copy the APK from your Mac to the phone (`adb push`)
3. From phone: Send Files to TV → pick the APK → pick the TV → on TV, install

**Option C — USB stick:**
Copy APK to a USB stick → plug into TV → use a file manager (X-Plore, ES File Explorer) to navigate and install.

### Samsung Smart TV (Tizen)

Samsung Tizen TVs **do not run Android APKs**. You can't sideload Interact Pro to a Tizen TV. Workarounds:

- Use a Chromecast / Fire TV stick / Android TV box plugged into the Samsung TV's HDMI — install Interact Pro on the stick
- Or: skip the LAN cast feature on Samsung Tizen and use the existing Chromecast SystemCastService path (Samsung TVs support Chromecast/AirPlay reception out of the box)

If your TV is Tizen, tell me and I'll stub a Chromecast-only path that doesn't need an Interact Pro install on the TV side.

---

## Step 4 — Pair phone ↔ TV (one-time)

Both devices: open Interact Pro, sign in.

### On the TV
1. Open Interact Pro
2. Navigate to **Settings → Nearby Devices**
3. Leave this screen open — the TV is now broadcasting via mDNS

### On the phone
1. Open Interact Pro
2. **Settings → Nearby Devices**
3. Wait 5-10 seconds — under "Discovered on this Wi-Fi" you should see a row for the TV
   - If not: pull down to refresh; check both devices are on the **same Wi-Fi network** (not "guest" vs main); confirm the TV's name in `dns-sd -B _interactpro._tcp local` from your Mac
4. Tap **Pair** next to the TV row
5. Look at the TV — a 6-digit PIN is now showing on its Nearby Devices screen
6. Type the PIN on the phone → **Pair**
7. Snackbar: "Paired with <TV name>"

The pair persists across app restarts. You only do this once per phone+TV combo.

### Troubleshooting if discovery fails
- Same Wi-Fi: confirm with `adb shell dumpsys connectivity | grep -i ssid` on each device; some routers isolate IoT devices
- iOS local network permission (only matters on iPhone, not Samsung): Settings → Privacy → Local Network → Interact Pro ON
- Multicast: some routers strip mDNS — try a different SSID or the router's "client isolation" setting OFF
- From Mac on the same Wi-Fi: `dns-sd -B _interactpro._tcp local` — should list both devices within 5 seconds. If empty, the issue is the network not the app.

---

## Step 5 — Share a photo from phone to TV

Open Samsung Gallery on the phone:

1. Pick any photo
2. Tap **Share**
3. **Interact Pro should now appear in the bottom app row** — alongside WhatsApp, Drive, Quick Share, etc. If it doesn't appear:
   - Check the SEND filter check from step 2c
   - Force-stop Interact Pro, then re-share (Samsung caches the share-target list aggressively)
4. Tap **Interact Pro**
5. The phone opens to the receive screen briefly, then the **Send to Device** sheet pops up
6. Under "Paired" you should see the TV
7. Tap the TV row
8. Snackbar: "Sent to <TV name>"

### On the TV (within 1 second of step 8)

- Snackbar: "Received from <phone name>"
- The image lands in `incoming/<filename>.jpg` — but **the v1 of this feature only auto-routes PDFs to the viewer**. For images/videos, the file is on disk but you don't see it appear yet (image viewer is a follow-up).

To verify the image actually arrived on the TV, from your Mac:
```bash
adb -s <TV-IP>:5555 shell ls -la /storage/emulated/0/Android/data/com.interactpak.interactpro/files/incoming/
```

You should see a file matching the photo you shared, with the right byte count.

### To see PDFs auto-open on the TV (the most satisfying demo)

Repeat steps 1-7 but pick a **PDF** instead of a photo (e.g. tap-and-share a PDF from Files / Gmail). The TV will:
- Snackbar: "Received from <phone>"
- Auto-navigate to the PDF viewer
- Display the PDF full-screen

This is the demo to show the team. Photos/videos auto-open after the image/video viewer is built.

---

## Step 6 — Edge cases worth testing

| Test | Expected |
|---|---|
| Share a 50MB PDF | Sub-2-second transfer on Wi-Fi 5; viewer opens immediately |
| Share to TV when TV's app is in background | Snackbar still fires; nav happens when user opens the app — currently the snackbar fires only if the app is foregrounded. To make it work in background you'd need a notification — flag for follow-up. |
| Share from phone when TV is OFF | Phone shows "Could not connect" snackbar from `lanRepository.send()` — the TV isn't broadcasting mDNS when off. Pair status persists; next time TV is on, send works again. |
| Two phones share to same TV simultaneously | Both arrive; receiver UI navigates to whichever PDF was last (current viewer push behaviour). Good enough for v1. |
| Share a 500MB video | Will probably OOM the receiver — `_receive` buffers the full body in memory before writing. Flag for follow-up: switch to streaming `req.read().pipe(file.openWrite())`. |
| Share text from a browser | The receive folder gets a `.txt` file; no auto-open (no text viewer). User can find it via a file manager. |

---

## Step 7 — When something doesn't work

### "Pair" button does nothing on phone

- Check `adb logcat | grep -E "LAN|bonsoir"` while you tap. If you see `Could not start LAN discovery` it's likely iOS local-network perm (iOS only) or router multicast.
- Restart the LAN repo: in Settings → Nearby Devices, pull-to-refresh — it invalidates the provider and rebuilds the bonsoir client.

### Share goes through (snackbar on phone), nothing on TV

- Check the TV's logs: `adb -s <TV-IP>:5555 logcat | grep -E "IncomingShare|LAN"`
- If `IncomingShare:` line appears, the file arrived; only the auto-open didn't fire (PDF only in v1)
- If nothing on the TV side, the phone hit a stale IP; force-stop and reopen Interact Pro on the TV to re-broadcast mDNS

### `Bad signature` (HTTP 403) from the TV

Means the HMAC secret diverged between phone and TV. Unpair from both sides (Settings → Nearby Devices → tap paired device → Unpair), re-pair fresh.

### Cast button in PDF viewer also broken

That's the **other** cast path (Chromecast/AirPlay), not this one. They share the LAN server but use different endpoints. Won't be affected by this change unless `flutter_chrome_cast` regressed — see `lib/features/casting/CASTING.md` for that path.

---

## Follow-ups (intentionally NOT in v1)

1. **Image viewer + auto-route on receive.** Today PDFs auto-open; images sit in `incoming/`. Add `lib/features/image_viewer/` with a fullscreen `Image.file(...)` + zoom/pan. ~1 day.
2. **Video viewer.** Same as above with `video_player` package. ~1 day.
3. **Background notifications on TV.** When app is backgrounded on the TV but a paired phone pushes, post an Android notification so the user knows to reopen. ~half day.
4. **Streaming receive for large files.** Change `_receive` from `req.read().fold(...)` (buffers everything) to a streamed write. Required before shipping video sharing seriously. ~half day.
5. **TLS for public Wi-Fi.** Self-signed cert + cert-pinning per pair. Required if Sahulat or FleetOps lift this for slaughterhouse / depot use. ~2 days.
6. **Cross-app discovery.** Right now the service type is `_interactpro._tcp`. If we want a Sahulat phone to send to a generic INTERACT cast TV, change to `_interact._tcp` and add a per-app capability TXT field. ~half day.

---

## Reference

- [`_shared/docs/LAN_CAST_REUSE_2026-05-08.md`](../_shared/docs/LAN_CAST_REUSE_2026-05-08.md) — how Sahulat / FleetOps / Movento can lift this
- [`lib/features/casting/CASTING.md`](lib/features/casting/CASTING.md) — full cast architecture (LAN + Chromecast + AirPlay)
- [`INTERACT_PRO_FIXES_2026-05-08.md`](INTERACT_PRO_FIXES_2026-05-08.md) — the morning's diagnosis doc
