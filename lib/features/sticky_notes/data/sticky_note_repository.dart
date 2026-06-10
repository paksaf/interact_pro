// SPDX-License-Identifier: AGPL-3.0
//
// Sticky notes repository — drift CRUD + media file housekeeping.
//
// One sticky note = one row in StickyNotes + optionally one media file
// under <appSupport>/sticky_notes/. When the row is hard-deleted (via
// the 30-day archive sweep, or an explicit "delete forever"), we clean
// up the matching file too. Soft-delete (archivedAt set) leaves the
// file alone so undo restores the note unmodified.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart';

const _uuid = Uuid();

/// One of: 'text', 'voice', 'image', 'handwriting'. Kept as a string
/// in the DB so raw dumps stay self-documenting (matches Pro's Bookmarks
/// color column).
enum StickyNoteKind {
  text('text'),
  voice('voice'),
  image('image'),
  handwriting('handwriting');

  const StickyNoteKind(this.dbValue);
  final String dbValue;

  static StickyNoteKind fromDbValue(String v) =>
      StickyNoteKind.values.firstWhere(
        (e) => e.dbValue == v,
        orElse: () => StickyNoteKind.text,
      );
}

/// Available sticky colors. The grid card draws a paper-yellow / pastel
/// background based on this; the picker UI surfaces the same six.
const stickyColors = <String>[
  'yellow', 'pink', 'green', 'blue', 'purple', 'grey',
];

/// Composite filter for the Notes screen.
class StickyNoteFilter {
  const StickyNoteFilter({
    this.kinds = const {},
    this.documentId,
    this.query,
    this.showArchived = false,
  });

  /// Empty set = all kinds.
  final Set<StickyNoteKind> kinds;
  /// When set, narrows to notes pinned to a specific document.
  final String? documentId;
  /// Free-text search across title + body. Case-insensitive.
  final String? query;
  /// True to show only soft-deleted rows ("Trash" tab).
  final bool showArchived;
}

class StickyNoteRepository {
  StickyNoteRepository(this._db);
  final AppDatabase _db;

  /// Watch all notes matching [filter]. Re-emits whenever the table
  /// changes — bind via Riverpod stream provider.
  Stream<List<StickyNote>> watch(StickyNoteFilter filter) {
    final q = _db.select(_db.stickyNotes);
    if (filter.showArchived) {
      q.where((t) => t.archivedAt.isNotNull());
    } else {
      q.where((t) => t.archivedAt.isNull());
    }
    if (filter.kinds.isNotEmpty) {
      final values = filter.kinds.map((k) => k.dbValue).toList();
      q.where((t) => t.kind.isIn(values));
    }
    if (filter.documentId != null) {
      q.where((t) => t.documentId.equals(filter.documentId!));
    }
    if (filter.query != null && filter.query!.trim().isNotEmpty) {
      final like = '%${filter.query!.trim().toLowerCase()}%';
      q.where((t) =>
          t.title.lower().like(like) | t.body.lower().like(like));
    }
    // Pinned first, then most-recent-updated.
    q.orderBy([
      (t) => OrderingTerm.desc(t.pinned),
      (t) => OrderingTerm.desc(t.updatedAt),
    ]);
    return q.watch();
  }

