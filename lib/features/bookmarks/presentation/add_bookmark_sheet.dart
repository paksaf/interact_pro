// SPDX-License-Identifier: AGPL-3.0
//
// Add/edit bookmark bottom sheet. Two modes:
//   - Add: triggered from the bookmark icon in the viewer toolbar.
//     Shows color picker + note field, creates a new bookmark on
//     [pageIndex] of [documentId] when Save is tapped.
//   - Edit: triggered from the bookmark drawer's row menu. Pre-fills
//     with the existing color + note, updates in place on Save.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../data/bookmark_repository.dart';
import 'bookmark_provider.dart';

/// Show the add-bookmark sheet. Returns true if a bookmark was created.
Future<bool> showAddBookmarkSheet(
  BuildContext context, {
  required String documentId,
  required int pageIndex,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _BookmarkSheet(
      documentId: documentId,
      pageIndex: pageIndex,
      existing: null,
    ),
  );
  return result ?? false;
}

/// Show the edit-bookmark sheet. Returns true if changes were saved.
Future<bool> showEditBookmarkSheet(
  BuildContext context, {
  required Bookmark bookmark,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _BookmarkSheet(
      documentId: bookmark.documentId,
      pageIndex: bookmark.pageIndex,
      existing: bookmark,
    ),
  );
  return result ?? false;
}

class _BookmarkSheet extends ConsumerStatefulWidget {
  const _BookmarkSheet({
    required this.documentId,
    required this.pageIndex,
    required this.existing,
  });

  final String documentId;
  final int pageIndex;
  final Bookmark? existing;

  @override
  ConsumerState<_BookmarkSheet> createState() => _BookmarkSheetState();
}

/// 3×3 region grid + whole-page option. Each cell maps to a fractional
/// page rect (0..1). Width/height are 1/3 of the page so the regions
/// tile cleanly with no gaps.
///
/// Indexing convention: `null` = whole page (default). Otherwise a row,col
/// pair (0..2, 0..2) where row 0 is top, col 0 is left. Stored together
/// in [_BookmarkRegion] so the UI can compare equality + look up the rect.
class _BookmarkRegion {
  const _BookmarkRegion(this.row, this.col);
  final int row;
  final int col;

  double get x => col / 3.0;
  double get y => row / 3.0;
  static const double width = 1.0 / 3.0;
  static const double height = 1.0 / 3.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _BookmarkRegion && other.row == row && other.col == col);

  @override
  int get hashCode => Object.hash(row, col);
}

class _BookmarkSheetState extends ConsumerState<_BookmarkSheet> {
  late final TextEditingController _noteCtrl;
  late String _color;

