import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'app_database.g.dart';

// ─────────────────────────── Tables ───────────────────────────────────────

/// Imported / scanned PDFs. The local file lives at [PdfDocuments.path] —
/// that's the source of truth on disk. The row holds metadata + sync flags.
class PdfDocuments extends Table {
  TextColumn get id => text()();
  TextColumn get path => text()();
  TextColumn get title => text()();
  IntColumn get pageCount => integer()();
  IntColumn get sizeBytes => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Set after the file is uploaded to Drive (PRD GDR-02).
  TextColumn get driveFileId => text().nullable()();
  TextColumn get thumbnailPath => text().nullable()();

  BoolColumn get isOcrApplied =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isFlattened =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isDigitallySigned =>
      boolean().withDefault(const Constant(false))();

  /// Spike A — originator-notify on sign.
  /// When this PDF arrived via an incoming share (email attachment,
  /// "Share to Pro" from WhatsApp/Mail, drop on file picker, etc.),
  /// IncomingFileListener tries to extract the sender's contact and
  /// stores it here. Used by SignatureNotifier to ping the originator
  /// via Comms Hub each time the doc is signed.
  TextColumn get originatorEmail => text().nullable()();
  TextColumn get originatorPhone => text().nullable()();

  /// Spike F — auto-upload bookkeeping.
  /// Wall-clock time of the LAST auto-upload to /api/sync/upload.
  /// Compared against [updatedAt] by AutoSyncService to decide
  /// whether the local file is dirty (needs re-upload). Null = never
  /// auto-uploaded yet.
  DateTimeColumn get autoUploadedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// PRD ANNO-01..06: highlight, underline, comment, drawing.
class Annotations extends Table {
  TextColumn get id => text()();
  TextColumn get documentId => text().references(PdfDocuments, #id)();

  /// 0-indexed page.
  IntColumn get pageIndex => integer()();

  /// Discriminator — `highlight` / `underline` / `comment` / `ink` / `text`.
  TextColumn get kind => text()();

  /// JSON blob of geometry + style (rect, color, stroke). Schema migrations
  /// here are cheap because it's free-form.
  TextColumn get payloadJson => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// PRD SIGN-03: up to 5 saved signature presets.
class SignaturePresets extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// `drawn` / `imported` / `typed` / `certificate`.
  TextColumn get kind => text()();

  /// PNG (drawn / imported / typed) or `.p12` (certificate).
  TextColumn get assetPath => text()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// PRD STAMP-04: image stamps (Approved / Rejected / Custom).
class Stamps extends Table {
  TextColumn get id => text()();
  TextColumn get label => text()();
  TextColumn get assetPath => text()();
  IntColumn get usageCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Pro-only interactive overlays — long-press creates one, tap reveals.
class Hotspots extends Table {
  TextColumn get id => text()();
  TextColumn get documentId => text().references(PdfDocuments, #id)();
  IntColumn get pageIndex => integer()();
  RealColumn get x => real()();
  RealColumn get y => real()();
  RealColumn get width => real()();
  RealColumn get height => real()();

  /// `note` / `link` / `audio` / `video`.
  TextColumn get type => text()();
  TextColumn get content => text()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// PRD GDR-06: offline sync queue. Items here flush when connectivity
/// returns and Drive auth is healthy.
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get documentId => text().references(PdfDocuments, #id)();

  /// `upload` / `update_meta` / `delete`.
  TextColumn get operation => text()();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get queuedAt => dateTime()();
  DateTimeColumn get lastAttemptedAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
}

/// Avoids re-running OCR on identical files. Keyed by SHA-1 of bytes.
class OcrCache extends Table {
  TextColumn get fileHash => text()();
  TextColumn get fullText => text()();
  IntColumn get pageCount => integer()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {fileHash};
}

/// QR / barcode history. Both scanned (read from camera) and generated
/// (created from text input) codes land here so the user can re-use,
/// copy, or stamp them later.
///
/// Schema bump v2 → v3 added this.
class SavedCodes extends Table {
  TextColumn get id => text()();

  /// `scanned` or `generated` — drives the icon + section in the history.
  TextColumn get origin => text()();

  /// Format label shown to humans: "QR", "EAN-13", "Code 128", etc.
  TextColumn get format => text()();

  /// Decoded text or the user's input that produced the code.
  TextColumn get rawValue => text()();

  /// Optional user-supplied label for generated codes ("Office Wi-Fi"
  /// vs the raw payload). Null when the user didn't bother.
  TextColumn get label => text().nullable()();

  /// Path to a PNG render of the code, populated for generated codes
  /// (used by the "Use as stamp" flow). Scanned codes leave this null.
  TextColumn get imagePath => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Devices on the same Wi-Fi we've paired with for direct transfer.
/// Schema bump v1 → v2 added this. The `secret` column stores the 32-byte
/// HMAC key as a hex string (BLOB columns interact poorly with SQLite's
/// REPLACE semantics on some Android versions).
/// Schema bump v3 → v4 added `tlsFingerprintSha256` for cert pinning.
class PairedDevices extends Table {
  /// Stable per-install id of the peer.
  TextColumn get deviceId => text()();
  TextColumn get name => text()();

  /// `ios` / `android` / `macos` — drives icon choice in the device picker.
  TextColumn get platform => text()();

  /// Hex-encoded 32-byte HMAC-SHA256 secret. Generated at pair time.
  TextColumn get secretHex => text()();

  /// Hex-encoded SHA-256 fingerprint of the peer's TLS cert, captured at
  /// pair time. Sender pins this on every outbound HTTPS connection so a
  /// rotated / swapped cert is rejected. Nullable for rows created before
  /// v3 → v4 (legacy plain-HTTP pairs); senders treat null as "fall back
  /// to plain HTTP for backward compat".
  TextColumn get tlsFingerprintSha256 => text().nullable()();

  DateTimeColumn get pairedAt => dateTime()();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// Signing identities — Ed25519 keypairs used for the stepwise document
/// approval workflow (task #3). Schema v5.
///
/// One row per device for the local identity. Additional rows are created
/// when a peer device's public key is observed (during LAN pair handshake
/// or when receiving a signed PDF from outside).
///
/// Private key is NOT stored here — it lives in flutter_secure_storage
/// keyed by [id]. This table only persists the public half so verification
/// works even when the original signer isn't reachable.
class SigningIdentities extends Table {
  /// UUID. For the local device this matches the userId from the auth
  /// flow when signed in; for guest mode it's a stable device-local UUID
  /// generated on first launch.
  TextColumn get id => text()();

  /// Display name shown on the signature stamp ("Signed by ...").
  TextColumn get name => text()();

  /// Optional email/identifier. Helps distinguish two signers with the
  /// same display name.
  TextColumn get email => text().nullable()();

  /// Base64-encoded Ed25519 public key (32 bytes raw → ~44 chars b64).
  TextColumn get publicKeyB64 => text()();

  /// True for the row representing the device's own identity. Exactly
  /// one row per device should have this set. Used to find "my" key
  /// pair for signing without re-deriving from secure storage.
  BoolColumn get isLocal => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Signatures applied to PDF documents — the audit chain for the
/// stepwise approval workflow. Schema v5.
///
/// Each signature is tamper-evident: the [signatureBytes] field is an
/// Ed25519 signature over the concatenation of
/// (pdfHash || code || timestampMs || signerId), where [pdfHash] is
/// SHA-256 over the canonical PDF bytes at sign time. Verification
/// recomputes the message and runs Ed25519 verify against the signer's
/// stored public key.
///
/// MVP (Phase 1) stores signatures in this table only. Phase 2 will also
/// embed a visible stamp annotation in the PDF via syncfusion + persist
/// a sidecar .sigchain JSON alongside the document so signatures move
/// when the PDF is shared.
class Signatures extends Table {
  /// UUID for this signature row.
  TextColumn get id => text()();

  /// Document this signature applies to. References [PdfDocuments.id].
  TextColumn get documentId => text().references(PdfDocuments, #id)();

  /// References [SigningIdentities.id]. Stored separately rather than
  /// FK-constrained so receiving a signed PDF from an unknown peer
  /// doesn't require pre-existing identity row creation.
  TextColumn get signerId => text()();

  /// Unique signature code shown to the user — last 8 hex chars become
  /// the visible "code" on the stamp. Full UUID is the audit handle.
  TextColumn get code => text()();

  /// Unix milliseconds at signing time. Stored as int (not DateTime) so
  /// the on-disk format matches what we hash and sign over — avoids
  /// timezone-conversion edge cases when verifying across devices.
  IntColumn get timestampMs => integer()();

  /// SHA-256 over the PDF bytes at signing time, hex-encoded.
  TextColumn get pdfHashHex => text()();

  /// Base64-encoded Ed25519 signature (64 raw bytes → ~88 chars b64).
  TextColumn get signatureB64 => text()();

  /// Optional free-text note shown alongside the stamp ("Approved",
  /// "Reviewed and accepted", etc.).
  TextColumn get note => text().nullable()();

  /// Stamp position on the page (Phase 2 — used when rendering the
  /// visible annotation onto the PDF). Nullable for Phase 1 where the
  /// signature lives in the DB only with no visual placement yet.
  IntColumn get pageIndex => integer().nullable()();
  RealColumn get x => real().nullable()();
  RealColumn get y => real().nullable()();
  RealColumn get width => real().nullable()();
  RealColumn get height => real().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// User-defined tags for organizing the PDF library (task #2). Each tag
/// has a display name + a brand color (stored as #RRGGBB hex). Tags are
/// per-device — there's no server-side tag taxonomy. When PDFs are
/// shared via LAN, the tags applied to that PDF are included in the
/// share payload so the receiver gets the same labels (with auto-merge
/// on name+color conflict). Schema v6.
class Tags extends Table {
  /// UUID — keeps stable across renames so PdfTags FKs don't break.
  TextColumn get id => text()();

  /// Display name, e.g. "Contracts", "Q4 review", "Reference".
  /// Treated as case-insensitive unique per device — the repository
  /// enforces uniqueness when creating/renaming, not the schema.
  TextColumn get name => text()();

  /// Color in #RRGGBB hex (lower-case, with leading hash). Used for
  /// the chip background tint and the tag-filter pill in the library.
  /// Default '#1976d2' = Material blue 700, picked because it's
  /// distinct from the existing brand orange.
  TextColumn get colorHex =>
      text().withDefault(const Constant('#1976d2'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Join table: which PDFs have which tags. Many-to-many. Schema v6.
/// Composite primary key on (documentId, tagId) — applying the same
/// tag twice to the same PDF is a no-op via insertOnConflictUpdate.
class PdfTags extends Table {
  TextColumn get documentId => text().references(PdfDocuments, #id)();
  TextColumn get tagId => text().references(Tags, #id)();
  DateTimeColumn get appliedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {documentId, tagId};
}

/// Bookmarks on PDFs — colored flags that mark a specific page (and
/// optionally a region within that page) with a user note. Used to
/// build a personal reference diary across the library. Schema v7.
///
/// Phase 1 MVP: page-level only. The region columns are nullable so
/// Phase 2 can layer region selection in without a migration.
///
/// Color is stored as one of seven flag colors (red/orange/yellow/
/// green/blue/purple/grey) — fewer choices than tags because the
/// flag visual is a small marker on the page, not a chip. Constraining
/// the palette keeps the cross-PDF reference diary visually scannable.
/// Sticky notes — the "everywhere capture" feature (task #260, 2026-05-21).
///
/// Four note types share one table: text, voice, image, handwriting.
/// Body fields are nullable per-type so unused columns stay NULL rather
/// than forcing a row-per-type child table (matches how Bookmarks
/// embeds optional region fields).
///
/// Location reference:
///   - `documentId` + `pageIndex` — when captured from inside BookViewer,
///     the active book + page get pinned automatically.
///   - `contextRoute` — fallback for non-BookViewer captures (e.g.
///     "library", "scanner", "settings"); the route name the user was on
///     when they tapped the Notes button.
///   - `scrollFraction` — 0..1 inside the page, lets the BookViewer
///     bounce to roughly where the note was placed when reopened.
///
/// Media columns (audioPath / imagePath / handwritingPath) are file
/// paths under `<appSupport>/sticky_notes/<id>.<ext>` — small enough to
/// embed inline but kept on disk so the DB stays cheap to back up.
class StickyNotes extends Table {
  /// UUID.
  TextColumn get id => text()();

  /// One of: 'text', 'voice', 'image', 'handwriting'. String not enum so
  /// raw DB dumps stay self-describing and the UI doesn't need a magic-
  /// number map. Validated at the repository layer.
  TextColumn get kind => text()();

  /// Optional title shown above the note body in the grid card. For
  /// voice / image / handwriting notes this is what the user types as a
  /// caption; for text notes it's an explicit title field.
  TextColumn get title => text().nullable()();

  /// Body text. Set for kind='text'; also used as a caption for the
  /// other kinds when the user adds one.
  TextColumn get body => text().nullable()();

  /// Path to the voice recording (kind='voice'). `.m4a` on iOS, `.aac`
  /// on Android — whatever `record` package's default for the platform is.
  TextColumn get audioPath => text().nullable()();

  /// Path to the captured image (kind='image'). PNG for screen captures,
  /// JPG for camera/gallery picks.
  TextColumn get imagePath => text().nullable()();

  /// Path to the handwriting PNG (kind='handwriting'). Always PNG with
  /// transparent background so it composites onto any sticky color.
  TextColumn get handwritingPath => text().nullable()();

  /// Recording duration in milliseconds. Set only when kind='voice'.
  IntColumn get durationMs => integer().nullable()();

  // ── Location reference ─────────────────────────────────────────────

  /// PDF this note belongs to. NULL when captured outside a BookViewer.
  TextColumn get documentId =>
      text().nullable().references(PdfDocuments, #id, onDelete: KeyAction.setNull)();

  /// Page within the PDF (0-indexed).
  IntColumn get pageIndex => integer().nullable()();

  /// 0..1 vertical scroll position within the page. Survives zoom.
  RealColumn get scrollFraction => real().nullable()();

  /// Route name from AppRoutes when documentId is null. Examples:
  /// 'library', 'scanner', 'settings'. Lets us render "from the Scanner
  /// screen" in the note card instead of a meaningless blank.
  TextColumn get contextRoute => text().nullable()();

  // ── Presentation ───────────────────────────────────────────────────

  /// One of: 'yellow', 'pink', 'green', 'blue', 'purple', 'grey'. Matches
  /// the physical sticky-note palette so the grid view looks like a
  /// corkboard at a glance.
  TextColumn get color => text().withDefault(const Constant('yellow'))();

  /// Pinned notes float to the top of the grid + survive bulk-archive.
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  /// Comma-separated tag names. Free-text; the Notes screen's filter
  /// chip row auto-builds from distinct values. (Keeping tags inline
  /// rather than a many-to-many table because notes are personal +
  /// transient — the bookshelf-Tags table handles the durable case.)
  TextColumn get tags => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft-delete timestamp. NULL = active. Archived notes still appear
  /// under a "Trash" filter in the Notes screen for 30 days before the
  /// nightly cleanup deletes the row + media file.
  DateTimeColumn get archivedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Bookmarks extends Table {
  /// UUID.
  TextColumn get id => text()();

  /// Document this bookmark belongs to. References [PdfDocuments.id].
  TextColumn get documentId => text().references(PdfDocuments, #id)();

  /// 0-indexed page within the PDF.
  IntColumn get pageIndex => integer()();

  /// Region within the page (Phase 2). All four nullable for Phase 1
  /// where bookmarks pin to the page as a whole. When set, the values
  /// are page-relative fractional coords (0..1) so they survive page
  /// resize / re-render.
  RealColumn get regionX => real().nullable()();
  RealColumn get regionY => real().nullable()();
  RealColumn get regionWidth => real().nullable()();
  RealColumn get regionHeight => real().nullable()();

  /// Color flag — one of: 'red', 'orange', 'yellow', 'green', 'blue',
  /// 'purple', 'grey'. Stored as the name string so it's human-readable
  /// in raw DB dumps and the UI doesn't need a magic-number map.
  TextColumn get color => text().withDefault(const Constant('blue'))();

  /// Optional user note. Free-text, no length cap at the schema level —
  /// the UI imposes a soft limit of ~280 chars (one tweet's worth) so
  /// the reference-diary list doesn't blow up.
  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// ─────────────────────────── Database ─────────────────────────────────────

@DriftDatabase(tables: [
  PdfDocuments,
  Annotations,
  SignaturePresets,
  Stamps,
  Hotspots,
  SyncQueue,
  OcrCache,
  PairedDevices,
  SavedCodes,
  SigningIdentities,
  Signatures,
  Tags,
  PdfTags,
  Bookmarks,
  StickyNotes,
],)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  /// Bump on every breaking schema change. The migration block below maps
  /// 1 → 2 → 3 etc. — never delete a previous step.
  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
        onUpgrade: (m, from, to) async {
          // v1 → v2: introduced LAN cross-device sharing.
          if (from < 2) await m.createTable(pairedDevices);
          // v2 → v3: scanned + generated QR/barcode history.
          if (from < 3) await m.createTable(savedCodes);
          // v3 → v4: TLS cert pinning per pair. Existing rows get NULL
          // fingerprint (LanRepository.send falls back to plain HTTP for
          // them). Users will be prompted to re-pair to upgrade to TLS.
          if (from < 4) {
            await m.addColumn(pairedDevices, pairedDevices.tlsFingerprintSha256);
          }
          // v4 → v5: stepwise approval signatures (task #3).
          // Two new tables — signing_identities (one row per known
          // signer, public keys + display info) and signatures (the
          // audit chain rows). Local identity row is created lazily
          // by SigningKeysService on first sign attempt; no data needs
          // to be backfilled in this migration.
          if (from < 5) {
            await m.createTable(signingIdentities);
            await m.createTable(signatures);
          }
          // v5 → v6: bookshelf tags (task #2). Two new tables — Tags
          // (the tag taxonomy) and PdfTags (many-to-many join). Empty
          // initial state; users create their first tag via the Settings
          // → Tag manager screen.
          if (from < 6) {
            await m.createTable(tags);
            await m.createTable(pdfTags);
          }
          // v6 → v7: bookmarks + reference diary (task #1). One new
          // table — Bookmarks — with optional region cols pre-baced so
          // Phase 2's region-picker doesn't need another migration.
          if (from < 7) {
            await m.createTable(bookmarks);
          }
          // v7 → v8: Spike A (originator-notify on sign) + Spike F
          // (auto-upload on save). Three new nullable columns on
          // PdfDocuments — originatorEmail / originatorPhone capture
          // who sent the doc via incoming share, autoUploadedAt
          // records the last successful /api/sync/upload. All three
          // are nullable so existing rows migrate silently.
          if (from < 8) {
            await m.addColumn(pdfDocuments, pdfDocuments.originatorEmail);
            await m.addColumn(pdfDocuments, pdfDocuments.originatorPhone);
            await m.addColumn(pdfDocuments, pdfDocuments.autoUploadedAt);
          }
          // v8 → v9: sticky notes (task #260). Multi-kind capture (text,
          // voice, image, handwriting) with location ref to the active
          // book + page. One new table — StickyNotes — see its docstring
          // for the column layout.
          if (from < 9) {
            await m.createTable(stickyNotes);
          }
        },
      );

  // ── Convenience DAO methods ───────────────────────────────────────────

  Future<List<PdfDocument>> allDocumentsByRecency() {
    return (select(pdfDocuments)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<PdfDocument?> documentByPath(String path) {
    return (select(pdfDocuments)..where((t) => t.path.equals(path)))
        .getSingleOrNull();
  }

  Future<int> upsertDocument(PdfDocumentsCompanion entry) =>
      into(pdfDocuments).insertOnConflictUpdate(entry);

  Future<int> deleteDocument(String id) =>
      (delete(pdfDocuments)..where((t) => t.id.equals(id))).go();

  Future<List<Annotation>> annotationsForPage(String docId, int page) {
    return (select(annotations)
          ..where((t) =>
              t.documentId.equals(docId) & t.pageIndex.equals(page),))
        .get();
  }

  Future<List<Hotspot>> hotspotsForPage(String docId, int page) {
    return (select(hotspots)
          ..where((t) =>
              t.documentId.equals(docId) & t.pageIndex.equals(page),))
        .get();
  }

  Future<OcrCacheData?> cachedOcr(String fileHash) =>
      (select(ocrCache)..where((t) => t.fileHash.equals(fileHash)))
          .getSingleOrNull();

  /// Insert or replace the cached OCR text for [fileHash]. Re-running OCR
  /// on the same file (matched by SHA-1) becomes an instant DB read.
  Future<int> upsertOcrCache({
    required String fileHash,
    required String fullText,
    required int pageCount,
  }) =>
      into(ocrCache).insertOnConflictUpdate(
        OcrCacheCompanion(
          fileHash: Value(fileHash),
          fullText: Value(fullText),
          pageCount: Value(pageCount),
          cachedAt: Value(DateTime.now()),
        ),
      );

  // ── Paired LAN devices ────────────────────────────────────────────────

  Stream<List<PairedDevice>> watchPairedDevices() =>
      (select(pairedDevices)
            ..orderBy([(t) => OrderingTerm.desc(t.pairedAt)]))
          .watch();

  Future<PairedDevice?> pairedDevice(String deviceId) =>
      (select(pairedDevices)..where((t) => t.deviceId.equals(deviceId)))
          .getSingleOrNull();

  Future<void> upsertPairedDevice(PairedDevicesCompanion entry) =>
      into(pairedDevices).insertOnConflictUpdate(entry);

  Future<int> unpairDevice(String deviceId) =>
      (delete(pairedDevices)..where((t) => t.deviceId.equals(deviceId))).go();

  Future<void> markPairedDeviceSeen(String deviceId) =>
      (update(pairedDevices)..where((t) => t.deviceId.equals(deviceId)))
          .write(PairedDevicesCompanion(lastSeenAt: Value(DateTime.now())));

  // ── Saved QR / barcode history ──────────────────────────────────────

  Stream<List<SavedCode>> watchSavedCodes({String? originFilter}) {
    final q = select(savedCodes)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (originFilter != null) {
      q.where((t) => t.origin.equals(originFilter));
    }
    return q.watch();
  }

  Future<int> insertSavedCode(SavedCodesCompanion entry) =>
      into(savedCodes).insert(entry);

  Future<int> deleteSavedCode(String id) =>
      (delete(savedCodes)..where((t) => t.id.equals(id))).go();
}

QueryExecutor _open() {
  // drift_flutter handles SQLite plumbing across platforms (uses bundled
  // sqlite3 on Android, system sqlite3 on iOS, and proper background
  // isolates so queries don't block the UI thread).
  return driftDatabase(name: 'interact_pro');
}

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
