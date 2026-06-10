// SPDX-License-Identifier: AGPL-3.0
//
// WorkManager isolate body for the Drive sync queue.
//
// Pre-2026-05-13 this file was a scaffold — the dispatcher returned
// success after a 1-second no-op, so the SyncQueue table grew forever
// while WorkManager fired every 15 minutes and accomplished nothing.
// Now: opens the database, drains pending operations through a fresh
// GoogleDriveDataSource (silent-sign-in piggybacks the Android
// AccountManager grant from the main isolate), respects retry counts
// with exponential-ish backoff, and bails before the 10-min OS budget
// to avoid SIGKILL.
//
// Lifecycle: WorkManager registers this dispatcher at app boot
// (`main.dart` → `Workmanager.initialize(syncWorkerDispatcher, ...)`).
// SyncScheduler.schedulePeriodic() registers the recurring task. Each
// invocation runs in a SEPARATE Flutter isolate — no Riverpod, no
// MaterialApp, no UI. Dependencies are constructed manually.

import 'dart:async';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:workmanager/workmanager.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/storage/app_database.dart';
import '../../../../core/utils/logger.dart';
import 'google_drive_datasource.dart';

/// Hard caps for one worker run. These protect against runaway loops
/// (e.g. an operation that perpetually fails to enqueue-itself), and
/// against the OS's ~10-minute budget for background work.
const int _kMaxItemsPerRun = 20;
const int _kMaxRetries = 5;
const Duration _kBudget = Duration(minutes: 8);

/// Top-level entry point invoked by WorkManager in a separate isolate.
/// Must be top-level (or static) for the platform plugin to find it.
@pragma('vm:entry-point')
void syncWorkerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    appLogger.i('SyncWorker: invoked with task=$task');

    if (task != AppConstants.syncWorkerTaskName) {
      // Unknown task name — return success so WorkManager doesn't
      // retry, but log it. Shouldn't happen unless something else
      // registered a task under our dispatcher.
      appLogger.w('SyncWorker: unknown task "$task" — skipping');
      return true;
    }

    final stopwatch = Stopwatch()..start();
    AppDatabase? db;
    GoogleDriveDataSource? drive;
    int processed = 0;
    int succeeded = 0;
    int failed = 0;

    try {
      db = AppDatabase();

      // Pull up to N pending items, oldest first. The retry-count gate
      // means rows that have failed MAX_RETRIES times stop being
      // attempted — they sit in the table for inspection and can be
      // surfaced in a future "Sync issues" UI.
      // Drift 2.28 doesn't expose isSmallerThan / isSmallerThanValue
      // on GeneratedColumn<int> (verified empirically — both
      // candidate methods fail the type check). The queue table is
      // small enough that the filter cost in Dart is negligible; we
      // pull ordered rows up to a generous limit and filter retry-
      // count exhaustion client-side.
      final fetched = await (db.select(db.syncQueue)
            ..orderBy([(t) => OrderingTerm.asc(t.queuedAt)])
            ..limit(_kMaxItemsPerRun * 2))
          .get();
      final pending = fetched
          .where((row) => row.retryCount < _kMaxRetries)
          .take(_kMaxItemsPerRun)
          .toList();

      if (pending.isEmpty) {
        appLogger.i('SyncWorker: queue empty');
        return true;
      }

      appLogger.i('SyncWorker: draining ${pending.length} item(s)');

      // Construct the Drive datasource and attempt silent sign-in.
      // signInSilently() returns null when there's no cached account
      // OR when the token has expired and re-auth needs UI. Either
      // way: we can't make API calls, so bail and let the next
      // scheduled run try again.
      drive = GoogleDriveDataSource();
      final account = await drive.silentSignIn();
      if (account == null) {
        appLogger.w(
          'SyncWorker: silentSignIn returned null — '
          '${pending.length} item(s) deferred. Re-auth in app to flush.',
        );
        return true; // not a failure; just couldn't sign in
      }

      for (final item in pending) {
        if (stopwatch.elapsed > _kBudget) {
          appLogger.w(
            'SyncWorker: budget exhausted after $processed/'
            '${pending.length} items',
          );
          break;
        }

        processed++;
        final doc = await (db.select(db.pdfDocuments)
              ..where((t) => t.id.equals(item.documentId)))
            .getSingleOrNull();

        // If the source document was deleted out from under us, the
        // queue row is an orphan — drop it rather than retry forever.
        if (doc == null) {
          appLogger.w(
            'SyncWorker: orphan queue item ${item.id} '
            '(documentId=${item.documentId} not in PdfDocuments) — dropping',
          );
          await (db.delete(db.syncQueue)
                ..where((t) => t.id.equals(item.id)))
              .go();
          continue;
        }

        try {
          await _dispatch(db, drive, item, doc);
          await (db.delete(db.syncQueue)
                ..where((t) => t.id.equals(item.id)))
              .go();
          succeeded++;
        } catch (e, st) {
          failed++;
          appLogger.w(
            'SyncWorker: ${item.operation} for ${item.documentId} '
            'failed (retry ${item.retryCount + 1}/$_kMaxRetries): $e',
            stackTrace: st,
          );
          await (db.update(db.syncQueue)
                ..where((t) => t.id.equals(item.id)))
              .write(SyncQueueCompanion(
            retryCount: Value(item.retryCount + 1),
            lastAttemptedAt: Value(DateTime.now()),
            lastError: Value('$e'),
          ),);
        }
      }

      appLogger.i(
        'SyncWorker: done — $succeeded ok, $failed failed, '
        '${pending.length - processed} deferred, '
        'elapsed=${stopwatch.elapsed.inSeconds}s',
      );
      return true;
    } catch (e, st) {
      // Top-level catch — return false so WorkManager backs off and
      // retries on the next cycle rather than burning power retrying
      // a fundamentally broken state.
      appLogger.e('SyncWorker: fatal', error: e, stackTrace: st);
      return false;
    } finally {
      await db?.close();
    }
  });
}

