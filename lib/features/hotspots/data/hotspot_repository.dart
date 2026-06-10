import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/failures.dart';
import '../../../core/storage/app_database.dart' as db;
import '../../../core/utils/result.dart';
import '../domain/hotspot.dart';

/// Drift-backed implementation. Hotspots persist across app restarts and
/// reference the [PdfDocuments] row by foreign key.
final hotspotRepositoryProvider = Provider<HotspotRepository>((ref) {
  return DriftHotspotRepository(ref.watch(db.appDatabaseProvider));
});

/// Live-stream every [Hotspot] for [documentUuid]. Drift recomputes when
/// any insert/update/delete touches the [Hotspots] table for this id.
final hotspotsForDocumentProvider =
    StreamProvider.family<List<Hotspot>, String>((ref, documentUuid) {
  final database = ref.watch(db.appDatabaseProvider);
  final query = database.select(database.hotspots)
    ..where((t) => t.documentId.equals(documentUuid))
    ..orderBy([
      (t) => OrderingTerm.asc(t.pageIndex),
      (t) => OrderingTerm.asc(t.createdAt),
    ]);
  return query.watch().map((rows) => rows.map(_rowToDomain).toList());
});

abstract class HotspotRepository {
  Future<Result<List<Hotspot>>> listForDocument(String documentUuid);
  Future<Result<Hotspot>> add(Hotspot hotspot);
  Future<Result<void>> remove(String hotspotId);
}

// ── Mappers ─────────────────────────────────────────────────────────────

Hotspot _rowToDomain(db.Hotspot row) {
  final kind = _kindFromString(row.type);
  final payload = switch (kind) {
    HotspotKind.note => NotePayload(row.content),
    HotspotKind.link => LinkPayload(row.content),
    HotspotKind.image => ImagePayload(row.content),
    HotspotKind.audio => AudioPayload(row.content),
  };
  return Hotspot(
    id: row.id,
    documentUuid: row.documentId,
    // Schema keeps page 0-indexed; domain entity is 1-indexed for display.
    pageNumber: row.pageIndex + 1,
    kind: kind,
    bounds: [row.x, row.y, row.x + row.width, row.y + row.height],
    payload: payload,
    createdAt: row.createdAt,
  );
}

HotspotKind _kindFromString(String s) => switch (s) {
      'note' => HotspotKind.note,
      'link' => HotspotKind.link,
      'image' => HotspotKind.image,
      'audio' => HotspotKind.audio,
      // Legacy rows used 'video' before we settled on 'audio' for media.
      'video' => HotspotKind.audio,
      _ => HotspotKind.note,
    };

String _kindToString(HotspotKind k) => switch (k) {
      HotspotKind.note => 'note',
      HotspotKind.link => 'link',
      HotspotKind.image => 'image',
      HotspotKind.audio => 'audio',
    };

String _payloadToContent(HotspotPayload p) => switch (p) {
      NotePayload(:final text) => text,
      LinkPayload(:final url) => url,
      ImagePayload(:final imagePath) => imagePath,
      AudioPayload(:final audioPath) => audioPath,
    };

class DriftHotspotRepository implements HotspotRepository {
  DriftHotspotRepository(this._db) : _uuid = const Uuid();
  final db.AppDatabase _db;
  final Uuid _uuid;

  @override
  Future<Result<List<Hotspot>>> listForDocument(String documentUuid) async {
    try {
      final rows = await (_db.select(_db.hotspots)
            ..where((t) => t.documentId.equals(documentUuid)))
          .get();
      return Result.ok(rows.map(_rowToDomain).toList());
    } catch (e) {
      return Result.err(StorageFailure('Could not list hotspots', cause: e));
    }
  }

  @override
  Future<Result<Hotspot>> add(Hotspot hotspot) async {
    try {
      final id = hotspot.id.isEmpty ? _uuid.v4() : hotspot.id;
      final left = hotspot.bounds[0];
      final top = hotspot.bounds[1];
      final right = hotspot.bounds[2];
      final bottom = hotspot.bounds[3];
      await _db.into(_db.hotspots).insertOnConflictUpdate(db.HotspotsCompanion(
            id: Value(id),
            documentId: Value(hotspot.documentUuid),
            pageIndex: Value(hotspot.pageNumber - 1),
            x: Value(left),
            y: Value(top),
            width: Value(right - left),
            height: Value(bottom - top),
            type: Value(_kindToString(hotspot.kind)),
            content: Value(_payloadToContent(hotspot.payload)),
            createdAt: Value(hotspot.createdAt),
          ),);
      return Result.ok(Hotspot(
        id: id,
        documentUuid: hotspot.documentUuid,
        pageNumber: hotspot.pageNumber,
        kind: hotspot.kind,
        bounds: hotspot.bounds,
        payload: hotspot.payload,
        createdAt: hotspot.createdAt,
      ),);
    } catch (e) {
      return Result.err(StorageFailure('Could not save hotspot', cause: e));
    }
  }

  @override
  Future<Result<void>> remove(String hotspotId) async {
    try {
      await (_db.delete(_db.hotspots)..where((t) => t.id.equals(hotspotId)))
          .go();
      return const Result.ok(null);
    } catch (e) {
      return Result.err(StorageFailure('Could not delete hotspot', cause: e));
    }
  }
}
