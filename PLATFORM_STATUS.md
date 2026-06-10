# Platform support — current state and roadmap

Interact Pro currently ships for **iOS**, **iPadOS** and **Android**. The
LAN code already branches on `Platform.isMacOS / Windows / Linux` for
forward-compat, but several core dependencies don't have desktop support
yet, so the desktop tree isn't compiled.

This file is the honest accounting of what would have to change to add
each desktop target.

## Quick summary

| Platform | Status | Effort to ship |
|---|---|---|
| iOS | ✅ Released | — |
| iPadOS | ✅ Released | — |
| Android | ✅ Released | — |
| macOS | ⚠️ Possible with feature loss | 1–2 weeks + per-feature work |
| Windows | ❌ Not currently feasible | 4–6 weeks; significant rewrites |
| Linux | ❌ Not currently feasible | 4–6 weeks; significant rewrites |
| Web | ❌ Out of scope | Almost every native feature would need a web equivalent |

## Per-dependency desktop support

Cross-referenced against pubspec as of May 2026.

| Dependency | iOS | Android | macOS | Windows | Linux |
|---|---|---|---|---|---|
| `syncfusion_flutter_pdfviewer` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `syncfusion_flutter_pdf` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `syncfusion_flutter_signaturepad` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `pdfx` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `pdf` / `printing` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `google_mlkit_text_recognition` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `google_mlkit_image_labeling` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `google_mlkit_digital_ink_recognition` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `cunning_document_scanner` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `mobile_scanner` (QR) | ✅ | ✅ | ❌ | ❌ | ❌ |
| `qr_flutter`, `barcode_widget` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `signature` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `image_picker` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `camera` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `flutter_chrome_cast` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `ar_flutter_plugin` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `flutter_tts` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `speech_to_text` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `bonsoir` (mDNS) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `network_info_plus` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `shelf` / `shelf_router` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `google_sign_in` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `googleapis` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `drift` / `drift_flutter` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `shared_preferences` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `flutter_secure_storage` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `permission_handler` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `file_picker` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `share_plus` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `url_launcher` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `open_filex` | ✅ | ✅ | ❌ | ✅ | ✅ |
| `app_links` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `receive_sharing_intent` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `workmanager` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `in_app_purchase` | ✅ | ✅ | ✅ | ❌ | ❌ |

## What this means in practice

### macOS — the most achievable desktop target

A macOS build is feasible **if you're willing to lose** these features:

- OCR (no ML Kit on macOS — you'd swap to Apple's `Vision` framework via
  a platform channel, or the cross-platform `tesseract_ocr` (which has
  its own Gradle issues on Android — keep the platforms separate).
- Image identification (same — needs Apple `Vision` for labels).
- Digital-ink handwriting recognition (no ML Kit; Apple's `PencilKit` +
  on-device handwriting recognition is the macOS-native equivalent).
- Document scanning via `cunning_document_scanner` — replace with
  `VNDocumentCameraViewController` (Apple) wrapped in a platform channel
  or just `image_picker` + manual crop.
- Chromecast (no Cast SDK on macOS; AirPlay is fine).
- AR measurement (no ARKit on macOS desktop; iPad-only for now).

**Effort estimate:** 1–2 weeks for a feature-reduced macOS build, plus
~3–5 days per feature you want to bring back via macOS-native APIs.

**Why even bother:** users with PDFs already on a Mac (signing,
annotating, drive-syncing) would benefit from the desktop app even
without OCR / handwriting / AR — those are the photo-driven features
that most users do on phone anyway.

### Windows — not currently feasible without significant rewrites

The blocker is `camera`, `mobile_scanner`, `cunning_document_scanner`,
plus all the ML Kit + AR plugins. Without a camera pipeline, three
flagship features (scanner, QR, photograph-handwriting) can't ship.

If a Windows build became a priority, the route would be:

1. Replace `camera` with `camera_windows` (community plugin, partial
   coverage) or a Win32 plugin via `flutter_window_close` + `media_kit`.
2. Replace ML Kit with cloud calls (the vision LLM service we already
   have can substitute for OCR / labels / handwriting at the cost of
   network and tokens).
3. Drop AR, Chromecast, Apple-specific bits (AirPlay, etc).
4. Re-skin the UI for desktop conventions (right-click menus, multi-
   window support, drag-drop file import).

**Effort estimate:** 4–6 weeks for a usable Windows build, with
materially fewer features than mobile.

### Linux — same as Windows, plus:

`flutter_secure_storage` works on Linux but requires `libsecret`.
`google_sign_in` doesn't ship a Linux implementation — you'd need to
roll your own OAuth flow against `googleapis_auth`. Same blockers as
Windows otherwise.

### Web — out of scope for the foreseeable future

Almost every native feature of Interact Pro would need a web equivalent:

- ML Kit → Cloud Vision / TensorFlow.js
- Camera → `getUserMedia()`
- Local PDF storage → IndexedDB-backed Drift (works) but no shared `.pdf`
  files to native viewers
- LAN discovery → impossible from a browser sandbox
- Cast → Web Cast API (limited)
- AR → WebXR (limited device support)

If a "viewer-only" web build is wanted (just open and read PDFs in a
browser tab), the existing app could be configured to compile to web
with most features disabled. That would be ~3 days. For full feature
parity with mobile, web is a separate product.

## Recommendation

If desktop becomes a priority, in order of ROI:

1. **macOS** with the feature-reduced set above (1–2 weeks).
2. **iPadOS optimisation** — the app already runs on iPad, but the UI is
   still phone-first. Two-column layouts, keyboard shortcuts, proper
   multitasking support would unlock significantly more value than a
   Windows port (~1 week).
3. **Android tablet optimisation** — same story (~1 week).
4. **Windows** — if there's a specific enterprise customer asking for it
   (4–6 weeks, feature-reduced).
5. Skip Linux and Web unless a customer explicitly pays for them.
