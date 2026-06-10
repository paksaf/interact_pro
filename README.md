# Interact Pro (Flutter)

A mobile PDF workstation for Android and iOS — view, edit, OCR, sign, stamp, scan, and sync to Google Drive. Built from the v2.0 PRD.

> **This is a scaffold, not a finished app.** Architecture, folder layout, dependencies, and key entry points are wired up. Many feature methods contain `TODO(scaffold)` markers — those are the real implementation work.

---

## Stack at a glance

| Concern              | Choice                                                                |
|----------------------|-----------------------------------------------------------------------|
| UI / cross-platform  | Flutter (Dart)                                                        |
| State management     | `flutter_riverpod` 2.x with code-gen-friendly `Notifier` classes      |
| Routing              | `go_router`                                                           |
| PDF render & edit    | `syncfusion_flutter_pdfviewer` + `syncfusion_flutter_pdf` (commercial) |
| PDF render alt.      | `pdfx` (Pdfium) for OCR rasterisation                                 |
| PDF assembly         | `pdf` package (for scans → PDF)                                       |
| OCR                  | `google_mlkit_text_recognition` (on-device)                           |
| Doc scanner          | `cunning_document_scanner` (ML Kit on Android, VisionKit on iOS)      |
| Signatures (drawn)   | `signature` package                                                   |
| Signatures (cert.)   | Syncfusion's `PdfSignatureField` + `PdfCertificate`                   |
| Local DB             | Isar (single-file, offline-first)                                     |
| Secure storage       | `flutter_secure_storage` (Keychain / EncryptedSharedPrefs)            |
| Drive integration    | `google_sign_in` + `googleapis` (`drive.file` scope only)             |
| Background sync      | `workmanager`                                                         |
| Permissions          | `permission_handler`                                                  |

---

## Architecture

Feature-first clean architecture. Each feature module is split into:

```
features/<feature>/
├── domain/
│   ├── entities/        ← pure Dart, no framework deps
│   ├── repositories/    ← interfaces (the contract presentation depends on)
│   └── usecases/        ← optional, for orchestrating multiple repos
├── data/
│   ├── datasources/     ← raw I/O — Syncfusion calls, ML Kit, googleapis, etc.
│   ├── repositories/    ← implements the domain interface
│   └── models/          ← Isar / JSON DTOs (with codegen)
└── presentation/
    ├── providers/       ← Riverpod controllers + state classes
    ├── screens/         ← top-level pages
    └── widgets/         ← feature-scoped widgets
```

**Cross-feature deps**: only via `domain/`. The annotations feature depends on `viewer/domain/entities/pdf_document.dart` — never on `viewer/data/...`.

**Errors**: every repository method returns `Result<T>` (`core/utils/result.dart`). Datasources can throw — repositories catch and convert to `Failure` subclasses (`core/error/failures.dart`). Presentation layers never see a thrown exception.

**DI**: Riverpod providers, no separate container. Most repositories are `FutureProvider` so they can `await` async setup (e.g. `getApplicationDocumentsDirectory()`).

---

## Feature roadmap

The table below maps PRD requirements to where they are scaffolded vs. still need work.

