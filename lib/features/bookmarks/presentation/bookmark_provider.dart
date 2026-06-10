// SPDX-License-Identifier: AGPL-3.0
//
// Riverpod providers for the bookmark feature (task #1).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../data/bookmark_repository.dart';

final bookmarkRepositoryProvider = Provider<BookmarkRepository>((ref) {
  return BookmarkRepository(db: ref.watch(appDatabaseProvider));
});

/// Bookmarks on a specific document, ordered by page. Used by the
/// viewer's bookmark drawer.
final bookmarksForDocumentProvider =
    FutureProvider.family<List<Bookmark>, String>((ref, documentId) {
  return ref.watch(bookmarkRepositoryProvider).bookmarksForDocument(documentId);
});

/// Bookmark count on a specific document — feeds the badge on the
/// toolbar bookmark icon.
final bookmarkCountProvider =
    FutureProvider.family<int, String>((ref, documentId) {
  return ref.watch(bookmarkRepositoryProvider).countForDocument(documentId);
});

/// All bookmarks across the library, newest first. Used by the
/// reference-diary screen.
final allBookmarksProvider =
    FutureProvider.family<List<BookmarkWithDoc>, String?>((ref, color) {
  return ref.watch(bookmarkRepositoryProvider).allBookmarks(color: color);
});

/// Bookmarks grouped by color across the library. Used by the
/// reference-diary screen in "group by color" mode.
final bookmarksByColorProvider =
    FutureProvider<Map<String, List<BookmarkWithDoc>>>((ref) {
  return ref.watch(bookmarkRepositoryProvider).bookmarksByColor();
});

/// User's currently-selected color filter on the reference diary
/// screen. Null means "show all colors".
final referenceDiaryColorFilterProvider = StateProvider<String?>((_) => null);

/// Whether the reference diary screen shows the flat list or the
/// grouped-by-color view. Persisted across screen rebuilds.
final referenceDiaryGroupedProvider = StateProvider<bool>((_) => false);
