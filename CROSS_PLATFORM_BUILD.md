# Cross-Platform Build Runbook — Interact Pro

Living reference for shipping Interact Pro beyond Android. Each
platform section starts with the COMMAND, then prerequisites, then
known gotchas. Don't run a section unless every prerequisite is
satisfied; the failure modes are expensive (rejected submissions,
revoked enterprise certs, dep-rabbit-holes).

Status as of 2026-05-17:

| Platform | Scaffold | Builds | Distributable | Effort to ship |
|---|---|---|---|---|
| Android (phone/tablet/TV) | ✅ | ✅ | ✅ pro.interactpak.com/InteractPro.apk | shipped |
| Android Play Store (.aab) | ✅ | not built | needs Play Console ($25) | 1 week incl. review |
| iOS / iPad | ✅ (ios/Runner.xcodeproj) | never built | App Store / TestFlight only | 3-5 weeks |
| macOS | ❌ no macos/ folder | — | DMG download w/ Gatekeeper bypass | 2-4 weeks |
| Windows | ❌ no windows/ folder | — | .exe download w/ SmartScreen friction | 2-3 weeks |
| Linux | ❌ no linux/ folder | — | .deb / Snap / Flatpak | 1-2 weeks |

---

## Android APK (current — production)

```bash
cd ~/Documents/INTERACT/interact_pro
HEX=$(ssh interact "grep -oP '(?<=INTERACT_PRO_AI_SECRET=)[a-f0-9]+' /etc/interact/pro-ai.env")

flutter build apk --release --split-per-abi \
  --dart-define=INTERACT_PRO_AI_SECRET="$HEX"

# Distribute (arm64 is the default for the website mirror)
scp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
  interact:/var/www/interactpro/InteractPro.apk

# Install on connected devices
adb -s R68T304FX1F        install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb -s 192.168.100.4:5555 install -r build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
```

Three ABIs (arm64 / armv7 / x86_64) are produced. arm64 covers all
modern phones/tablets; armv7 is required for the Bravia VH21 TV.

---

## Android App Bundle (Play Store, #163)

```bash
cd ~/Documents/INTERACT/interact_pro
HEX=$(ssh interact "grep -oP '(?<=INTERACT_PRO_AI_SECRET=)[a-f0-9]+' /etc/interact/pro-ai.env")

flutter build appbundle --release \
  --dart-define=INTERACT_PRO_AI_SECRET="$HEX"

ls -lh build/app/outputs/bundle/release/app-release.aab
```

