# Interact Pro — Multi-platform build runbook (#161, #162, #163)

Three target platforms, three different signing stories, three
different distribution channels. This doc is the one-paste recipe for
each.

## #163 — Google Play Store (.aab)

Easiest one — the existing release APK builder already produces a
universal binary. We just need a bundled .aab + Play Console metadata.

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro

# 1. Bake the AI secret + build the bundle
bash scripts/bake-ai-secret.sh
flutter build appbundle --release --dart-define-from-file=dart_defines.json

# 2. Output: build/app/outputs/bundle/release/app-release.aab (~110 MB)
ls -la build/app/outputs/bundle/release/app-release.aab
```

**Play Console one-time setup** (user action):

1. Create a developer account at https://play.google.com/console
   ($25 one-time fee, ~48h verification)
2. Create app "Interact Pro" — single APK, no in-app billing for now
3. Upload `app-release.aab` to Internal Testing track first
4. Fill the Data Safety form. Pro's relevant disclosures:
   - **Files & docs**: yes, app reads PDFs (user-uploaded)
   - **Audio**: yes, microphone access for TTS/Whisper (declared in
     pubspec via `permission_handler`)
   - **Photos**: yes, document scanner uses camera
   - **No location, no contacts, no SMS** — make sure these stay
     unchecked
5. Add screenshots from the device (Bravia TV + phone) at the
   resolutions Play requires: phone 16:9 + tablet 16:10 + 7-inch TV
6. Promote Internal → Open Testing → Production once metrics are clean

The .aab is significantly smaller than the universal APK (~85 MB vs
221 MB) because Play splits per ABI automatically. Don't sideload
the .aab directly — `bundletool` is the only sideload path and Play
won't accept side-loaded binaries.

## #161 — macOS desktop

Flutter macOS support shipped stable; main hurdles are signing +
notarization. Without notarization, Gatekeeper blocks first launch.

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro

# 1. One-time native scaffold
flutter create --platforms=macos .

# 2. Audit deps that may need macOS native code
#    Risky deps: camera, mobile_scanner, flutter_webrtc, media_kit,
#    bonsoir, in_app_purchase, syncfusion. Most have macOS support
#    but check pubspec.yaml + run `flutter pub get` once to surface.
flutter pub get

# 3. Build release
bash scripts/bake-ai-secret.sh
flutter build macos --release --dart-define-from-file=dart_defines.json

# 4. Output: build/macos/Build/Products/Release/Interact Pro.app
```

**Signing + notarization** (user action — requires Apple Developer
Program $99/yr):

1. Create a "Developer ID Application" certificate at
   https://developer.apple.com/account/resources/certificates
2. Install the certificate into the macOS Keychain (double-click)
3. Sign:
   ```bash
   codesign --deep --force --verbose \
     --options runtime \
     --sign "Developer ID Application: <Your Name> (<TEAM_ID>)" \
     "build/macos/Build/Products/Release/Interact Pro.app"
   ```
4. Create a zip for notarization:
   ```bash
   ditto -c -k --keepParent \
     "build/macos/Build/Products/Release/Interact Pro.app" \
     /tmp/interact-pro-macos.zip
   ```
5. Submit to Apple:
   ```bash
   xcrun notarytool submit /tmp/interact-pro-macos.zip \
     --apple-id you@example.com --team-id <TEAM_ID> --wait
   ```
6. Staple the ticket:
   ```bash
   xcrun stapler staple "build/macos/Build/Products/Release/Interact Pro.app"
   ```
7. Distribute as a `.dmg` (use create-dmg) or as the zipped .app.
   Upload to https://downloads.interactpak.com/pro/ following the
   same pattern as the .apk.

**Without a Developer ID** the app will still build + run locally,
but users will see "App is damaged and can't be opened" on first
launch — they must right-click + Open and confirm in Security
preferences. Document this on the download page as the temporary
workaround until the cert is in place.

## #162 — Windows desktop

Flutter Windows is stable. MSIX is the modern distribution format
(Microsoft Store + sideload); EXE installer (via Inno Setup) is the
fallback for users who don't have Microsoft Store access.

