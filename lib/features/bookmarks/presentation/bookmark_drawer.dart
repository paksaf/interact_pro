// SPDX-License-Identifier: AGPL-3.0
//
// Bookmark drawer — bottom sheet (mobile) / side panel (tablet/TV) that
// lists all bookmarks on the currently-open PDF. Tap a row to jump to
// that page. Long-press → edit/delete menu.
//
// Phase 1 MVP: page-level bookmarks, single tap row = jump.
// Phase 2 will add: region preview thumbnails, drag-reorder.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../data/bookmark_repository.dart';
import 'add_bookmark_sheet.dart';
import 'bookmark_provider.dart';

/// Open the bookmark drawer as a modal bottom sheet. Returns the page
/// index of a bookmark the user tapped to navigate to (caller jumps
/// the PDF viewer), or null if they closed without picking.
Future<int?> showBookmarkDrawer(
  BuildContext context, {
  required String documentId,
  required String documentTitle,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BookmarkDrawer(
      documentId: documentId,
      documentTitle: documentTitle,
    ),
  );
}

class BookmarkDrawer extends ConsumerWidget {
  const BookmarkDrawer({
    required this.documentId,
    required this.documentTitle,
    super.key,
  });

  final String documentId;
  final String documentTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarksAsync = ref.watch(bookmarksForDocumentProvider(documentId));
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            // Drag handle + title
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.bookmarks_outlined, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Bookmarks',
                            style: Theme.of(context).textTheme.titleMedium,),
                        Text(
                          documentTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Bookmark list
            Expanded(
              child: bookmarksAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child:
                        Text('Failed to load: $e',
                            style: TextStyle(color: cs.error),),
                  ),
                ),
                data: (bookmarks) {
                  if (bookmarks.isEmpty) {
                    return _EmptyState();
                  }
                  return ListView.separated(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: bookmarks.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final b = bookmarks[i];
                      return _BookmarkRow(
                        bookmark: b,
                        onTap: () => Navigator.of(context).pop(b.pageIndex),
                        onEdit: () async {
                          await showEditBookmarkSheet(
                            context,
                            bookmark: b,
                          );
                          ref.invalidate(
                              bookmarksForDocumentProvider(documentId),);
                          ref.invalidate(bookmarkCountProvider(documentId));
                        },
                        onDelete: () async {
                          final ok = await _confirmDelete(context);
                          if (ok != true) return;
                          await ref
                              .read(bookmarkRepositoryProvider)
                              .delete(b.id);
                          ref.invalidate(
                              bookmarksForDocumentProvider(documentId),);
                          ref.invalidate(bookmarkCountProvider(documentId));
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete bookmark?'),
        content: const Text(
          'This removes the bookmark from your reference diary. The PDF '
          'page is unaffected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({
    required this.bookmark,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final Bookmark bookmark;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final color = Color(bookmarkColorArgb(bookmark.color));
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.bookmark, color: color, size: 18),
      ),
      title: Text(
        'Page ${bookmark.pageIndex + 1}',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: bookmark.note != null && bookmark.note!.trim().isNotEmpty
          ? Text(
              bookmark.note!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : Text(
              'Added ${_relativeTime(bookmark.createdAt)}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (action) {
          if (action == 'edit') onEdit();
          if (action == 'delete') onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border,
                size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.4),),
            const SizedBox(height: 12),
            Text(
              'No bookmarks yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the bookmark icon while viewing a page to flag it. '
              'Use different colors to build a personal reference diary '
              'across your library.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
