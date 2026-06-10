// SPDX-License-Identifier: AGPL-3.0
//
// Bookmark repository — drift queries for the bookmark + reference
// diary feature (task #1).
//
// Phase 1 MVP responsibilities:
//   - CRUD on bookmarks (create / update note + color / delete)
//   - Per-PDF query: bookmarks for the currently open doc, ordered by page
//   - Cross-PDF query: ALL bookmarks across the library for the reference
//     diary screen, optionally filtered by color
//
// Phase 2 (deferred):
//   - Region selection (drag a rect on the page) — schema cols are
//     already present, just needs UI + write path
//   - Bookmark export/share via LAN payload extension
//
// Color values are stored as enum-like strings ('red' / 'orange' / etc.)
// — kept as strings so raw DB dumps stay human-readable and we don't
// have to maintain a magic-int → name map in three places.

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart' as uuid_pkg;

import '../../../core/storage/app_database.dart';

/// Canonical bookmark flag colors. Order matters for the picker UI —
/// users see them in this sequence.
const bookmarkColors = <String>[
  'red',
  'orange',
  'yellow',
  'green',
  'blue',
  'purple',
  'grey',
];

/// Map color name → ARGB int for rendering. Kept here rather than in
/// the widget so the reference-diary screen and the in-PDF flag icon
/// share the same palette without duplication.
int bookmarkColorArgb(String name) {
  switch (name) {
    case 'red':
      return 0xFFE53935; // Material red 600
    case 'orange':
      return 0xFFFB8C00; // Material orange 600
    case 'yellow':
      return 0xFFFDD835; // Material yellow 600 — readable on light bg
    case 'green':
      return 0xFF43A047; // Material green 600
    case 'blue':
      return 0xFF1E88E5; // Material blue 600
    case 'purple':
      return 0xFF8E24AA; // Material purple 600
    case 'grey':
    default:
      return 0xFF757575; // Material grey 600 — fallback
  }
}

/// Bundle a bookmark with its parent document's title — used by the
/// reference-diary screen to render "page N of <doc>" rows without a
/// second query per row.
class BookmarkWithDoc {
  const BookmarkWithDoc({required this.bookmark, required this.document});
  final Bookmark bookmark;
  final PdfDocument document;
}

class BookmarkRepository {
  BookmarkRepository({required AppDatabase db}) : _db = db;

  final AppDatabase _db;
  static const _uuid = uuid_pkg.Uuid();

