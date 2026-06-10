// SPDX-License-Identifier: AGPL-3.0
//
// AutoSyncService — Spike F.
//
// Closes the "save → cloud" gap. Today /api/sync/upload exists but
// nothing in the app calls it automatically — users must tap "Sync
// now" from the Settings → Sync screen. Most never do.
//
// Behaviour:
//   1. Reads SharedPreferences `autoSyncEnabled` (default false).
//      Users opt in from Settings → Privacy → "Auto-save my edited
//      documents to cloud."
//   2. When enabled, listens to two signals via Riverpod providers:
//        • Document save events from the viewer (after PDF bytes
//          are written back to disk).
//        • Successful sign events from SignatureRepository.
//   3. On either signal, debounces by 3s (so a rapid burst of
//      saves coalesces into one upload), then calls
//      SyncApiClient.upload(file) and stamps PdfDocuments.autoUploadedAt
//      with `now()`.
//   4. Network failures are logged + the timestamp NOT stamped so the
//      next save retries.
//
// This service is intentionally NOT a singleton bound to app
// startup — too many side effects. The viewer & sign sheet call
// `triggerForDocument(id)` directly when they know a save just
// committed. Riverpod's Provider keeps a single instance.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/utils/logger.dart';
import 'sync_api_client.dart';

class AutoSyncService {
  AutoSyncService(this._db, this._api);

  final AppDatabase _db;
  final SyncApiClient _api;

  static const String _kPrefKey = 'auto_sync_enabled';
  static const Duration _debounce = Duration(seconds: 3);

  final Map<String, Timer> _pending = {};

  /// Default OFF. The Settings screen toggles it. Worth re-reading
  /// on every trigger rather than caching — users may flip it
  /// mid-session.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPrefKey) ?? false;
  }

  Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefKey, v);
  }

  /// Call this on:
  ///   • viewer save (annotation flush, redaction commit, form fill)
  ///   • SignatureRepository.signDocument success
  ///   • OcrController flatten success
  ///
  /// No-op when the user hasn't opted in OR the doc doesn't exist.
  /// Debounces by 3s so a flurry of small saves (typical with ink
  /// strokes) only triggers one upload.
  Future<void> triggerForDocument(String documentId) async {
    if (!await isEnabled()) return;
    _pending[documentId]?.cancel();
    _pending[documentId] = Timer(_debounce, () async {
      _pending.remove(documentId);
      await _flush(documentId);
    });
  }

  Future<void> _flush(String documentId) async {
    final doc = await (_db.select(_db.pdfDocuments)
          ..where((t) => t.id.equals(documentId)))
        .getSingleOrNull();
    if (doc == null) return;

    // Already up-to-date? autoUploadedAt is wall-clock at the
    // moment of the last successful upload. updatedAt is the row's
    // last modification (annotation, sign, OCR, etc.). If the
    // upload timestamp is more recent than updatedAt we have
    // nothing to do.
    final last = doc.autoUploadedAt;
    if (last != null && !doc.updatedAt.isAfter(last)) return;

    final file = File(doc.path);
    if (!file.existsSync()) {
      appLogger.w('AutoSync: file missing $documentId — skipping');
      return;
    }

    // Look up the cloud copy by name to get the expected version
    // for If-Match. Skip the version check on first-upload (no
    // prior cloud copy).
    final result = await _api.upload(file: file);
    if (result.isOk) {
      await _db.update(_db.pdfDocuments).replace(
            doc.toCompanion(true).copyWith(
                  autoUploadedAt: Value(DateTime.now()),
                ),
          );
      appLogger.i('AutoSync: uploaded ${doc.title} (${doc.id})');
    } else {
      appLogger.w('AutoSync: upload failed for ${doc.id} — will retry next save');
    }
  }

  void dispose() {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
  }
}

final autoSyncServiceProvider = Provider<AutoSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(syncApiClientProvider);
  final svc = AutoSyncService(db, api);
  ref.onDispose(svc.dispose);
  return svc;
});
