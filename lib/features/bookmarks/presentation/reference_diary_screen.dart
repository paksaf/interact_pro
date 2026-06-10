// SPDX-License-Identifier: AGPL-3.0
//
// Reference Diary — aggregates ALL bookmarks across every PDF in the
// library, with optional color filter + group-by-color view. Tap a row
// → jumps into that PDF at the bookmarked page.
//
// This is the main user-facing payoff of the bookmark feature: a
// research-grade index built from the highlights you set while reading.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/responsive.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/storage/app_database.dart';
import '../data/bookmark_repository.dart';
import 'bookmark_provider.dart';

class ReferenceDiaryScreen extends ConsumerWidget {
  const ReferenceDiaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorFilter = ref.watch(referenceDiaryColorFilterProvider);
    final grouped = ref.watch(referenceDiaryGroupedProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reference diary'),
        actions: [
          IconButton(
            icon: Icon(grouped ? Icons.view_list : Icons.palette_outlined),
            tooltip: grouped ? 'Show flat list' : 'Group by color',
            onPressed: () =>
                ref.read(referenceDiaryGroupedProvider.notifier).state =
                    !grouped,
          ),
        ],
      ),
      body: LandscapeFormBody(
        child: Column(
        children: [
          // Color filter row — also shown in grouped mode for quick
          // jumping between color sections.
          _ColorFilterRow(
            activeColor: colorFilter,
            onSelect: (c) => ref
                .read(referenceDiaryColorFilterProvider.notifier)
                .state = c,
          ),
          const Divider(height: 1),
          Expanded(
            child: grouped
                ? _GroupedView()
                : _FlatView(colorFilter: colorFilter),
          ),
        ],
      ),
      ),
    );
  }
}

class _ColorFilterRow extends StatelessWidget {
  const _ColorFilterRow({required this.activeColor, required this.onSelect});

  final String? activeColor;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _FilterChip(
            label: 'All',
            color: null,
            selected: activeColor == null,
            onTap: () => onSelect(null),
          ),
          ...bookmarkColors.map((c) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _FilterChip(
                  label: _capitalize(c),
                  color: Color(bookmarkColorArgb(c)),
                  selected: activeColor == c,
                  onTap: () => onSelect(c),
                ),
              ),),
        ],
      ),
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = color ?? cs.primary;
    return Material(
      color: selected ? fg : fg.withValues(alpha: 0.08),
      shape: StadiumBorder(side: BorderSide(color: fg, width: 1)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.check, size: 14, color: Colors.white),
                ),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : fg,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlatView extends ConsumerWidget {
  const _FlatView({required this.colorFilter});
  final String? colorFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(allBookmarksProvider(colorFilter));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load: $e')),
      data: (rows) {
        if (rows.isEmpty) return _EmptyState();
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => _BookmarkRow(item: rows[i]),
        );
      },
    );
  }
}

class _GroupedView extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(bookmarksByColorProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load: $e')),
      data: (groups) {
        if (groups.isEmpty) return _EmptyState();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: groups.length,
          itemBuilder: (_, i) {
            final entry = groups.entries.elementAt(i);
            return _ColorSection(color: entry.key, items: entry.value);
          },
        );
      },
    );
  }
}

class _ColorSection extends StatelessWidget {
  const _ColorSection({required this.color, required this.items});
  final String color;
  final List<BookmarkWithDoc> items;

