# Interact Pro — session state (snapshot)

Captured at the end of the spring 2026 build sprint. Use this to pick
back up next week without re-orienting.

## Latest checkpoint — May 2026 feature push

Added in the most recent run (still in this folder, not yet pushed to
any host until you run `bash scripts/build-and-upload.sh`):

- Cast to TV — `lib/features/casting/` (system AirPlay + Chromecast SDK).
  Native: `ios/Runner/AirPlayPlugin.swift`,
  `android/.../CastOptionsProvider.kt`. See `lib/features/casting/CASTING.md`.
- Handwriting — both digital ink (`lib/features/handwriting/`, write on
  screen, ML Kit `DigitalInkRecognizer`) AND photograph-handwriting
  (`lib/features/handwriting_doc/`, ML Kit on-device + DeepSeek vision
  cloud engine).
- Vision LLM service — `lib/features/vision/` (DeepSeek vision via the
  same auth model as the existing translation client). Wired into
  `image_identifier`'s deep-analysis path.
- AR measure — `lib/features/ar_measuring/` via `ar_flutter_plugin`.
  Tap two points on a detected surface, get distance with mm/cm/m/in/ft
  unit picker. Native config: ARCore `<meta-data>` in AndroidManifest,
  `UIRequiresFullScreen=false` + camera usage in Info.plist.
- Library shelf — `lib/features/library/` (bookshelf-style grid with
  per-PDF first-page thumbnails on wood-textured rows). Backed by
  `thumbnail_service.dart` (mtime-keyed JPEG cache).
- Book-flip viewer — `lib/features/book_viewer/` with custom
  `page_flip.dart` (rotateY transform + sheen overlay). Two-page
  spread on landscape tablets.
- Auth + VPS sync — `lib/features/auth/` (email/phone OTP, JWT in
  secure storage, AuthRepository + provider) and `lib/features/sync/`
  (per-user manifest + upload + download against `pro.interactpak.com`).
  Both are CLIENT-side only — backend still needs to be deployed.
- Trial banner — three-state banner above home content (`auth/.../trial_banner.dart`).
- Admin panel — `lib/features/admin/` master-detail user manager,
  hidden behind `user.isAdmin` server-side role.
- Tablet UI — `lib/core/layout/responsive.dart` (Material 3 window-size
  classes), `lib/core/shortcuts/app_shortcuts.dart` (Cmd-shortcuts, work
  with iPadOS Cmd+/ overlay). Library/home/admin/book-viewer all check
  `WindowSize.of(context)` for adaptive layouts.
- Viewer thumbnail sidebar — `lib/features/viewer/.../thumbnail_sidebar.dart`
  on tablet-or-wider, toggleable via new AppBar action. Lazy-loaded
  per-page thumbnails via the same `thumbnail_service` (extended with
  `pageNumber` parameter + `xsmall` size).
- Offline-first PDF fonts — `transcript_to_pdf.dart` now prefers the
  bundled `assets/fonts/` (NotoNaskhArabic, Gurmukhi, AppleGothic, etc.)
  before falling back to `PdfGoogleFonts`.

### Distribution (this turn)

Two new scripts pushed in this round:

- `scripts/build-and-upload.sh` — build APK / AAB / IPA, then upload
  to BOTH `downloads.interactpak.com/interactpro/` (FTP to Hetzner
  Webhosting, same account every other INTERACT app uses) and
  `pro.interactpak.com/downloads/interactpro/` (rsync over SSH to the
  Hetzner VPS at 178.105.73.238). Run from the project root on a Mac
  with Flutter + lftp installed and `.env.local` populated.
- Patched `../ussd-rewards/scripts/upload-downloads.sh` so the canonical
  multi-app uploader picks up Interact Pro's `build/dist/` too.