**Then in Play Console (https://play.google.com/console — $25 one-time):**

1. Create app → "Interact Pro" → English (US) → Free → Education (or Productivity)
2. **App content** — privacy policy URL (HOST ONE; example: https://interactpak.com/privacy)
3. **Data safety** — declare every collection: account email (auth), document files (OCR/sync), microphone (TTS preview if enabled), camera (scan), Drive scopes used
4. **Content rating** — questionnaire → likely Everyone
5. **Target audience** — set age range; declares whether app targets children (matters for OCR/AI features)
6. **App signing** — let Google manage (Play App Signing) — keeps your upload key offline
7. **Internal testing track first** — upload .aab, invite 1-2 testers, iterate without paying review cost
8. **Production release** — promote when stable; first review 1-7 days, updates 1-3 hours

**Listing assets you'll need:** app icon (512×512), feature graphic
(1024×500), 2-8 phone screenshots, 1-8 7" tablet, 1-8 10" tablet, TV
banner (1280×720) + screenshots. Short description ≤80 chars, full
description ≤4000 chars.

**Common rejection causes for this app:**
- Missing privacy policy URL → host one at https://interactpak.com/pro/privacy
- Audio recording permission without justification — declare TTS preview use case explicitly
- Drive scope justification — explain why you need `drive.readonly` vs `drive.file`
- Background-location not used (good) — make sure you haven't accidentally declared it

---

## iOS / iPad (#160)

**Cannot ship from website.** Apple physically blocks `.ipa` install
outside of App Store, TestFlight, ABM/MDM. Plan accordingly.

```bash
# On the Mac — Xcode required (download from Mac App Store, ~10 GB)
cd ~/Documents/INTERACT/interact_pro

# After Apple Developer enrollment ($99/yr, ~24-48 hr review):
open ios/Runner.xcworkspace
# Xcode → Signing & Capabilities → Team: <your Apple Developer team>
# Xcode → Product → Archive → Distribute App → App Store Connect

# Or via CLI once the signing is configured:
flutter build ipa --release \
  --dart-define=INTERACT_PRO_AI_SECRET="$HEX" \
  --export-options-plist ios/ExportOptions.plist
```

**Dep audit before first build attempt** (these are the suspects
based on platform support history; verify with `flutter pub deps`
then check each package's pubspec for an `ios:` block under `flutter.plugin.platforms`):

| Package | iOS support | Mitigation |
|---|---|---|
| flutter_tts | ✅ AVSpeechSynthesizer | — |
| pdfx | ✅ PDFKit | — |
| audioplayers | ✅ | — |
| google_mlkit_digital_ink_recognition | ✅ via ML Kit pod | bumps min iOS to 12+ |
| cunning_document_scanner | ✅ via VisionKit | min iOS 13 |
| camera | ✅ | request NSCameraUsageDescription |
| bonsoir | ✅ via NSNetService | — |
| sqlite3_flutter_libs | ✅ via SQLite3 pod | — |
| signature | ✅ | — |
| permission_handler | ✅ | declare matching Info.plist keys |
| google_sign_in | ✅ but needs URL scheme in Info.plist | configure reversed client ID |

**Info.plist additions required:** NSCameraUsageDescription,
NSMicrophoneUsageDescription, NSPhotoLibraryUsageDescription,
NSLocalNetworkUsageDescription, NSBonjourServices (mDNS service
types for LAN pair), GIDClientID (Google Sign-In).

**Min iOS version:** bump Podfile to `platform :ios, '13.0'` — the
ML Kit + VisionKit deps require it.

---

## macOS (#161)

```bash
cd ~/Documents/INTERACT/interact_pro

# 1. Scaffold the platform folder
flutter create --platforms macos .

# 2. Try to build — expect failures, triage one by one
flutter build macos --release \
  --dart-define=INTERACT_PRO_AI_SECRET="$HEX"

# 3. After build succeeds, find the .app:
ls -lh build/macos/Build/Products/Release/interact_pro.app
```

**Expected build failures and triage:**

| Package | macOS likely status | Workaround |
|---|---|---|
| camera | ❌ no macOS impl | Use file_picker for image input on macOS only |
| google_mlkit_* | ❌ Mobile-only | Stub or route through cloud API |
| bonsoir | ✅ macOS (NSNetService) | — |
| cunning_document_scanner | ❌ Mobile-only | Hide UI on macOS via Platform.isMacOS check |
| permission_handler | partial — file/notification work, mic/camera need entitlements | declare in DebugProfile.entitlements + Release.entitlements |
| flutter_tts | ✅ NSSpeechSynthesizer | — |
| signature | ✅ | — |
| share_plus | ✅ | — |

**Entitlements (`macos/Runner/DebugProfile.entitlements` + same for Release):**
- `com.apple.security.network.client` — outbound HTTP
- `com.apple.security.network.server` — for LAN /receive endpoint
- `com.apple.security.files.user-selected.read-write` — file picker
- `com.apple.security.device.camera` — if camera deps stay
- `com.apple.security.device.audio-input` — if mic stays

**Distribution:**
- Sign + notarize (needs Apple Developer $99/yr): `xcrun notarytool submit`. Users double-click DMG → no warnings.
- Or ship unsigned: users must right-click → Open → Open Anyway. Acceptable for technical audience, friction-heavy for general users.

---

## Windows (#162)

**Requires Windows + Visual Studio 2022 + Desktop C++ workload.**
Cannot cross-compile from macOS or Linux.

```powershell
# On Windows
cd C:\Path\To\interact_pro

# 1. Scaffold
flutter create --platforms windows .

# 2. Build
flutter build windows --release `
  --dart-define=INTERACT_PRO_AI_SECRET="<hex>"

# 3. Find the artifact tree
dir build\windows\x64\runner\Release\
```

**Expected dep failures:** every plugin that doesn't list `windows:`
in its pubspec. ML Kit family, camera, signature_pad, bonsoir (Windows
mDNS is rough — may need `multicast_dns` direct).

**Packaging options:**
- **MSIX** (modern, sandboxed, can ship via Microsoft Store): `flutter pub run msix:create`
- **Inno Setup .exe installer** (traditional, more friction, no store needed)
- **Plain ZIP** (developer-distribution only — no shortcuts, no updater)

**Code signing:** without an EV cert (~$300/yr), SmartScreen will warn
every user on first launch ("Windows protected your PC"). Mitigation:
build reputation slowly (Microsoft tracks downloads of unsigned exes
over time), or pay for the EV cert.

---

## Cross-platform considerations baked into the codebase

These already work because of decisions made in earlier sessions:

- **`DeviceCapabilities.current()`** (`lib/core/device/device_capabilities.dart`) — answers `hasCamera`, `hasMicrophone`, `hasTouch`, `canShare`, etc. New platforms just need their answers added to the `current()` switch (Linux laptop = touch true if user wants, camera false on most desktops, etc.).
- **`WindowSize.of(context)`** (`lib/core/layout/responsive.dart`) — compact/medium/expanded breakpoints work identically on any platform. `LandscapeFormBody` already wraps phone-shaped forms for large screens.
- **`AppConstants.aiBackendConfigured`** — checked everywhere a remote engine is invoked; degrades gracefully when secret not baked in.
- **`CapabilityGate`** — wraps icons that should hide on platforms lacking the underlying capability. Already in use for camera/mic/share on TV; same gates apply on macOS/Windows where camera/mic are usually absent.

When you scaffold a new platform: search for `Platform.isAndroid` / `Platform.isIOS` and audit each branch — some will need `|| Platform.isMacOS` etc.

---

## Distribution surfaces

| Surface | URL | Hosts |
|---|---|---|
| Direct APK | https://pro.interactpak.com/InteractPro.apk | arm64 only (Bravia armv7 users need armv7 build) |
| Download mirror | https://downloads.interactpak.com/ | future: macOS DMG, Windows MSI, Linux DEB |
| Play Store | (TBD) | .aab once #163 ships |
| App Store | (TBD) | requires Apple Developer + review |
| Microsoft Store | (TBD) | MSIX once #162 ships, optional |

Always ship the latest binary to `pro.interactpak.com/InteractPro.apk`
on the same deploy as the Caddy config that serves it. Old downloaders
hitting `/api/version` get redirected to the new APK via the existing
update flow.