| PRD ID    | Feature                          | File                                                           | Status            |
|-----------|----------------------------------|----------------------------------------------------------------|-------------------|
| **OCR**   |                                  |                                                                |                   |
| OCR-01    | Run OCR on any PDF/image         | `ocr/data/datasources/mlkit_ocr_datasource.dart`               | ✅ wired          |
| OCR-02    | Multi-language                   | `OcrLanguage` enum + `_recogniserFor`                          | ✅                |
| OCR-03    | Skip if already searchable       | `isAlreadySearchable`                                          | ✅                |
| OCR-04    | Fast / Accurate modes            | `OcrAccuracyMode`, DPI scaling                                 | ✅                |
| OCR-05    | Build searchable PDF overlay     | `buildSearchablePdf`                                           | ⚠️ **TODO**       |
| OCR-06    | Export `.txt`                    | `exportPlainText`                                              | ✅                |
| **EDIT**  |                                  |                                                                |                   |
| EDIT-01   | Insert text                      | `EditAction.InsertText` + `EditorRepositoryImpl.apply`         | ✅ basic          |
| EDIT-02   | Edit existing text               | `EditAction.EditExistingText`                                  | ⚠️ **TODO**       |
| EDIT-03   | Move/insert images               | `MoveImage` / `InsertImage`                                    | ⚠️ partial        |
| EDIT-05   | Extract pages                    | `PdfRepositoryImpl.extractPages`                               | ✅                |
| EDIT-06   | Rotate page                      | `PdfRepositoryImpl.rotatePage`                                 | ✅                |
| EDIT-07   | 50-step undo/redo                | `EditorController` undo/redo stack                             | ✅ structural     |
| EDIT-08   | Flatten                          | `PdfRepositoryImpl.flatten`                                    | ⚠️ **TODO**       |
| **SEL**   |                                  |                                                                |                   |
| SEL-01    | Long-press selection menu        | `ViewerScreen.onTextSelectionChanged`                          | ⚠️ stub           |
| SEL-02    | Redaction                        | `RedactAnnotation`, `addAnnotation`                            | ✅ visual only    |
| SEL-03    | Highlight / underline / strike   | `HighlightAnnotation`, `addAnnotation`                         | ✅                |
| **SIGN**  |                                  |                                                                |                   |
| SIGN-01   | Draw signature                   | `SignaturePadScreen` (drawn)                                   | ✅ UI             |
| SIGN-02   | Import signature                 | `SignaturePadScreen` (imported)                                | ⚠️ TODO           |
| SIGN-03   | Save up to 5 presets             | `saveSignaturePreset` + Isar enforcement                       | ⚠️ TODO           |
| SIGN-04   | Place signature                  | `placeSignature`                                               | ⚠️ TODO           |
| SIGN-05   | Certificate-based signature      | `applyCertificateSignature`                                    | ✅                |
| SIGN-06   | Validate signatures              | `validateSignatures`                                           | ⚠️ TODO           |
| **STAMP** |                                  |                                                                |                   |
| STAMP-01  | Predefined stamps                | `PredefinedStamps.all`, `placeStamp`                           | ✅                |
| STAMP-02  | Custom text stamps               | `Stamp.customText`, `placeStamp`                               | ✅                |
| STAMP-03  | Dynamic stamps (date/user/etc.)  | `DynamicStampField`, `_resolveDynamicText`                     | ✅ basic          |
| STAMP-04  | Image stamps                     | `Stamp.image`, `placeStamp`                                    | ✅                |
| STAMP-05  | Adjustable opacity 0.2–1.0       | `Stamp.opacity`                                                | ✅                |
| **SCAN**  |                                  |                                                                |                   |
| SCAN-01..04 | Capture, edge-detect, filter   | `ScannerRepositoryImpl`, `cunning_document_scanner`            | ✅                |
| SCAN-05   | Optional OCR after scan          | `buildPdf(runOcr: true)`                                       | ⚠️ wire to OCR    |
| **GDR**   |                                  |                                                                |                   |
| GDR-01    | OAuth (`drive.file`)             | `DriveRemoteDatasource`                                        | ✅                |
| GDR-02    | Upload to `Backups/`             | `DriveRepositoryImpl.upload`                                   | ✅                |
| GDR-03    | Download                         | `DriveRepositoryImpl.download`                                 | ✅                |
| GDR-04    | List backups                     | `DriveRepositoryImpl.listBackups`                              | ✅                |
| GDR-05    | Save-to-Drive button             | `ViewerScreen` action                                          | ⚠️ wire           |
| GDR-06    | Offline queue (200 items)        | `SyncQueueEntry`, `sync_worker.dart`                           | ⚠️ **TODO**       |
| GDR-07    | Periodic background sync         | `scheduleSyncWorker`                                           | ✅ structural     |
| GDR-08    | Conflict resolution UI           | `resolveConflict`                                              | ✅ logic, UI TODO |

---

