import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/device/device_info.dart';
import '../../../../core/layout/responsive.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../viewer/presentation/providers/viewer_provider.dart';
import '../widgets/book_card.dart';
import '../widgets/shelf_row.dart';

/// Library shelf — a "real bookshelf" view of every locally-indexed PDF.
///
/// Compared to the existing `RecentDocuments` list (which is a vertical
/// list of rows), this screen lays the documents out as books standing
/// on wooden shelves. The visual gain matters: a 30-PDF library reads
/// instantly when the user can SEE the covers, vs scanning filenames.
///
/// Tap → open in the regular viewer.
/// Long-press → choose between viewer and book-flip mode.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(allDocumentsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: 'Switch to list view',
            // Always-present focusable target for TV remote D-pad.
            // When the shelf is empty there's nothing else focusable;
            // when it has books, this is the natural "go back" path.
            autofocus: true,
            onPressed: () => context.goNamed(AppRoutes.home),
          ),
        ],
      ),
      body: Container(
        // Warm parchment background so the wood shelves feel like
        // they're inside a study rather than against pure white.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF7EFDC), Color(0xFFE8DABA)],
          ),
        ),
        child: docs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (list) {
            if (list.isEmpty) return const _EmptyShelf();
            return LayoutBuilder(
              builder: (ctx, constraints) {
                final size = WindowSize.of(ctx);
                // Bigger books on tablets — readers expect to actually
                // see the cover content. Phones stay compact so 4 books
                // still fit per shelf.
                final bookHeight = size.isExpanded
                    ? 240.0
                    : (size.isMedium ? 210.0 : 180.0);
                final bookFootprint = bookHeight * 0.72 + 24; // book + gutter
                final perShelf = (constraints.maxWidth / bookFootprint)
                    .floor()
                    .clamp(3, 10);
                final shelves = <List<dynamic>>[];
                for (var i = 0; i < list.length; i += perShelf) {
                  shelves.add(list.sublist(
                    i,
                    (i + perShelf).clamp(0, list.length),
                  ),);
                }
                // On tablets, give the shelf a bit of breathing room on
                // the sides so books don't run into the screen edges.
                final hPad = size.isExpanded
                    ? 32.0
                    : (size.isMedium ? 16.0 : 0.0);
                return ListView.builder(
                  padding: EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: hPad,
                  ),
                  itemCount: shelves.length,
                  itemBuilder: (_, i) {
                    final row = shelves[i];
                    return ShelfRow(
                      books: row
                          .map<Widget>((doc) {
                            // Auto-pick the natural viewer per platform +
                            // doc shape:
                            //  - On TV with multi-page docs, the book-
                            //    flip animation + two-page spread is the
                            //    "right" 10-ft reading experience.
                            //  - On phones / 1-2 page docs, the standard
                            //    annotation-rich viewer is more useful.
                            //  - Long-press still opens the menu to
                            //    override to the other viewer.
                            final pageCount = doc.pageCount as int? ?? 0;
                            final preferBook =
                                DeviceInfo.isAndroidTv && pageCount > 2;
                            final route = preferBook
                                ? AppRoutes.bookViewer
                                : AppRoutes.viewer;
                            return BookCard(
                              pdfPath: doc.path as String,
                              height: bookHeight,
                              onTap: () => context.pushNamed(
                                route,
                                extra: doc.path,
                              ),
                              onLongPress: () =>
                                  _showBookMenu(context, doc.path as String),
                            );
                          })
                          .toList(),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  void _showBookMenu(BuildContext context, String pdfPath) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('Open in book mode'),
              subtitle: const Text(
                'Page-flip view for reading',
              ),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.pushNamed(
                  AppRoutes.bookViewer,
                  extra: pdfPath,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Open in editor view'),
              subtitle: const Text(
                'Full annotation toolset',
              ),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.pushNamed(
                  AppRoutes.viewer,
                  extra: pdfPath,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.menu_book_outlined, size: 96, color: Colors.brown),
          const SizedBox(height: 16),
          Text(
            'Your shelf is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Import a PDF from the home screen to see it here.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
