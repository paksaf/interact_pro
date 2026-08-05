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

  /// TV / device-flow scopes. Google HARD-REJECTS drive.readonly on the
  /// limited-input device flow ("Invalid device flow scope", verified
  /// against oauth2.googleapis.com/device/code 2026-06-11), so the TV can
  /// only ever get drive.file consent of its own. Consequence: the TV's
  /// Drive browser lists files created/uploaded BY Interact Pro (e.g.
  /// from the phone app — same project, so they're visible here). Full
  /// my-Drive browsing on TV would need a phone→TV token relay (backlog).
  static const List<String> driveTvScopes = <String>[
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
  /// Supplied at build via --dart-define=DRIVE_TV_CLIENT_ID=... (NOT committed).
  static const String driveTvClientId =
      String.fromEnvironment('DRIVE_TV_CLIENT_ID');

  /// Client secret paired with [driveTvClientId]. For "TVs and Limited Input
  /// devices" clients Google's token endpoint REQUIRES a client_secret; per
  /// Google's docs it is NOT confidential for this client type — but it must
  /// still NOT be committed (GitHub secret-scanning flags it, and public
  /// exposure invites app-impersonation/quota abuse). Provide it at build:
  ///   --dart-define=DRIVE_TV_CLIENT_ID=... --dart-define=DRIVE_TV_CLIENT_SECRET=...
  /// Keep the real values in the untracked `_shared/config/google_credentials.json`
  /// (see the `.example`) / the team secrets store, never in source.
  /// Rotated 2026-07-31 after the prior hardcoded pair leaked (GitHub alert #2).
  static const String driveTvClientSecret =
      String.fromEnvironment('DRIVE_TV_CLIENT_SECRET');

  /// True once the TV OAuth pair is fully configured. `String.fromEnvironment`
  /// defaults to '' when the --dart-define is absent, so isNotEmpty is the real
  /// gate (a bare !startsWith('TODO_') would wrongly report configured on '').
  static bool get driveTvConfigured =>
      driveTvClientId.isNotEmpty &&
      driveTvClientSecret.isNotEmpty &&
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