## Setup

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # once you add Isar/Freezed models
flutter run
```

### Syncfusion licensing

The Syncfusion Flutter PDF packages require a license key. Either:

1. Apply for the [Syncfusion Community License](https://www.syncfusion.com/sales/communitylicense) (free for individuals / small companies).
2. Buy a commercial license.

Register the key in `main.dart` *before* `runApp`:

```dart
SyncfusionLicense.registerLicense('YOUR_KEY');
```

If you can't or don't want to use Syncfusion, replace its usage with `pdfx` (rendering) + `pdf` (creation) — but you'll lose annotation/signature/edit primitives and need to reimplement those.

### Google Drive

1. Create a Google Cloud project; enable Drive API.
2. Add OAuth client IDs for Android (with your SHA-1) and iOS (bundle id).
3. Drop the iOS reversed client id into `ios/Runner/Info.plist` under `CFBundleURLSchemes`.
4. Android needs nothing else if you stick to the default `applicationId` in `android/app/build.gradle`.

### iOS — `Info.plist` additions

```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan documents and import signatures.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Used to import images and signatures.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Used to save scanned PDFs.</string>
<key>GIDClientID</key>
<string>YOUR_IOS_CLIENT_ID.apps.googleusercontent.com</string>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>com.googleusercontent.apps.YOUR_IOS_CLIENT_ID</string>
    </array>
  </dict>
</array>
```

Set `IPHONEOS_DEPLOYMENT_TARGET` ≥ `13.0` in `ios/Podfile` (VisionKit doc scanner needs it).

### Android — `AndroidManifest.xml` additions

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
```

Set `minSdkVersion 26`, `targetSdkVersion 34` in `android/app/build.gradle`. Workmanager needs `WorkManager` initialized — flutter_workmanager handles this if `Application.onCreate` isn't overridden.

---

## Realistic next steps

In order:

1. **Generate Isar models** — `PdfDocumentEntity`, `AnnotationEntity`, `SignaturePresetEntity`, `StampEntity`, `SyncQueueEntryEntity`. Run `build_runner`. Wire them into the repository TODOs.
2. **Build the searchable-PDF overlay** (OCR-05). This is the trickiest piece: render the page, draw OCR text at each block's `boundingBox` with a transparent pen, save.
3. **Wire the Drive sync queue** — Workmanager dispatcher reads queue from Isar, attempts each operation, retries with backoff, surfaces errors as local notifications.
4. **Conflict resolution UI** — bottom sheet showing local vs. remote metadata; calls `resolveConflict`.
5. **Polish flatten** (EDIT-08) — render every page to bitmap via pdfx, rebuild flat PDF via `pdf` package.
6. **Edit existing text** (EDIT-02) — non-trivial; the plan is to use `PdfTextExtractor`'s `getText` with `TextLine` positions, white-out the region, redraw with the new string at the same baseline + font.

Honest scope estimate: **4–6 months of solo full-time work to reach the PRD's "feature parity with Adobe Acrobat" bar**, not the 8-week timeline. The scaffold puts you at week 1 of that.

---

## Pro tier (paid)

The free baseline ships everything you need to read, edit, OCR, sign, and sync PDFs. The Pro tier unlocks the headline differentiators below. All Pro features live under `lib/features/pro/`, `features/translation/`, `features/voice/`, and `features/hotspots/`.

### Pro features

| Feature              | Module                       | Implementation                                                |
|----------------------|------------------------------|---------------------------------------------------------------|
| AI translation       | `features/translation/`      | DeepSeek chat-completions API + RTL-aware result rendering    |
| Read aloud (TTS)     | `features/voice/`            | `flutter_tts`                                                 |
| Voice dictation (STT)| `features/voice/`            | `speech_to_text`                                              |
| Interactive hotspots | `features/hotspots/`         | Custom overlay + repository (production: bake into PDF as `PdfUriAnnotation`/widget annotations so they travel with the file) |
| Polished Urdu/Arabic | rendering layer              | Syncfusion's PDF viewer already supports RTL & Arabic shaping; ensure font subset includes `Noto Naskh Arabic`/`Noto Nastaliq Urdu` for fallback |
| Unlimited OCR & sync | gating only                  | Free tier counters live in `SharedPreferences`; check before each call |
| No watermark         | export pipeline              | Skip the watermark draw step when `noWatermark` is unlocked   |

### Entitlement model

`ProEntitlement` is a granular enum (`translation`, `voiceReadAloud`, `hotspots`, …). Wrapping any UI affordance in `ProGate(entitlement: …, child: …)` automatically renders an upsell overlay for free users that taps through to the paywall. To check programmatically:

```dart
final canTranslate = ref.watch(hasEntitlementProvider(ProEntitlement.translation));
```

### IAP setup