  /// Bookmarks on a specific document, ordered by page index ascending.
  /// Used by the bookmark drawer in the viewer.
  Future<List<Bookmark>> bookmarksForDocument(String documentId) {
    return (_db.select(_db.bookmarks)
          ..where((t) => t.documentId.equals(documentId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.pageIndex),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  /// Count bookmarks on a specific document — used by the toolbar
  /// badge so users see at a glance "this PDF has 5 bookmarks".
  Future<int> countForDocument(String documentId) async {
    final rows = await bookmarksForDocument(documentId);
    return rows.length;
  }

  /// All bookmarks across the library, newest first. Used by the
  /// reference-diary screen. Optionally filtered by [color] (one of
  /// [bookmarkColors]) — pass null to get everything.
  ///
  /// Joins onto PdfDocuments so each row has its parent doc's title
  /// + path — saves a per-row second query in the UI.
  Future<List<BookmarkWithDoc>> allBookmarks({String? color}) async {
    final query = _db.select(_db.bookmarks).join([
      innerJoin(
        _db.pdfDocuments,
        _db.pdfDocuments.id.equalsExp(_db.bookmarks.documentId),
      ),
    ])
      ..orderBy([OrderingTerm.desc(_db.bookmarks.updatedAt)]);
    if (color != null && bookmarkColors.contains(color)) {
      query.where(_db.bookmarks.color.equals(color));
    }
    final rows = await query.get();
    return rows
        .map((r) => BookmarkWithDoc(
              bookmark: r.readTable(_db.bookmarks),
              document: r.readTable(_db.pdfDocuments),
            ),)
        .toList();
  }

  /// Bookmarks grouped by color — used by the reference-diary screen
  /// when the user toggles "Group by color" mode. Maps each color to
  /// the list of bookmarks of that color, with parent doc joined in.
  Future<Map<String, List<BookmarkWithDoc>>> bookmarksByColor() async {
    final all = await allBookmarks();
    final out = <String, List<BookmarkWithDoc>>{};
    for (final c in bookmarkColors) {
      out[c] = <BookmarkWithDoc>[];
    }
    for (final bm in all) {
      out.putIfAbsent(bm.bookmark.color, () => <BookmarkWithDoc>[]).add(bm);
    }
    // Strip empty buckets so the UI doesn't render dead sections.
    out.removeWhere((_, v) => v.isEmpty);
    return out;
  }

  /// Create a new bookmark at [pageIndex] of [documentId] with the
  /// given [color] + optional [note]. When all four region* values are
  /// supplied (page-relative fractional coords in [0..1]) the bookmark
  /// pins to a sub-region of the page rather than the whole page; pass
  /// all four as null to bookmark the page itself (Phase 1 behaviour).
  /// Returns the inserted row.
  Future<Bookmark> create({
    required String documentId,
    required int pageIndex,
    String color = 'blue',
    String? note,
    double? regionX,
    double? regionY,
    double? regionWidth,
    double? regionHeight,
  }) async {
    final safeColor =
        bookmarkColors.contains(color) ? color : 'blue';
    final now = DateTime.now();
    // Either all four region fields are set or all four are null — a
    // partial region would render as an invalid rect downstream. Treat
    // any null as "whole page" so the UI can't accidentally save a
    // half-defined region.
    final hasFullRegion = regionX != null &&
        regionY != null &&
        regionWidth != null &&
        regionHeight != null;
    final row = BookmarksCompanion(
      id: Value(_uuid.v4()),
      documentId: Value(documentId),
      pageIndex: Value(pageIndex),
      color: Value(safeColor),
      note: Value(note),
      regionX: hasFullRegion ? Value(regionX) : const Value.absent(),
      regionY: hasFullRegion ? Value(regionY) : const Value.absent(),
      regionWidth:
          hasFullRegion ? Value(regionWidth) : const Value.absent(),
      regionHeight:
          hasFullRegion ? Value(regionHeight) : const Value.absent(),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    return _db.into(_db.bookmarks).insertReturning(row);
  }

  /// Edit an existing bookmark's note, color, and/or region. Any
  /// parameter left null is preserved. The `region*` quad is treated
  /// as a single update: pass [setRegionToWholePage]=true to clear all
  /// four fields back to null (whole-page bookmark), or supply all
  /// four `newRegion*` values to switch to a sub-region. Mixing is
  /// rejected at the call-site (sheet) since a partial region would
  /// render as an invalid rect.
  Future<void> update({
    required String bookmarkId,
    String? newNote,
    String? newColor,
    double? newRegionX,
    double? newRegionY,
    double? newRegionWidth,
    double? newRegionHeight,
    bool setRegionToWholePage = false,
  }) async {
    final safeColor = newColor != null && bookmarkColors.contains(newColor)
        ? newColor
        : null;
    final hasNewRegion = newRegionX != null &&
        newRegionY != null &&
        newRegionWidth != null &&
        newRegionHeight != null;
    await (_db.update(_db.bookmarks)..where((t) => t.id.equals(bookmarkId)))
        .write(BookmarksCompanion(
      note: newNote != null ? Value(newNote) : const Value.absent(),
      color: safeColor != null ? Value(safeColor) : const Value.absent(),
      // Three states for region:
      //  - hasNewRegion → set to new fractional coords
      //  - setRegionToWholePage → clear to null (whole page)
      //  - neither → preserve existing values (Value.absent)
      regionX: hasNewRegion
          ? Value(newRegionX)
          : (setRegionToWholePage
              ? const Value(null)
              : const Value.absent()),
      regionY: hasNewRegion
          ? Value(newRegionY)
          : (setRegionToWholePage
              ? const Value(null)
              : const Value.absent()),
      regionWidth: hasNewRegion
          ? Value(newRegionWidth)
          : (setRegionToWholePage
              ? const Value(null)
              : const Value.absent()),
      regionHeight: hasNewRegion
          ? Value(newRegionHeight)
          : (setRegionToWholePage
              ? const Value(null)
              : const Value.absent()),
      updatedAt: Value(DateTime.now()),
    ),);
  }

  /// Delete a bookmark. Idempotent.
  Future<int> delete(String bookmarkId) {
    return (_db.delete(_db.bookmarks)..where((t) => t.id.equals(bookmarkId)))
        .go();
  }

  /// Delete ALL bookmarks for a document — used when a document is
  /// removed from the library so we don't accumulate orphans.
  Future<int> deleteAllForDocument(String documentId) {
    return (_db.delete(_db.bookmarks)
          ..where((t) => t.documentId.equals(documentId)))
        .go();
  }
}
