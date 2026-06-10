
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../library/data/thumbnail_service.dart';

/// Vertical strip of page thumbnails for the viewer. Tap to jump.
///
/// Lazy-loads via `ListView.builder` so a 500-page PDF doesn't try to
/// render every thumbnail at once — only the visible rows touch the
/// thumbnail service. Each tile is wrapped in a small wrapper that
/// reserves the same dimensions whether the thumb is loaded or not, so
/// scrolling doesn't jitter as new tiles paint in.
///
/// Owns its own page-count probe rather than depending on the screen
/// to pass it in — that way the sidebar is decoupled from whichever
/// PDF view widget the screen happens to be using (Syncfusion, pdfx,
/// etc.).
class ThumbnailSidebar extends ConsumerStatefulWidget {
  const ThumbnailSidebar({
    required this.pdfPath,
    required this.currentPage,
    required this.onPageSelected,
    this.width = 132,
    super.key,
  });

  final String pdfPath;

  /// 1-indexed current page (matches the rest of the codebase's
  /// `currentPageProvider` convention). Drives the highlight ring.
  final int currentPage;

  /// Called with the 1-indexed page number when the user taps a tile.
  final ValueChanged<int> onPageSelected;

  final double width;

  @override
  ConsumerState<ThumbnailSidebar> createState() => _ThumbnailSidebarState();
}

class _ThumbnailSidebarState extends ConsumerState<ThumbnailSidebar> {
  int? _pageCount;
  String? _error;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _probePageCount();
  }

  @override
  void didUpdateWidget(covariant ThumbnailSidebar old) {
    super.didUpdateWidget(old);
    if (old.pdfPath != widget.pdfPath) {
      // Different PDF — rerun the probe.
      setState(() {
        _pageCount = null;
        _error = null;
      });
      _probePageCount();
    } else if (old.currentPage != widget.currentPage) {
      // Keep the active page tile visible. Wait one frame so the list
      // has had a chance to lay out before we ask for an offset.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent();
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _probePageCount() async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(widget.pdfPath);
      final count = doc.pagesCount;
      if (!mounted) return;
      setState(() => _pageCount = count);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      await doc?.close();
    }
  }

  /// Estimate tile height (thumb cap 104 + caption + padding) and
  /// scroll the active tile into view. Conservative — if the user is
  /// already manually scrolled we don't fight them, just nudge.
  void _scrollToCurrent() {
    if (!_scroll.hasClients || _pageCount == null) return;
    const tileH = 104.0 + 28.0; // thumb height + caption + padding
    final target = (widget.currentPage - 1) * tileH;
    final viewport = _scroll.position.viewportDimension;
    final visibleTop = _scroll.offset;
    final visibleBottom = visibleTop + viewport;
    if (target < visibleTop || target > visibleBottom - tileH) {
      _scroll.animateTo(
        (target - viewport / 2 + tileH / 2)
            .clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: widget.width,
      color: cs.surfaceContainerHighest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.view_list, size: 14, color: cs.outline),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _pageCount == null
                        ? 'Pages'
                        : '$_pageCount page${_pageCount == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.outline,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: TextStyle(color: cs.error, fontSize: 11),
              ),
            )
          else if (_pageCount == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemCount: _pageCount!,
                itemBuilder: (_, i) {
                  final pageNumber = i + 1;
                  return _Tile(
                    pdfPath: widget.pdfPath,
                    pageNumber: pageNumber,
                    isActive: pageNumber == widget.currentPage,
                    onTap: () => widget.onPageSelected(pageNumber),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Tile extends ConsumerWidget {
  const _Tile({
    required this.pdfPath,
    required this.pageNumber,
    required this.isActive,
    required this.onTap,
  });

  final String pdfPath;
  final int pageNumber;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final thumb = ref.watch(thumbnailFileProvider(
      ThumbnailRequest(
        pdfPath: pdfPath,
        size: ThumbSize.xsmall,
        pageNumber: pageNumber,
      ),
    ),);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Container(
              width: 88,
              height: 112,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: isActive ? cs.primary : cs.outlineVariant,
                  width: isActive ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(4),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: cs.primary.withOpacity(0.25),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: thumb.when(
                data: (file) {
                  if (file == null) return _LoadingTile();
                  return Image.file(
                    file,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  );
                },
                loading: () => _LoadingTile(),
                error: (_, __) => _LoadingTile(),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$pageNumber',
              style: TextStyle(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                color: isActive ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      alignment: Alignment.center,
      child: SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}
