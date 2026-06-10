# Build & release runbook — Interact Pro

End-to-end recipe for producing distributable Android + iOS artifacts
and hosting them on `downloads.interactpak.com` and (optionally) the
parallel mirror at `pro.interactpak.com`.

**TL;DR — once the one-time setup at the top is done, every release is
literally one command:**

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro
bash scripts/build-and-upload.sh
```

That script does the build (using `dart_defines.json`) and ships the
APK + AAB + IPA to both endpoints. The rest of this doc explains the
prerequisites and what the script does under the hood.

---

## One-time prerequisites

### Android: create a release keystore

The keystore is the cryptographic identity that signs every APK. Once
you publish a build under it, every future build must use the same
keystore — Google Play and Android both refuse signature changes.

```bash
# Pick a passphrase you'll remember and store it in 1Password / Bitwarden.
keytool -genkey -v \
  -keystore ~/keys/interactpak-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload \
  -storetype JKS

# Move it somewhere that survives a Mac wipe — a USB key, your password
# manager's secure notes, an encrypted DMG. NEVER commit it.
```

Then create `android/key.properties` (gitignored) at the repo root:

```properties
storePassword=<your store passphrase>
keyPassword=<your key passphrase, often the same as above>
keyAlias=upload
storeFile=/Users/muzafar/keys/interactpak-upload.jks
```

The Gradle config (`android/app/build.gradle.kts`) already reads from
this file — no Gradle edits needed if it's set up correctly. Verify:

```bash
grep -A 5 'keystoreProperties' android/app/build.gradle.kts || echo 'NEEDS WIRING'
```

If you see `NEEDS WIRING`, the project skeleton predates release
signing. The block to add inside `android` { ... } in `build.gradle.kts`:

```kotlin
val keystoreProperties = java.util.Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

### iOS: enrol in Apple Developer Program

`https://developer.apple.com/programs/` — $99/year, ~24h approval.
Until you're enrolled you can't distribute outside your own dev
devices. Skip everything else in this doc's iOS section until you have
a Team ID.

After enrolment, in Xcode → Runner → Signing & Capabilities:
1. Tick "Automatically manage signing".
2. Select your Apple Developer team.
3. Bundle id should already be `com.interactpak.interactPro` (or
   whatever the project sets) — this needs to be unique across the
   App Store, so it'll fail if someone else owns it.

### iOS: fix the CocoaPods baseConfig warning

The recurring "CocoaPods did not set the base configuration" warning
is benign for `flutter run` but breaks App Store archive builds. Fix
once:

```bash
open ios/Runner.xcworkspace
```

Xcode → Runner project (blue icon) → Info → Configurations →
expand each row (Debug / Profile / Release) → set the Runner target's
"Based on configuration file" column to the matching
`Pods-Runner.<config>.xcconfig`. Save, close, done.

### Hosting: where `downloads.interactpak.com` actually runs

`downloads.interactpak.com` is the Hetzner **Webhosting S** subdomain
on `157.90.191.190` (Apache, not Caddy). Every other INTERACT app
publishes binaries there via FTP at `/public_html/downloads/<app>/`,
and so does Interact Pro — at `/public_html/downloads/interactpro/`,
matching the path in `server/downloads-site/apache.conf.snippet`.

You only have to do the Apache vhost wiring **once**. The block lives
in `server/downloads-site/apache.conf.snippet` — paste it inside the
existing `<VirtualHost>` block for `downloads.interactpak.com` (likely
under `/etc/apache2/sites-available/downloads.interactpak.com.conf`)
and reload Apache:

```bash
sudo apache2ctl configtest
sudo systemctl reload apache2
```

After that, every future build just FTPs new files into the same
folder — no further server work.

### (Optional) Parallel mirror at `pro.interactpak.com`

If you also want a Pro-app-branded download URL alongside the existing
`downloads.*` one, the sibling script

```bash
bash scripts/install-pro-caddy.sh
```

provisions `pro.interactpak.com` on the Hetzner VPS at `178.105.73.238`
(modern Caddy host, separate from the Webhosting S Apache box). It's
idempotent — re-running overwrites only the marked block in the
Caddyfile. The VPS path is `/var/www/pro/downloads/interactpro/` and
gets populated by the same `scripts/build-and-upload.sh` run that
ships the FTP mirror.

This is purely a convenience mirror — `downloads.interactpak.com/interactpro/`
alone is enough for "other devices to download". Skip this step if
you don't want the second URL.

---

## Build commands

Always pass the dart-defines file so the proxy URL + token + Google
client id end up baked into the binary. Without it the app will boot
but translate / Drive sign-in will silently fail.

### Android — APK (direct install via website)

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro

flutter clean
flutter pub get
dart run build_runner build --delete-conflicting-outputs

flutter build apk --release \
  --dart-define-from-file=dart_defines.json \
  --target-platform android-arm,android-arm64,android-x64 \
  --split-per-abi