  /// Selected page region. `null` means "whole page" — the default and
  /// the backward-compatible behaviour. Editing an existing bookmark
  /// pre-fills from the stored region* values (also null if Phase 1).
  _BookmarkRegion? _region;

  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController(text: widget.existing?.note ?? '');
    _color = widget.existing?.color ?? 'blue';
    // Reverse-map an existing region rect back to a grid cell. Only
    // valid when all four values are non-null AND aligned to a 1/3
    // tile (within a small epsilon for float drift). Anything else
    // falls back to "whole page" so the UI doesn't render in a weird
    // state — the underlying DB row is untouched until Save.
    final ex = widget.existing;
    if (ex != null &&
        ex.regionX != null &&
        ex.regionY != null &&
        ex.regionWidth != null &&
        ex.regionHeight != null) {
      const eps = 0.05;
      final col = (ex.regionX! * 3).round();
      final row = (ex.regionY! * 3).round();
      if (col >= 0 &&
          col <= 2 &&
          row >= 0 &&
          row <= 2 &&
          (ex.regionWidth! - _BookmarkRegion.width).abs() < eps &&
          (ex.regionHeight! - _BookmarkRegion.height).abs() < eps) {
        _region = _BookmarkRegion(row, col);
      }
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final note = _noteCtrl.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(bookmarkRepositoryProvider);
      if (_isEdit) {
        await repo.update(
          bookmarkId: widget.existing!.id,
          newColor: _color,
          newNote: note,
          // Edit region in lockstep with create: either all four
          // fractional coords or a clear-to-whole-page flag. The
          // sheet's _region state is the single source of truth.
          newRegionX: _region?.x,
          newRegionY: _region?.y,
          newRegionWidth: _region == null ? null : _BookmarkRegion.width,
          newRegionHeight: _region == null ? null : _BookmarkRegion.height,
          setRegionToWholePage: _region == null,
        );
      } else {
        await repo.create(
          documentId: widget.documentId,
          pageIndex: widget.pageIndex,
          color: _color,
          note: note.isEmpty ? null : note,
          // Region: null = whole page (default). When the user picks
          // a 3×3 tile, send all four fractional coords; the repo
          // requires the full quad so a partial set isn't possible.
          regionX: _region?.x,
          regionY: _region?.y,
          regionWidth: _region == null ? null : _BookmarkRegion.width,
          regionHeight: _region == null ? null : _BookmarkRegion.height,
        );
      }
      // Invalidate the providers so all consumers refresh.
      ref.invalidate(bookmarksForDocumentProvider(widget.documentId));
      ref.invalidate(bookmarkCountProvider(widget.documentId));
      ref.invalidate(allBookmarksProvider(null));
      ref.invalidate(bookmarksByColorProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Save failed: $e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(
                    _isEdit ? Icons.edit : Icons.bookmark_add,
                    color: Color(bookmarkColorArgb(_color)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isEdit
                        ? 'Edit bookmark'
                        : 'Bookmark page ${widget.pageIndex + 1}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Flag color',
                  style: Theme.of(context).textTheme.labelMedium,),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: bookmarkColors.map((c) {
                  final selected = c == _color;
                  return GestureDetector(
                    onTap: _busy ? null : () => setState(() => _color = c),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(bookmarkColorArgb(c)),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? cs.onSurface
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: selected
                          ? const Icon(Icons.check,
                              color: Colors.white, size: 20,)
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Text('Region on page',
                  style: Theme.of(context).textTheme.labelMedium,),
              const SizedBox(height: 4),
              Text(
                _region == null
                    ? 'Whole page'
                    : 'Tile (${_region!.row + 1},${_region!.col + 1}) — top-left = (1,1)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 8),
              // 3×3 grid + whole-page chip beneath. The grid renders at
              // a fixed aspect ratio (4:3) so it reads as "this is a
              // page" rather than a sticker grid. Tapping a cell sets
              // the region; tapping the same cell again clears back to
              // whole-page. Cells use a Material InkWell for the ripple
              // so tap target = cell area, not just the icon.
              _RegionGridPicker(
                region: _region,
                color: Color(bookmarkColorArgb(_color)),
                enabled: !_busy,
                onChanged: (r) => setState(() => _region = r),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _noteCtrl,
                enabled: !_busy,
                maxLines: 3,
                maxLength: 280,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  hintText: 'Why is this page important?',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: cs.error),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(_isEdit ? Icons.save : Icons.bookmark_add),
                      label: Text(_isEdit ? 'Save' : 'Add bookmark'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 3×3 region grid + "whole page" toggle. Renders a page-shaped (4:3)
/// rectangle divided into 9 cells. Tapping a cell selects it; tapping
/// the selected cell again clears back to whole-page mode. "Whole page"
/// is a separate full-width pill underneath for explicit reset.
class _RegionGridPicker extends StatelessWidget {
  const _RegionGridPicker({
    required this.region,
    required this.color,
    required this.enabled,
    required this.onChanged,
  });

  final _BookmarkRegion? region;

  /// Flag color — the selected cell tints with this so the picker
  /// visually anticipates how the bookmark will look on the page.
  final Color color;
  final bool enabled;
  final ValueChanged<_BookmarkRegion?> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Fixed aspect ratio so the grid reads as a page outline rather
        // than a square sticker. 4:3 is close enough to US-letter portrait
        // for the visual cue to land; the actual region rect is stored
        // as page-relative fractions so any page size resolves correctly.
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant, width: 1),
              borderRadius: BorderRadius.circular(6),
              color: cs.surfaceContainerLowest,
            ),
            child: Column(
              children: List.generate(3, (row) {
                return Expanded(
                  child: Row(
                    children: List.generate(3, (col) {
                      final cell = _BookmarkRegion(row, col);
                      final selected = region == cell;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Material(
                            color: selected
                                ? color.withValues(alpha: 0.35)
                                : cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: !enabled
                                  ? null
                                  : () => onChanged(selected ? null : cell),
                              child: Center(
                                child: selected
                                    ? Icon(
                                        Icons.bookmark,
                                        size: 18,
                                        color: color,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                );
              }),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Explicit "whole page" reset — tapping a selected cell clears
        // too, but a dedicated control makes the affordance obvious for
        // users who didn't try the toggle.
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: (!enabled || region == null)
                ? null
                : () => onChanged(null),
            icon: const Icon(Icons.crop_free, size: 16),
            label: const Text('Whole page'),
            style: OutlinedButton.styleFrom(
              foregroundColor: region == null ? cs.primary : cs.onSurface,
              side: BorderSide(
                color: region == null ? cs.primary : cs.outlineVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
