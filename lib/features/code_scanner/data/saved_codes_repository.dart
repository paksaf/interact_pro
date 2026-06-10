import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart' as db;

/// Drift-backed CRUD for the [SavedCodes] table. Holds both scans
/// (read from the camera) and generated codes (built from user input).
final savedCodesRepositoryProvider = Provider<SavedCodesRepository>((ref) {
  return SavedCodesRepository(ref.watch(db.appDatabaseProvider));
});

/// Live stream of every saved code, newest first. UI watches this so
/// the history list re-renders the moment a new scan is recorded.
final savedCodesStreamProvider = StreamProvider<List<db.SavedCode>>((ref) {
  return ref.watch(savedCodesRepositoryProvider).watchAll();
});

class SavedCodesRepository {
  SavedCodesRepository(this._db) : _uuid = const Uuid();
  final db.AppDatabase _db;
  final Uuid _uuid;

  /// Source-of-truth strings written to [SavedCodes.origin]. Constants
  /// rather than enums so the column stays migration-friendly without
  /// requiring an enum codec.
  static const String originScanned = 'scanned';
  static const String originGenerated = 'generated';

  Stream<List<db.SavedCode>> watchAll({String? originFilter}) =>
      _db.watchSavedCodes(originFilter: originFilter);

  Future<String> add({
    required String origin,
    required String format,
    required String rawValue,
    String? label,
    String? imagePath,
  }) async {
    final id = _uuid.v4();
    await _db.insertSavedCode(db.SavedCodesCompanion(
      id: Value(id),
      origin: Value(origin),
      format: Value(format),
      rawValue: Value(rawValue),
      label: Value(label),
      imagePath: Value(imagePath),
      createdAt: Value(DateTime.now()),
    ),);
    return id;
  }

  Future<void> remove(String id) => _db.deleteSavedCode(id).then((_) {});
}