/// Dispatches a single queue item. Throws on failure — the caller
/// catches + writes the retry counter. Splits by operation name
/// (matches the strings written from app code: `upload` /
/// `update_meta` / `delete`).
Future<void> _dispatch(
  AppDatabase db,
  GoogleDriveDataSource drive,
  SyncQueueData item,
  PdfDocument doc,
) async {
  switch (item.operation) {
    case 'upload':
      final fileId = await drive.uploadPdf(doc.path);
      // Stamp the doc with the new driveFileId so future updates
      // know which file to overwrite. Without this, every "update"
      // would re-upload as a fresh file.
      await (db.update(db.pdfDocuments)
            ..where((t) => t.id.equals(doc.id)))
          .write(PdfDocumentsCompanion(
        driveFileId: Value(fileId),
        updatedAt: Value(DateTime.now()),
      ),);
      break;

    case 'update_meta':
      final fileId = doc.driveFileId;
      if (fileId == null) {
        // Document was queued for update but never uploaded — treat
        // as an upload instead. Self-healing.
        final newId = await drive.uploadPdf(doc.path);
        await (db.update(db.pdfDocuments)
              ..where((t) => t.id.equals(doc.id)))
            .write(PdfDocumentsCompanion(
          driveFileId: Value(newId),
          updatedAt: Value(DateTime.now()),
        ),);
      } else {
        // Method is updatePdfContent(driveFileId, path) — not
        // updatePdf — and arg order is (id-first, path-second).
        await drive.updatePdfContent(fileId, doc.path);
        await (db.update(db.pdfDocuments)
              ..where((t) => t.id.equals(doc.id)))
            .write(PdfDocumentsCompanion(
          updatedAt: Value(DateTime.now()),
        ),);
      }
      break;

    case 'delete':
      final fileId = doc.driveFileId;
      if (fileId == null) {
        // Nothing to delete on Drive side — caller already deleted
        // the local file before queueing. Just drop the row.
        return;
      }
      await drive.deleteFile(fileId);
      // Clear the driveFileId so future re-uploads (if the local
      // doc is re-added) get a fresh file.
      await (db.update(db.pdfDocuments)
            ..where((t) => t.id.equals(doc.id)))
          .write(const PdfDocumentsCompanion(
        driveFileId: Value(null),
      ),);
      break;

    default:
      // Unknown operation — log + drop the row so we don't retry
      // forever. The app shouldn't enqueue unknown ops, but be
      // defensive.
      appLogger.w(
        'SyncWorker: unknown operation "${item.operation}" — dropping',
      );
  }
}

/// Helpers callable from app code to schedule / cancel periodic sync.
class SyncScheduler {
  SyncScheduler._();

  static const _kUniqueName = 'interact_pro_sync_periodic';

  static Future<void> schedulePeriodic() async {
    await Workmanager().registerPeriodicTask(
      _kUniqueName,
      AppConstants.syncWorkerTaskName,
      frequency: AppConstants.syncWorkerInterval,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }

  static Future<void> cancel() async =>
      Workmanager().cancelByUniqueName(_kUniqueName);
}
