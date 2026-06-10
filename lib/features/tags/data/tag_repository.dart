// SPDX-License-Identifier: AGPL-3.0
//
// Tag repository — drift queries for the bookshelf tag feature (task #2).
//
// Phase 1 MVP responsibilities:
//   - CRUD on Tags (create / rename / recolor / delete)
//   - Apply / remove tags from PDFs (PdfTags join table)
//   - Query: which tags does this PDF have? which PDFs have this tag?
//
// Phase 2 (deferred):
//   - Color-coded chips in the library grid
//   - Multi-select tag filter
//
// Phase 3 (deferred):
//   - Extend LAN share payload to include tags
//   - PDF XMP metadata read/write so tags survive export to non-Pro

// Import drift unrestricted here — we use innerJoin, OrderingTerm, the
// `&` boolean operator on Expression<bool>, plus Value. No symbol
// collisions in this file so `show ...` would just be friction.
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart' as uuid_pkg;

import '../../../core/storage/app_database.dart';

class TagRepository {
  TagRepository({required AppDatabase db}) : _db = db;

  final AppDatabase _db;
  static const _uuid = uuid_pkg.Uuid();

  /// All tags, ordered by name (case-insensitive). Used by:
  /// - the tag manager screen (Settings)
  /// - the tag picker sheet when applying tags to a PDF
  /// - the filter dropdown in the library
  Future<List<Tag>> allTags() async {
    final rows = await _db.select(_db.tags).get();
    rows.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()),);
    return rows;
  }

  /// Tags applied to a specific PDF. Returns the full Tag rows
  /// (joined via PdfTags), not just the IDs, so the caller can render
  /// chips without a second query.
  Future<List<Tag>> tagsForDocument(String documentId) async {
    final query = _db.select(_db.tags).join([
      innerJoin(
        _db.pdfTags,
        _db.pdfTags.tagId.equalsExp(_db.tags.id),
      ),
    ])
      ..where(_db.pdfTags.documentId.equals(documentId));
    final rows = await query.get();
    final out = rows.map((r) => r.readTable(_db.tags)).toList();
    out.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()),);
    return out;
  }

  /// Documents that have a given tag applied. Used by the library
  /// filter — "show me everything tagged Contracts".
  Future<List<PdfDocument>> documentsForTag(String tagId) async {
    final query = _db.select(_db.pdfDocuments).join([
      innerJoin(
        _db.pdfTags,
        _db.pdfTags.documentId.equalsExp(_db.pdfDocuments.id),
      ),
    ])
      ..where(_db.pdfTags.tagId.equals(tagId))
      ..orderBy([
        OrderingTerm.desc(_db.pdfDocuments.updatedAt),
      ]);
    final rows = await query.get();
    return rows.map((r) => r.readTable(_db.pdfDocuments)).toList();
  }

  /// Create a new tag. Returns the inserted row. Throws [StateError]
  /// if a tag with the same name (case-insensitive) already exists —
  /// callers should catch and show "already exists" in the UI.
  Future<Tag> createTag({
    required String name,
    required String colorHex,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('Tag name cannot be empty');
    final lowered = trimmed.toLowerCase();
    final existing = await allTags();
    if (existing.any((t) => t.name.toLowerCase() == lowered)) {
      throw StateError('Tag "$trimmed" already exists');
    }
    final now = DateTime.now();
    final row = TagsCompanion(
      id: Value(_uuid.v4()),
      name: Value(trimmed),
      colorHex: Value(_normalizeHex(colorHex)),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    return _db.into(_db.tags).insertReturning(row);
  }

  /// Rename and/or recolor an existing tag. Either parameter may be
  /// null to leave unchanged.
  Future<void> updateTag({
    required String tagId,
    String? newName,
    String? newColorHex,
  }) async {
    if (newName != null) {
      final trimmed = newName.trim();
      if (trimmed.isEmpty) throw ArgumentError('Tag name cannot be empty');
      final lowered = trimmed.toLowerCase();
      // Check uniqueness vs. OTHER rows (a tag can keep its own name).
      final existing = await allTags();
      if (existing
          .any((t) => t.id != tagId && t.name.toLowerCase() == lowered)) {
        throw StateError('Another tag named "$trimmed" already exists');
      }
    }
    await (_db.update(_db.tags)..where((t) => t.id.equals(tagId))).write(
      TagsCompanion(
        name: newName != null ? Value(newName.trim()) : const Value.absent(),
        colorHex: newColorHex != null
            ? Value(_normalizeHex(newColorHex))
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Delete a tag. The matching PdfTags rows are cascade-removed by
  /// the FK constraint. Idempotent — deleting a non-existent tag
  /// returns 0 without error.
  Future<int> deleteTag(String tagId) async {
    // Drift doesn't emit ON DELETE CASCADE by default — strip the join
    // rows first, then the tag itself.
    await (_db.delete(_db.pdfTags)..where((t) => t.tagId.equals(tagId))).go();
    return (_db.delete(_db.tags)..where((t) => t.id.equals(tagId))).go();
  }

  /// Apply a tag to a document. No-op if already applied (composite
  /// PK collision triggers insertOnConflictUpdate's update which is
  /// also a no-op).
  Future<void> applyTag({
    required String documentId,
    required String tagId,
  }) {
    return _db.into(_db.pdfTags).insertOnConflictUpdate(
          PdfTagsCompanion(
            documentId: Value(documentId),
            tagId: Value(tagId),
            appliedAt: Value(DateTime.now()),
          ),
        );
  }

  /// Remove a tag from a document. Idempotent.
  Future<int> removeTag({
    required String documentId,
    required String tagId,
  }) {
    return (_db.delete(_db.pdfTags)
          ..where(
            (t) => t.documentId.equals(documentId) & t.tagId.equals(tagId),
          ))
        .go();
  }

  /// Set the exact tag set on a document (idempotent). Convenience for
  /// the tag picker UI: user toggles chips, hits Save, we sync.
  Future<void> setTagsForDocument({
    required String documentId,
    required List<String> tagIds,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.pdfTags)
            ..where((t) => t.documentId.equals(documentId)))
          .go();
      final now = DateTime.now();
      for (final tagId in tagIds) {
        await _db.into(_db.pdfTags).insert(
              PdfTagsCompanion(
                documentId: Value(documentId),
                tagId: Value(tagId),
                appliedAt: Value(now),
              ),
            );
      }
    });
  }

  /// Normalize a user-entered hex color string to lower-case #RRGGBB.
  /// Accepts: "#FFA500", "ffa500", "#fa5", "fa5". Throws [FormatException]
  /// on any other shape so the UI shows a clear error.
  String _normalizeHex(String input) {
    var v = input.trim().toLowerCase();
    if (v.startsWith('#')) v = v.substring(1);
    if (v.length == 3) {
      // Short form: "fa5" → "ffaa55"
      v = v.split('').map((c) => '$c$c').join();
    }
    if (v.length != 6 || !RegExp(r'^[0-9a-f]{6}$').hasMatch(v)) {
      throw FormatException('Color must be #RRGGBB or #RGB hex, got "$input"');
    }
    return '#$v';
  }
}
