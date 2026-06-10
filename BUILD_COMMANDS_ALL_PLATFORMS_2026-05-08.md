# Interact Pro — Build Commands for Every Target

**Date:** 2026-05-08
**Scope:** Android (sideload APK + Play Store AAB) and iOS (App Store IPA + ad-hoc IPA + dev). Plus the existing Hetzner upload script that ships everything to `downloads.interactpak.com` in one shot.

This is the operator quick-reference. The deeper "what does each step do and why" lives in [`BUILD_AND_RELEASE.md`](./BUILD_AND_RELEASE.md). When in doubt, that's the canonical doc — this one is for when you already know what you want and need the command.

---

## 0. Prereqs (one-time)

Verify these once per machine. Skip if you've shipped from this Mac before.

```bash
# Flutter SDK + plumbing
flutter --version              # expect ≥ 3.19
flutter doctor -v              # every checkmark green; iOS section requires Xcode + CocoaPods + accepted licenses
flutter precache --android --ios

# Project deps fresh
cd /Users/muzafar/Documents/INTERACT/interact_pro
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs   # regenerates Drift / Riverpod codegen

# Android signing keystore exists (one-time):
ls -la ~/keys/interactpak-upload.jks            # if missing → see BUILD_AND_RELEASE.md "One-time prerequisites"
ls -la android/key.properties                   # gitignored; must point at the JKS above

# iOS signing wired:
open ios/Runner.xcworkspace                     # opens Xcode → Runner → Signing & Capabilities → Team selected, "Automatically manage signing" on
cd ios && pod install && cd ..                  # pulls Cast SDK + ML Kit + AirPlay deps; re-run after every pubspec change
```

If `flutter doctor` flags issues, fix those first — the build commands below assume a green doctor.

---

## 1. Android — sideload APK (test on phones / TVs / Fire TV)

The artifact you sideload during testing. Three flavours, pick one:

```bash
# A. Universal APK — single ~80 MB file installs on every Android arch.
#    Easiest for ad-hoc test distribution; biggest file size.
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk

# B. Per-arch split APKs — three smaller files (~30 MB each), one per ABI.
#    Best for sideloading on a specific device (TV is usually arm64-v8a).
flutter build apk --release --split-per-abi
# Output:
#   build/app/outputs/flutter-apk/app-arm64-v8a-release.apk          ← modern phones, modern Android TVs
#   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk        ← older phones (32-bit ARM)
#   build/app/outputs/flutter-apk/app-x86_64-release.apk             ← emulator + some Fire TVs

# C. Profile build — slower than release but with debug-print + DevTools attach.
#    Good when you suspect a release-only bug.
flutter build apk --profile --split-per-abi
```

### Sideload to a connected phone via USB

```bash
adb devices                                                               # confirm phone shows as "device"
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb logcat -s flutter                                                     # tail Flutter logs while you test
```

### Sideload to an Android TV via network (no USB)

```bash
# On the TV: Settings → Device Preferences → About → tap "Build" 7×
#            → Developer options → ADB debugging ON → note the IP.
adb connect 192.168.1.42:5555                                             # use your TV's IP
adb -s 192.168.1.42:5555 install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

---

## 2. Android — Play Store AAB (production release)

The bundle Google Play accepts. Required for new releases on Play; APKs are sideload-only since 2021.

```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
# Upload to Play Console → Internal testing / Closed / Open / Production track.
```

### Sanity-test the AAB on a real device first (Play Internal App Sharing)

```bash
# Or use bundletool to install the AAB directly on a USB-attached device.
brew install bundletool                                                    # one-time
bundletool build-apks \
  --bundle=build/app/outputs/bundle/release/app-release.aab \
  --output=/tmp/interactpro.apks \
  --connected-device                                                       # only generates for the connected device's ABI
bundletool install-apks --apks=/tmp/interactpro.apks
```

---

## 3. iOS — App Store IPA (production release)

Requires: Apple Developer Program ($99/year), Team ID `2NZD65G583` (Shazia Parveen account), bundle id `com.interactpak.interactPro`.

```bash
# Build the .ipa with App-Store distribution profile
flutter build ipa --release --export-method app-store
# Output: build/ios/ipa/interact_pro.ipa
#         build/ios/ipa/Runner.app  (the app bundle inside)
#         build/ios/ipa/manifest.plist  (download manifest for OTA, not used here)
```

### Upload to App Store Connect

```bash
# Method A — Apple's Transporter app (GUI). Drag the .ipa, sign in, upload.
open -a Transporter build/ios/ipa/interact_pro.ipa

# Method B — xcrun altool (CLI). Needs an app-specific password.
#   Create one: appleid.apple.com → Sign-In and Security → App-Specific Passwords → Generate
xcrun altool --upload-app -f build/ios/ipa/interact_pro.ipa \
  -t ios -u "your-apple-id@email.com" -p "abcd-efgh-ijkl-mnop"
```

After upload: App Store Connect → My Apps → Interact Pro → TestFlight tab → wait ~10 min for Apple's processing → invite testers, or submit to App Review.

---

## 4. iOS — ad-hoc IPA (test on specific devices, no App Store)

For when you want to install on a handful of test iPhones/iPads without going through TestFlight. Each device's UDID must be added to your Apple Developer provisioning profile first.

```bash
# Each tester's UDID has to be registered at:
#   developer.apple.com → Account → Devices → +
# Then regenerate the ad-hoc provisioning profile so it includes them.
flutter build ipa --release --export-method ad-hoc
# Output: build/ios/ipa/interact_pro.ipa  (signed for the UDIDs in the profile)
```

Distribute via:
- **Diawi** (`https://diawi.com`, free) — drag the .ipa, get a short URL, share with testers, they tap → Safari → install.
- **AirDrop the .ipa to a Mac running Apple Configurator 2** → install via USB.
- **TestFlight** — strictly speaking ad-hoc isn't required for TestFlight; just use the App Store flow above and add testers in TestFlight.