  @override
  Widget build(BuildContext context) {
    final c = Color(bookmarkColorArgb(color));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_capitalize(color)} · ${items.length}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: c,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        ...items.map((it) => _BookmarkRow(item: it)),
        const Divider(height: 1),
      ],
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({required this.item});
  final BookmarkWithDoc item;

  @override
  Widget build(BuildContext context) {
    final c = Color(bookmarkColorArgb(item.bookmark.color));
    return ListTile(
      onTap: () => context.pushNamed(
        AppRoutes.viewer,
        extra: item.document.path,
        // TODO Phase 2: pass pageIndex as a query param so the viewer
        // jumps directly there. Currently the viewer opens at page 0.
      ),
      leading: _RegionThumb(
        color: c,
        regionX: item.bookmark.regionX,
        regionY: item.bookmark.regionY,
        regionWidth: item.bookmark.regionWidth,
        regionHeight: item.bookmark.regionHeight,
      ),
      title: Text(
        item.document.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // Append a region hint when the bookmark pins a specific
            // tile rather than the whole page. The thumbnail to the
            // left also shows this graphically — the text is for
            // accessibility / screen-reader users who can't see the
            // mini-page indicator.
            _pageLineFor(item.bookmark),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (item.bookmark.note != null &&
              item.bookmark.note!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                item.bookmark.note!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }

  /// Build the "Page N" line, suffixed with the region quadrant when
  /// the bookmark pins a sub-region. We map the stored fractional rect
  /// back to a (row,col) of the 3×3 grid used in the picker so the
  /// label reads consistently with the add-bookmark UX. Bookmarks with
  /// non-grid-aligned regions (e.g. legacy data from a future free-drag
  /// version) just say "Region" without coords so we don't lie about
  /// the tile address.
  String _pageLineFor(Bookmark b) {
    final base = 'Page ${b.pageIndex + 1}';
    if (b.regionX == null ||
        b.regionY == null ||
        b.regionWidth == null ||
        b.regionHeight == null) {
      return base;
    }
    const eps = 0.05;
    final aligned =
        (b.regionWidth! - 1 / 3).abs() < eps &&
            (b.regionHeight! - 1 / 3).abs() < eps;
    if (!aligned) return '$base · region';
    final col = (b.regionX! * 3).round().clamp(0, 2);
    final row = (b.regionY! * 3).round().clamp(0, 2);
    return '$base · tile (${row + 1},${col + 1})';
  }
}

/// Tiny 4:3 page-shape that visualizes which region a bookmark covers.
/// Rendered as the row's leading icon in Reference Diary so a glance
/// down the list tells the user "top-right of this page", "whole of
/// that page", etc. without parsing text.
///
/// All four region* are null → fills the whole page outline (Phase 1
/// bookmarks). Any quad is set → only that fractional rect is filled.
class _RegionThumb extends StatelessWidget {
  const _RegionThumb({
    required this.color,
    required this.regionX,
    required this.regionY,
    required this.regionWidth,
    required this.regionHeight,
  });

  final Color color;
  final double? regionX;
  final double? regionY;
  final double? regionWidth;
  final double? regionHeight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 32,
      height: 32,
      child: Center(
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: CustomPaint(
            painter: _RegionThumbPainter(
              fillColor: color,
              outlineColor: cs.outlineVariant,
              regionX: regionX,
              regionY: regionY,
              regionWidth: regionWidth,
              regionHeight: regionHeight,
            ),
          ),
        ),
      ),
    );
  }
}

class _RegionThumbPainter extends CustomPainter {
  _RegionThumbPainter({
    required this.fillColor,
    required this.outlineColor,
    required this.regionX,
    required this.regionY,
    required this.regionWidth,
    required this.regionHeight,
  });

  final Color fillColor;
  final Color outlineColor;
  final double? regionX;
  final double? regionY;
  final double? regionWidth;
  final double? regionHeight;

  @override
  void paint(Canvas canvas, Size size) {
    // Background fill — very faint so the outline reads as "this is a
    // page" rather than a colored swatch.
    final bg = Paint()..color = fillColor.withValues(alpha: 0.08);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(2),
    );
    canvas.drawRRect(rrect, bg);

    // Active region. Whole-page when any field is null; otherwise the
    // specific fractional rect mapped to widget pixels.
    final isWholePage = regionX == null ||
        regionY == null ||
        regionWidth == null ||
        regionHeight == null;
    final fill = Paint()..color = fillColor.withValues(alpha: 0.55);
    if (isWholePage) {
      canvas.drawRRect(rrect, fill);
    } else {
      final rect = Rect.fromLTWH(
        regionX! * size.width,
        regionY! * size.height,
        regionWidth! * size.width,
        regionHeight! * size.height,
      );
      canvas.drawRect(rect, fill);
    }

    // Outline last so it sits on top of both fills.
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outlineColor;
    canvas.drawRRect(rrect, border);
  }

  @override
  bool shouldRepaint(covariant _RegionThumbPainter old) {
    return old.fillColor != fillColor ||
        old.outlineColor != outlineColor ||
        old.regionX != regionX ||
        old.regionY != regionY ||
        old.regionWidth != regionWidth ||
        old.regionHeight != regionHeight;
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
            Icon(Icons.bookmarks_outlined,
                size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4),),
            const SizedBox(height: 12),
            Text(
              'No bookmarks across your library yet',
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Open any PDF and tap the bookmark icon while viewing a '
              'page. Bookmarks across all your documents land here, '
              'organized by color so you can build a personal reference '
              'diary across the library.',
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
