/// Application-wide constants. Tweak these in one place rather than
/// scattering magic numbers and strings across features.
class AppConstants {
  AppConstants._();

  // ── App identity ───────────────────────────────────────────────────────────
  static const String appName = 'Interact Pro';
  static const String appVersion = '2.0.0';

  // ── Storage paths ──────────────────────────────────────────────────────────
  /// Local sub-folder under the app's documents directory where edited PDFs
  /// live. Mirrored to Drive at `Interact Pro/Backups/`.
  static const String localPdfFolder = 'pdfs';
  static const String scannedFolder = 'scans';
  static const String thumbnailsFolder = 'thumbnails';

  // ── Google Drive ───────────────────────────────────────────────────────────
  /// GDR-01 REVISED 2026-06-10 (product decision): TV must browse ALL the
  /// user's Drive PDFs, not just app-created ones. `drive.readonly` grants
  /// read of everything; `drive.file` stays for uploads/backups (write to
  /// app-created files). Note: drive.readonly is a Google "restricted"
  /// scope — unverified clients show an "unverified app" consent warning
  /// and are capped at 100 users. Acceptable for internal distribution;
  /// requires Google verification before public release.
  /// Existing sign-ins must DISCONNECT + RE-PAIR to pick up the new scope.
  static const List<String> driveScopes = <String>[
    'https://www.googleapis.com/auth/drive.readonly',
    'https://www.googleapis.com/auth/drive.file',
  ];
  static const String driveBackupFolderName = 'Interact Pro';
  static const String driveBackupSubfolder = 'Backups';

  /// OAuth 2.0 client_id of type "TVs and Limited Input devices" —
  /// used by the Device Flow path on Android TV (the standard
  /// `google_sign_in` flow was deprecated for Drive on Android TV in
  /// late 2024). DIFFERENT from the Android client_id used by
  /// `google_sign_in` on phones.
  ///
  /// Created 2026-05-16 in Google Cloud Console project
  /// `interact-pro-496115`. The shared OAuth consent screen still
  /// needs:
  ///   1. drive.file scope added under Data Access
  ///   2. branding submitted for verification (logo + URLs are
  ///      already in place; only the user-support email may need
  ///      switching from a personal Gmail to a domain address)
  /// Until both ship, end users see Google's "unverified app" notice
  /// during pairing AND a 100-user lifetime cap applies. Code path
  /// works regardless — only the consent UX is affected.
  static const String driveTvClientId =
      '394554205484-qgddairmjpo5d5kbuco94epslqe7p69s.apps.googleusercontent.com';

  /// Client secret paired with [driveTvClientId]. ADDED 2026-06-10:
  /// Google's token endpoint REQUIRES client_secret for "TVs and
  /// Limited Input devices" clients — without it the device-flow poll
  /// fails with "client_secret is missing" (the TV Drive bug). Copy it
  /// from Google Cloud Console → Credentials → the TV client → "Client
  /// secret" (same place the client_id came from). Per Google's docs
  /// this secret is NOT treated as confidential for this client type,
  /// so shipping it in the APK is the sanctioned pattern. Template:
  /// `_shared/config/google_credentials.json.example`.
  static const String driveTvClientSecret =
      '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'; // from Apple Note "Interact pro:" — TV (Device Flow) client, created 2026-05-16

  /// True once the TV OAuth pair is fully configured.
  static bool get driveTvConfigured =>
      !driveTvClientId.startsWith('TODO_') &&
      !driveTvClientSecret.startsWith('TODO_');

  // ── OCR ────────────────────────────────────────────────────────────────────
  /// PRD OCR-04: target latencies on Snapdragon-class hardware.
  static const Duration ocrFastModeTargetPerPage = Duration(seconds: 1);
  static const Duration ocrAccurateModeTargetPerPage = Duration(seconds: 3);

  // ── AI backend (Track 3 Phase 1 — Surya advanced OCR) ─────────────────────
  /// Base URL of the Python FastAPI service (Surya / Marker / Tesseract).
  /// Lives behind Caddy on the same Hetzner VPS as pro-api but proxied
  /// under `/api/ocr/*` for clean separation. See
  /// `interact-pro-ai-backend/deploy/caddy-snippet.conf`.
  static const String aiBackendBaseUrl = 'https://pro.interactpak.com';

  /// Shared secret with the Python service. Empty in public APK builds
  /// — the Flutter side gates the "Advanced layout analysis" toggle
  /// behind `aiBackendConfigured` so users without the secret see the
  /// toggle disabled rather than a confusing 503. Injected at build
  /// time via:
  ///   flutter build apk --dart-define=INTERACT_PRO_AI_SECRET=...
  static const String aiBackendSecret =
      String.fromEnvironment('INTERACT_PRO_AI_SECRET');

  static bool get aiBackendConfigured => aiBackendSecret.isNotEmpty;

  /// Endpoint path. Contract documented in
  /// interact-pro-ai-backend/README.md.
  static const String aiAdvancedOcrPath = '/api/ocr/advanced';

  // ── Editor ─────────────────────────────────────────────────────────────────
  /// PRD EDIT-07.
  static const int undoRedoStackSize = 50;

  // ── Sync ───────────────────────────────────────────────────────────────────
  static const Duration syncDebounce = Duration(seconds: 2);
  static const int offlineQueueMaxSize = 200;
  static const String syncWorkerTaskName = 'interact_pro_sync_task';
  static const Duration syncWorkerInterval = Duration(hours: 1);
}