  Future<StickyNote?> findById(String id) =>
      (_db.select(_db.stickyNotes)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// Generate a UUID + claim the media file path for a new note. Caller
  /// writes media bytes to the returned path BEFORE calling [insert].
  Future<({String id, String mediaPath})> reserveMediaSlot(
    StickyNoteKind kind,
  ) async {
    final id = _uuid.v4();
    final dir = await _mediaDir();
    final ext = switch (kind) {
      StickyNoteKind.voice        => 'm4a',
      StickyNoteKind.image        => 'png',
      StickyNoteKind.handwriting  => 'png',
      StickyNoteKind.text         => 'txt',
    };
    return (id: id, mediaPath: p.join(dir, '$id.$ext'));
  }

  Future<String> insert({
    required String id,
    required StickyNoteKind kind,
    String? title,
    String? body,
    String? audioPath,
    String? imagePath,
    String? handwritingPath,
    int? durationMs,
    String? documentId,
    int? pageIndex,
    double? scrollFraction,
    String? contextRoute,
    String color = 'yellow',
    bool pinned = false,
    String? tags,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.into(_db.stickyNotes).insert(StickyNotesCompanion.insert(
          id: id,
          kind: kind.dbValue,
          title: Value(title),
          body: Value(body),
          audioPath: Value(audioPath),
          imagePath: Value(imagePath),
          handwritingPath: Value(handwritingPath),
          durationMs: Value(durationMs),
          documentId: Value(documentId),
          pageIndex: Value(pageIndex),
          scrollFraction: Value(scrollFraction),
          contextRoute: Value(contextRoute),
          color: Value(color),
          pinned: Value(pinned),
          tags: Value(tags),
          createdAt: now,
          updatedAt: now,
        ),);
    return id;
  }

  Future<void> updateBody(String id, {String? title, String? body, String? color}) async {
    await (_db.update(_db.stickyNotes)..where((t) => t.id.equals(id)))
        .write(StickyNotesCompanion(
          title:     Value(title),
          body:      Value(body),
          color:     color != null ? Value(color) : const Value.absent(),
          updatedAt: Value(DateTime.now().toUtc()),
        ));
  }

  Future<void> togglePinned(String id, bool pinned) async {
    await (_db.update(_db.stickyNotes)..where((t) => t.id.equals(id)))
        .write(StickyNotesCompanion(
          pinned:    Value(pinned),
          updatedAt: Value(DateTime.now().toUtc()),
        ));
  }

  /// Soft-delete — sets archivedAt. The note disappears from the main
  /// grid but survives in "Trash" for 30 days. Media file is kept so
  /// undo restores the note unmodified.
  Future<void> archive(String id) async {
    await (_db.update(_db.stickyNotes)..where((t) => t.id.equals(id)))
        .write(StickyNotesCompanion(archivedAt: Value(DateTime.now().toUtc())));
  }

  Future<void> unarchive(String id) async {
    await (_db.update(_db.stickyNotes)..where((t) => t.id.equals(id)))
        .write(const StickyNotesCompanion(archivedAt: Value(null)));
  }

  /// Hard-delete — removes the row + the media file. Used by the 30-day
  /// archive sweep and by explicit "delete forever" from the Trash tab.
  Future<void> deleteForever(String id) async {
    final note = await findById(id);
    if (note == null) return;
    for (final path in [note.audioPath, note.imagePath, note.handwritingPath]) {
      if (path == null) continue;
      try { await File(path).delete(); } catch (_) {/* already gone */}
    }
    await (_db.delete(_db.stickyNotes)..where((t) => t.id.equals(id))).go();
  }

  /// Sweep archived rows older than [olderThanDays]. Called by the
  /// startup janitor — see StickyNoteJanitor.run().
  Future<int> sweepArchived({int olderThanDays = 30}) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: olderThanDays));
    final rows = await (_db.select(_db.stickyNotes)
          ..where((t) => t.archivedAt.isNotNull() & t.archivedAt.isSmallerThanValue(cutoff)))
        .get();
    for (final r in rows) {
      await deleteForever(r.id);
    }
    return rows.length;
  }

  Future<String> _mediaDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'sticky_notes'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }
}

// ─── Providers ─────────────────────────────────────────────────────────

final stickyNoteRepositoryProvider = Provider<StickyNoteRepository>((ref) {
  return StickyNoteRepository(ref.watch(appDatabaseProvider));
});

/// Reactive list of notes for the current filter. Bind from NotesScreen.
final stickyNotesProvider = StreamProvider.family<List<StickyNote>, StickyNoteFilter>(
  (ref, filter) => ref.watch(stickyNoteRepositoryProvider).watch(filter),
);

/// Auto-captured location reference. Set by BookViewer when the user
/// taps "+ note" inside a book; null elsewhere so the capture sheet
/// defaults to "anywhere" / contextRoute.
class NoteLocationRef {
  const NoteLocationRef({
    this.documentId,
    this.pageIndex,
    this.scrollFraction,
    this.contextRoute,
  });
  final String? documentId;
  final int? pageIndex;
  final double? scrollFraction;
  final String? contextRoute;

  static const empty = NoteLocationRef();
}

final currentNoteLocationProvider = StateProvider<NoteLocationRef>(
  (_) => NoteLocationRef.empty,
);