Run the full build + double-publish:

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro
bash scripts/build-and-upload.sh
```

### What's NOT yet on a server

- The `pro.interactpak.com` Caddy route doesn't exist yet — the script
  will rsync the binaries to `/var/www/pro/downloads/interactpro/` on
  the VPS, and prints the Caddyfile snippet you need to add.
- `pro.interactpak.com/api/auth`, `/api/sync`, `/api/admin` — the API
  contracts are documented in `lib/features/auth/data/auth_api_client.dart`,
  `lib/features/sync/data/sync_api_client.dart`, and
  `lib/features/admin/.../admin_screen.dart`. Until the server ships,
  the app's "Continue without an account" path keeps working locally.

---

## Live infrastructure

| Surface | Host | Status |
|--|--|--|
| Translate proxy (DeepSeek) | `signal.interactpak.com/translate` (current `dart_defines.json`) | Live, token-gated, weekly usage email scheduled (Mondays 09:00 UTC). |
| Translate proxy code | `/opt/interact/translate-proxy/` on Hetzner | Synced from `server/translate-proxy/` in this repo. |
| Token (`APP_SHARED_SECRET`) | `/etc/interact/translate.env` (server) + `dart_defines.json` (Mac) | 64-char value already populated in `dart_defines.json`. |
| `pro.interactpak.com` | NOT YET DEPLOYED | The auth / sync / admin API + binary mirror. Caddy block + folders installable via `scripts/install-pro-caddy.sh`; backend code itself still TODO. |
| `downloads.interactpak.com` | Apache @ `157.90.191.190` (Webhosting S) | Existing landing page lives in `server/downloads-site/`. The Apache `/interactpro/` vhost block is already drafted in `server/downloads-site/apache.conf.snippet`. |

## App features shipped

PDF viewer, editor (rotate / delete / flatten / text+voice notes),
signature placement (draw + photo + saved presets, drag-to-place),
**stamp picker** (predefined catalog / custom text / image, with
opacity + dynamic placeholders), **hotspots** (Drift-backed, list view
with delete + jump-to-page), translate (DeepSeek via proxy, cached),
read-aloud TTS (selection-aware, language + voice pickers, persisted),
OCR-on-PDF (cached by SHA-1, .txt save, share, copy), document scanner
(camera → filtered → PDF, registered in Recents), **QR / barcode
reader + generator** (history persisted to Drift, "Use as stamp" pipe
into the PDF), **Image Identifier** (ML Kit labels + text recognition),
Save to Drive (user's own Google Drive), print, share, Send to nearby
device (LAN, mDNS-discovered, paired), Find Signed PDF (search by name
or code), Settings + Pro paywall + 7-day trial.

## Backlog — picked up next session

Ordered by what we agreed to do next, after the release pipeline:

1. **PDF merge / split / watermark** — combine, extract page ranges,
   text/image watermark per page. All use Syncfusion's existing API
   plus the stamp infra. ~1 day combined.
2. **Unit converter** — length, area, volume, weight, temperature, time,
   data, speed, pressure. Currency deferred to Pro (needs rates API).
   Entry point next to Image Identifier in the home AppBar.
3. **Multi-language UX (Urdu/English toggle)** — `flutter_localizations`
   + Urdu .arb file. App chrome only — translate feature already does
   Urdu via DeepSeek.
4. **Batch image OCR** — pick N photos, run OCR sequentially, output
   combined text or a single searchable PDF.
5. **Image identifier improvements ported from rewards app** — waiting
   on the rewards-app source path to read the existing implementation.
6. **Indoor measuring tool ported from grower app** — waiting on the
   grower-app source path. Disabled tile already in place inside
   Image Identifier screen.
7. **PDF flip ("book" page-turn animation)** — `turn_page_transition`
   layered over Syncfusion as a "Read mode" toggle. Half a day.
8. **Save to "our" Drive** — open architectural decision: Google
   service-account model vs. MinIO/S3 on Hetzner. Recommended MinIO
   for predictable pricing + no Google review chain.
9. **PDF compression** — lower-DPI re-render of the existing flatten
   pipeline. Hours.
10. **Form filling** — Syncfusion exposes `pdf.form.fields[]`; UI walks
    them, typing/signing each. ~1 day.
11. **Receipt scanner** — vendor + total + date extraction; expense
    report exports.
12. **Hotspot drag-to-place UX** (#53) — currently drops at page center;
    add the same drag overlay flow signatures and stamps use, plus
    inline visual rendering of existing hotspots over the page.
13. **Tesseract offline OCR bundling** — package present in pubspec but
    trained-data files aren't bundled; ML Kit covers most cases on-
    device anyway, this is belt-and-suspenders.
14. **Drive sync queue worker** — `SyncQueue` table exists; offline-
    mode upload retry would consume it.
15. **iCloud datasource** — stubbed; full impl is iOS-only and requires
    CloudKit container setup in App Store Connect.
16. **Highlight + Edit toolbar tools** — toolbar buttons exist but are
    inert; signature/stamp/note cover v1 annotation needs.

## Drift schema versions

Currently at **v3**. Migration history:
- v1 → v2: added `PairedDevices` (LAN cross-device sharing).
- v2 → v3: added `SavedCodes` (QR/barcode history, scanned + generated).

## Native config notes

- iOS deployment target: 15.5 (ML Kit 8 requirement).
- Bundle id: see `ios/Runner.xcodeproj/project.pbxproj`.
- Custom URL scheme: `interactpro://` for cross-app deep links.
- Permissions declared: camera, microphone, speech recognition, photo
  library, local network (mDNS).
- Cocoapods baseConfig warning is benign for `flutter run`, will block
  App Store builds — see `BUILD_AND_RELEASE.md` for the one-line fix.

## Outstanding install/build issues

- Android: needs a release keystore (see `android/key.properties.example`
  and the runbook).
- iOS: requires Apple Developer Program enrolment for any distribution
  beyond your own dev devices.
- The `flutter pub outdated` list shows 88 packages with newer versions;
  none are blocking. Worth a "bump major versions" sprint at some
  point but not for v1.

## Recommended next session opener

```
1. flutter pub get
2. flutter run --dart-define-from-file=dart_defines.json
3. Read this file + BUILD_AND_RELEASE.md
4. Pick the merge/split/watermark task and start there.
```