---

## 5. iOS — development build (run on YOUR own iPhone via USB)

Fastest iteration; rebuilds in seconds rather than minutes.

```bash
# Plug your iPhone via USB → trust the Mac when prompted.
flutter devices                                              # confirm your iPhone shows up
flutter run --release -d <DEVICE_ID_FROM_LIST>
# Or for hot-reload-friendly debug:
flutter run -d <DEVICE_ID_FROM_LIST>
```

If signing fails: open `ios/Runner.xcworkspace` in Xcode, select Runner → Signing & Capabilities → re-pick Team → close Xcode → re-run `flutter run`.

---

## 6. The one-command release (does everything above + uploads)

Already exists — `interact_pro/scripts/build-and-upload.sh`. Reads `dart_defines.json` for build-time secrets, builds the APK + AAB + IPA, ships them to `downloads.interactpak.com` (Hetzner Webhosting S) and the parallel mirror at `pro.interactpak.com`.

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro
bash scripts/build-and-upload.sh
```

Prereqs:
- Android signing config done (Step 0)
- `HETZNER_FTP_HOST` / `HETZNER_FTP_USER` / `HETZNER_FTP_PASS` in `.env.local`
- iOS signing wired in Xcode

The script's source is your authoritative source for "what gets built and where it goes" if you ever need to debug or replicate elsewhere.

---

## 7. After the build — what gets distributed where

| Artifact | Goes to | Used by |
|---|---|---|
| `app-arm64-v8a-release.apk` | `https://downloads.interactpak.com/interactpro/InteractPro-arm64.apk` | sideload on phone / TV |
| `app-release.aab` | Play Console (manual) | end users via Play Store |
| `interact_pro.ipa` (App Store) | App Store Connect (manual) | end users via App Store + TestFlight |
| `interact_pro.ipa` (ad-hoc) | Diawi / Configurator | named test devices only |

The Hetzner upload script puts every APK variant in `/downloads/interactpro/` so testers can pick the right ABI without you posting individual links.

---

## 8. Build-time variables

`dart_defines.json` (kept gitignored) holds anything compiled into the binary that you don't want in source. Currently used for:
- `INTERACT_APP_SLUG` — defaults to `interactpro`; override per-app fork (Sahulat = `sahulat`, etc.)
- `DEEPSEEK_API_KEY` — only if you want client-direct AI (the proxy path is preferred — see translation feature)
- `INTERACT_HUB_URL` / `INTERACT_HUB_TOKEN` — for migrating the in-app email path to the Comms Hub

To use:
```bash
flutter build apk --release \
  --dart-define-from-file=dart_defines.json
```

`scripts/build-and-upload.sh` already passes this flag.

---

## 9. Common build failures (and the one-line fix)

| Error | Fix |
|---|---|
| `Could not find a Build artifact for this device` | `flutter clean && flutter pub get && flutter build apk` (Gradle cache stale) |
| `Provisioning profile "iOS Team Provisioning Profile" doesn't include signing certificate` | Open Xcode → Runner → Signing → un-tick "Automatic", re-tick. Re-run. |
| `[!] CocoaPods could not find compatible versions for pod "Firebase/...":` | `cd ios && pod repo update && pod install` |
| `Execution failed for task ':app:lintVitalRelease'` (Android) | `flutter build apk --release --no-shrink` (then debug the lint warning later) |
| `Module 'flutter_local_notifications' not found` (iOS) | `cd ios && pod install` after `flutter pub get` |
| `Keystore file not found for signing config 'release'` | Check `android/key.properties` exists and `storeFile` path is correct |
| `Error: The kernel build failed` (during `flutter pub run build_runner`) | `dart run build_runner clean && dart run build_runner build --delete-conflicting-outputs` |

---

## 10. Verifying a built artifact before shipping it

```bash
# Confirm the APK has the right intent filters (catches the Samsung-share regression)
adb shell pm dump com.interactpak.interactpro | grep -A 4 SEND | head -20

# Confirm the version code/name match what you intended
aapt dump badging build/app/outputs/flutter-apk/app-arm64-v8a-release.apk | grep -E '(versionName|versionCode)'

# iOS — confirm the bundle id and version
plutil -p build/ios/iphoneos/Runner.app/Info.plist | grep -E '(CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion)'

# Run the obfuscated symbol check (release builds strip stack traces by default)
ls -la build/app/outputs/symbols/                    # should contain .symbols files for crash-report decoding
```

Crash reports from production users won't be readable without those `.symbols` files. Keep them archived per release in `~/Library/InteractPro/symbols/<version>/`.

---

## Sources

- [`BUILD_AND_RELEASE.md`](./BUILD_AND_RELEASE.md) — canonical, deeper version of this doc
- [`scripts/build-and-upload.sh`](./scripts/build-and-upload.sh) — the one-command release script
- [`dart_defines.example.json`](./dart_defines.example.json) — template for the gitignored real file
- Apple Developer Program: <https://developer.apple.com/programs/>
- Google Play Console: <https://play.google.com/console>
- Diawi (ad-hoc iOS distribution): <https://diawi.com>