```bash
# On a Windows machine (or VM — Parallels/UTM work):
cd %USERPROFILE%\Documents\INTERACT\interact_pro

# 1. One-time native scaffold (run once on Windows, never on macOS —
#    macOS-generated windows/ folder won't link properly).
flutter create --platforms=windows .

# 2. Build release
bash scripts/bake-ai-secret.sh
flutter build windows --release --dart-define-from-file=dart_defines.json

# 3. Output: build\windows\x64\runner\Release\interact_pro.exe
#    plus the DLLs it needs (flutter_windows.dll, plugin DLLs).
```

**Distribution** (user action — choose one):

**Option A: MSIX (Microsoft Store + sideload)**

```bash
flutter pub add msix --dev
flutter pub run msix:create \
  --display-name "Interact Pro" \
  --publisher-display-name "Interact Pak" \
  --publisher "CN=Interact Pak" \
  --identity-name com.interactpak.pro \
  --logo-path windows/runner/resources/app_icon.ico \
  --capabilities internetClient,microphone,picturesLibrary
```
Output `build\windows\x64\runner\Release\interact_pro.msix` —
sideload-able via PowerShell or Microsoft Store.

**Option B: Inno Setup .exe installer**

Install Inno Setup from https://jrsoftware.org/isinfo.php, then
compile `windows/installer.iss` (template at the bottom of this doc).
Produces a single `.exe` installer that handles registry + uninstall.

For our user base (Pakistan, mostly Android-first), Option B is
probably the right starting point — fewer users have the Microsoft
Store gate cleared on their Windows setup.

## Known dep concerns across platforms

Run `flutter pub deps` after `flutter create --platforms=...` and
watch for these:

| Plugin               | macOS    | Windows  | Notes |
|----------------------|----------|----------|-------|
| flutter_webrtc       | ✓        | ⚠ partial | Windows lacks acoustic-echo cancellation; doc the workaround |
| media_kit            | ✓        | ✓        | Bundles libmpv — adds 30 MB to each build |
| mobile_scanner       | ✓        | ✗        | Windows = no camera path. Hide the scan tab on desktop. |
| syncfusion_pdf       | ✓        | ✓        | Heavy but works |
| in_app_purchase      | n/a      | n/a      | Disable on desktop builds (use renewal endpoint instead) |
| bonsoir (mDNS)       | ✓        | ⚠        | Windows discovery flaky on some routers; doc manual-IP fallback |
| audioplayers         | ✓        | ✓        | Works |
| speech_to_text       | ⚠ macOS-only API needs entitlement | ✗ | Hide STT controls on Windows |

The DeviceCapabilities helper from #156 already gates UI on per-device
flags — extend it with `isMacOS` + `isWindows` and add `featureMatrix`
entries for each plugin above.

## Inno Setup .iss template (Windows)

Save as `windows/installer.iss`. Adjust paths if Flutter outputs
elsewhere.

```ini
#define MyAppName "Interact Pro"
#define MyAppVersion "2.0.3"
#define MyAppPublisher "Interact Pak"
#define MyAppURL "https://pro.interactpak.com/"
#define MyAppExeName "interact_pro.exe"

[Setup]
AppId={{B11B0C7E-5DCD-4D45-B7C6-3DBC8C0F5C1E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=..\..\..\..\dist
OutputBaseFilename=InteractPro-Setup-{#MyAppVersion}
SetupIconFile=runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\..\..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; \
    GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; \
    Flags: nowait postinstall skipifsilent
```

Build the installer:
```
"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" windows\installer.iss
```
Output ends up in `dist\InteractPro-Setup-2.0.3.exe`. Upload to
`https://downloads.interactpak.com/pro/InteractPro-Setup-2.0.3.exe`.

## Sequencing recommendation

1. **#163 first** (Play Store) — only piece needing nothing-but-build.
   Internal Testing track gets us TestFlight-style distribution
   without the production review cycle.
2. **#161 second** (macOS) — buy the Apple Developer Program first
   ($99/yr), then run through the notarization recipe. Notarization
   takes 5-10 min per submission.
3. **#162 last** (Windows) — needs a Windows machine or VM. If you
   have one already, skip ahead; otherwise, Parallels Desktop on Mac
   or a $20/month Hetzner Windows VM both work for the build host.
