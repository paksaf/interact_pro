// SPDX-License-Identifier: AGPL-3.0
//
// Riverpod providers for the tag feature (task #2).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../data/tag_repository.dart';

final tagRepositoryProvider = Provider<TagRepository>((ref) {
  return TagRepository(db: ref.watch(appDatabaseProvider));
});

/// All tags, sorted by name. Used by the tag manager + the picker sheet.
/// Invalidated whenever a tag is created/renamed/deleted.
final allTagsProvider = FutureProvider<List<Tag>>((ref) {
  return ref.watch(tagRepositoryProvider).allTags();
});

/// Tags applied to a specific document. Used by the per-PDF tag picker
/// to seed the initial selection, and by the library card to show chips.
final tagsForDocumentProvider =
    FutureProvider.family<List<Tag>, String>((ref, documentId) {
  return ref.watch(tagRepositoryProvider).tagsForDocument(documentId);
});

/// Documents that have a given tag. Used by the library filter.
final documentsForTagProvider =
    FutureProvider.family<List<PdfDocument>, String>((ref, tagId) {
  return ref.watch(tagRepositoryProvider).documentsForTag(tagId);
});

/// Currently-active library filter (a tag id, or null = "show all").
/// Plain state provider — the library screen reads + writes.
final activeLibraryTagFilterProvider = StateProvider<String?>((_) => null);