```

Artifacts land in `build/app/outputs/flutter-apk/`:

- `app-armeabi-v7a-release.apk` — older 32-bit phones.
- `app-arm64-v8a-release.apk` — every modern phone.
- `app-x86_64-release.apk` — emulators / x86 tablets.

For most users, `app-arm64-v8a-release.apk` is the file to host. Or
build a single fat APK without `--split-per-abi` if you'd rather one
download serve everyone (~30 MB larger).

### NDK toolchain — fixing "failed to strip debug symbols"

If `flutter build appbundle` fails with:

```
Release app bundle failed to strip debug symbols from native libraries.
Please run flutter doctor and ensure that the Android toolchain does
not report any issues.
```

…the cause is almost always an NDK version mismatch. The release-mode
AAB build invokes `llvm-strip` from the Android NDK to remove debug
symbols from the `.so` files; if the NDK version Flutter expects isn't
installed, the strip step has nothing to call.

Diagnosis:

```bash
flutter doctor -v 2>&1 | grep -A 3 "Android toolchain"
ls -la ~/Library/Android/sdk/ndk/ 2>/dev/null
```

Fix — install the NDK Flutter expects via Android SDK Manager (current
Flutter SDK channels expect NDK `26.3.11579264`):

```bash
# Either via the GUI: Android Studio → SDK Manager → SDK Tools tab →
# tick "Show package details" → expand "NDK (Side by side)" →
# install 26.3.11579264.
#
# Or from CLI:
yes | sdkmanager --install "ndk;26.3.11579264"
```

Then pin the version in `android/app/build.gradle.kts` so it doesn't
drift on the next Flutter upgrade:

```kotlin
android {
    ndkVersion = "26.3.11579264"   // replace `flutter.ndkVersion`
    // ...
}
```

The APK build doesn't need this — only AAB does, because Play Console
requires stripped native libs. Direct-install APKs distribute fine
either way.

### Android — AAB (Play Store submission)

```bash
flutter build appbundle --release \
  --dart-define-from-file=dart_defines.json
```

Output: `build/app/outputs/bundle/release/app-release.aab`. Upload to
Play Console → create a release on Internal/Closed/Open testing or
Production tracks.

### iOS — IPA (TestFlight / ad-hoc, requires paid Dev account)

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro

flutter clean
flutter pub get
cd ios && pod install --repo-update && cd ..

flutter build ipa --release \
  --dart-define-from-file=dart_defines.json
```

Output: `build/ios/ipa/interact_pro.ipa`.

To distribute via **TestFlight** (easiest, recommended):

```bash
open build/ios/archive/Runner.xcarchive
# In Xcode Organizer, click "Distribute App" → App Store Connect → Upload.
# Then on App Store Connect, add testers + send invites.
```

To distribute via **ad-hoc OTA** (host on `downloads.`):

In Xcode Organizer pick "Distribute App" → Ad Hoc → Export. The export
includes a `manifest.plist` and the `.ipa`. The script's standard
upload places the `.ipa` at `/public_html/downloads/interactpro/InteractPro.ipa`.
For OTA install, upload `manifest.plist` next to it (one-line manual
`lftp` or via Webhosting's web file manager) and link to:

```
itms-services://?action=download-manifest&url=https://downloads.interactpak.com/interactpro/manifest.plist
```

iOS Safari opens that URL → prompts the user to install. Each device
must be registered under your developer account's UDID list (max 100).

---

## Deploy a fresh build to the website

The single command:

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro
bash scripts/build-and-upload.sh
```

What it does, in order:

1. Builds the release APK + AAB using `--dart-define-from-file=dart_defines.json`
   (so the proxy URL, app token, Google client id, vision model, and
   auth base URL all bake in correctly).
2. Best-effort iOS IPA — silently skips if your Apple signing isn't
   configured. The Android push doesn't depend on iOS.
3. FTPs the artifacts to `downloads.interactpak.com:/public_html/downloads/interactpro/`
   (Apache vhost — your existing `apache.conf.snippet` is the source of truth
   for the path). Credentials come from `HETZNER_FTP_PASS` in `.env.local`.
4. Rsyncs the same artifacts to `pro.interactpak.com:/var/www/pro/downloads/interactpro/`
   (Caddy vhost on the VPS, installed by `scripts/install-pro-caddy.sh`).
   Skipped silently if `~/.ssh/interactpak` is missing.
5. Prints the final URLs so you can paste them into a release email.

Flags:

```bash
bash scripts/build-and-upload.sh --android-only     # APK + AAB only
bash scripts/build-and-upload.sh --skip-pro         # only downloads.*
bash scripts/build-and-upload.sh --skip-downloads   # only pro.*
bash scripts/build-and-upload.sh --no-build         # upload prebuilt
```

`.env.local` (gitignored) at the project root needs at minimum:

```
HETZNER_FTP_PASS=<the existing Hetzner Webhosting password>
# Optional, only for the pro.* mirror:
PRO_VPS_KEY=~/.ssh/interactpak
```

The default FTP host (`9rkp.your-vhost.de`), user (`zrkpsy`), and VPS
(`178.105.73.238`) match every other INTERACT app's deployment, so
you usually only need the password line.

### What you DON'T need to do anymore

- **No `rsync` to `leathx-vps`.** That older path is obsolete; `leathx-vps`
  was a different host for a different stack.
- **No manual filename copies.** The script names everything `InteractPro.{apk,aab,ipa}` consistently.
- **No manual landing-page deploy.** `server/downloads-site/index.html`
  is already on the Apache box; refresh it via the same FTP account
  if you need to.

---

## Versioning checklist

Each release:

1. Bump `version: x.y.z+N` in `pubspec.yaml` (the `+N` is the build
   number; iOS uses it for CFBundleVersion, Android for versionCode).
2. Tag the commit: `git tag v0.x.y && git push --tags`.
3. Update the version label inside `server/downloads-site/index.html`
   (the `<span data-version>` element) so the website shows the right
   build.
4. After 7 days running with the new build, update the legacy
   download fallback link too.

---

## Roadmap dependency

Don't ship to the Play Store / App Store until at least:

- A privacy policy lives at `https://interactpak.com/privacy`
  (referenced by Settings → Privacy Policy in-app already).
- A terms-of-service page lives at `https://interactpak.com/terms`.
- The DeepSeek + Google Drive integrations are listed in the privacy
  page's "third-party services" section.

Both stores require these and will reject otherwise. The website
already hosts them per `ApiConfig.privacyPolicyUrl` / `termsUrl`,
so the implementation side is done — just confirm the actual pages
exist and reflect what the app does.