1. Create three SKUs in **App Store Connect** and **Google Play Console** with these exact IDs (defined in `lib/features/pro/domain/iap_products.dart`):
   - `interact_pro_monthly` — auto-renewing subscription
   - `interact_pro_yearly` — auto-renewing subscription
   - `interact_pro_lifetime` — non-consumable
2. Submit both apps for store review with the products attached.
3. **Verify receipts server-side.** The scaffold's `ProRepositoryImpl` grants entitlement on the device immediately when a purchase succeeds — this is fine for development but trivially bypassable on a rooted/jailbroken device. For production, send `purchase.verificationData.serverVerificationData` to your backend, validate it against Apple's/Google's verification endpoints, and only then write the entitlement to your user record.

### DeepSeek translation — security note

`DeepSeekClient` ships with two modes:

- **Direct mode (development):** the API key is stored in platform-secure storage (`flutter_secure_storage` → Keychain on iOS, EncryptedSharedPreferences on Android). The client signs requests directly with the key.
- **Proxy mode (recommended for production):** call `client.setProxyEndpoint('https://your-backend.example.com/translate')`. The client now sends translation requests to your backend, which injects the real DeepSeek key server-side, enforces per-user rate limits, and verifies the user's Pro entitlement before forwarding.

**Do not ship a release build with a real DeepSeek key embedded.** Anyone who decompiles your APK can extract it. Use proxy mode.

### Voice features — Urdu specifics

- **TTS (read aloud):** `flutter_tts` works with Urdu (`ur-PK`) only if the device has an Urdu voice pack installed. Google's TTS engine ships it on most Android phones; older devices and most iOS devices may need the user to install one. Detect availability with `TtsController.availableLanguages()` and gracefully fall back.
- **STT (dictation):** `speech_to_text` defaults to the device's primary recognizer locale. Pass `localeId: 'ur_PK'` to `start()` for Urdu.

### Wiring the Pro UI

The viewer's overflow menu currently has placeholder entries for "Translate" and "Read aloud". To wire them up:

```dart
// In viewer_screen.dart's overflow ListTile for Translate:
ProGate(
  entitlement: ProEntitlement.translation,
  upsellLabel: 'Translate · Pro',
  child: ListTile(
    leading: const Icon(Icons.translate),
    title: const Text('Translate'),
    onTap: () {
      Navigator.pop(context);
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => TranslationSheet(originalText: selectedText),
      );
    },
  ),
)
```

The same pattern applies to TTS, STT, and hotspot creation tools.

---

## Realistic timeline

A solo developer with intermediate Flutter experience should expect roughly the following to ship a polished v1 to both stores:

| Phase                                              | Estimate    |
|----------------------------------------------------|-------------|
| Wire scaffold up + base PDF viewing/import/export  | 2–3 weeks   |
| OCR (both modes) + searchable PDF generation       | 2 weeks     |
| Editor + annotations + flatten-to-PDF              | 3–4 weeks   |
| Document scanner + filters                         | 1 week      |
| Signature library + drawn/typed/imported flow      | 1–2 weeks   |
| Google Drive sync + offline queue                  | 2–3 weeks   |
| Pro: paywall + IAP + receipt verification backend  | 2 weeks     |
| Pro: DeepSeek backend proxy                        | 1 week      |
| Pro: TTS, STT, hotspots                            | 1–2 weeks   |
| Polish, beta, store submissions                    | 2–3 weeks   |
| **Total**                                          | **4–6 months** |

The biggest hidden costs: signed-PDF edge cases, OCR accuracy tuning per language, Drive conflict resolution, and store review back-and-forth (especially for IAP).

---

## Open work / TODOs in the scaffold

Search the codebase for `TODO(scaffold)` to find every spot that needs implementation work. The big ones:

- **`features/drive_sync/data/datasources/sync_worker.dart`** — open Isar in the worker isolate, drain the `SyncQueueEntity` rows, dispatch through `DriveRepository`, handle retries/backoff.
- **`features/hotspots/data/hotspot_repository.dart`** — replace the in-memory `Map` with Isar persistence and bake hotspots into the PDF as PDF annotations so they travel with the file.
- **`features/pro/data/pro_repository.dart`** — add the server-side receipt verification step before granting entitlement.
- **`features/translation/data/deepseek_client.dart`** — switch to proxy mode for production builds.
- **`features/annotations/data/repositories/annotation_repository_impl.dart`** — persist annotations to Isar; hook the freehand path replay during flatten.
