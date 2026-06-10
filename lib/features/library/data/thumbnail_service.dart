import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';

/// Renders + caches first-page thumbnails for PDFs.
///
/// Design notes:
///   • One thumbnail per (path, mtime, size). The mtime is the cache
///     buster — editing a PDF (sign, stamp, OCR) changes the mtime, so
///     the next read regenerates automatically. No manual invalidation.
///   • Cache keyed by SHA-1 of those three so renames don't break.
///   • Two sizes: `small` (200×260) for shelf view, `medium` (400×520)
///     for the recent-documents list. Both rendered fresh from the
///     PDF — no upscaling.
///   • Output is JPEG (q=82) for the cache, not PNG — the shelf has
///     hundreds of thumbs in flight and JPEG is ~5× smaller for
///     photo-like first pages.
final thumbnailServiceProvider = Provider<ThumbnailService>((ref) {
  return ThumbnailService();
});

enum ThumbSize {
  /// 80×104 — used by the viewer's thumbnail sidebar (lots of small
  /// previews). Cheap to render and reasonable on a Retina sidebar.
  xsmall,

  /// 200×260 — used by the shelf grid.
  small,

  /// 400×520 — used by the recents list and detail headers.
  medium,
}

class ThumbnailService {
  Directory? _cacheDir;

  Future<Directory> _ensureCacheDir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'pdf_thumbs'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  /// Returns the cached thumbnail file. Generates on first miss; reads
  /// from disk on subsequent calls. The returned `File` may not exist
  /// only on the error branch.
  ///
  /// [pageNumber] is 1-indexed. Defaults to page 1 — that's the cover
  /// for the library shelf use case. The viewer's thumbnail sidebar
  /// passes the actual page number to get per-page previews.
  Future<Result<File>> thumbnailFor(
    String pdfPath, {
    ThumbSize size = ThumbSize.small,
    int pageNumber = 1,
  }) async {
    try {
      final src = File(pdfPath);
      if (!src.existsSync()) {
        return Result.err(StorageFailure('PDF not found: $pdfPath'));
      }
      final stat = src.statSync();
      final cacheKey = _cacheKey(
        path: pdfPath,
        mtime: stat.modified,
        size: size,
        pageNumber: pageNumber,
      );
      final dir = await _ensureCacheDir();
      final out = File(p.join(dir.path, '$cacheKey.jpg'));

      if (out.existsSync() && out.lengthSync() > 0) {
        return Result.ok(out);
      }
      return _render(
        pdfPath: pdfPath,
        out: out,
        size: size,
        pageNumber: pageNumber,
      );
    } catch (e, st) {
      appLogger.e('thumbnail failed', error: e, stackTrace: st);
      return Result.err(StorageFailure('Thumbnail failed', cause: e));
    }
  }

  Future<Result<File>> _render({
    required String pdfPath,
    required File out,
    required ThumbSize size,
    required int pageNumber,
  }) async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(pdfPath);
      if (doc.pagesCount == 0) {
        return const Result.err(StorageFailure('PDF has no pages'));
      }
      final clamped = pageNumber.clamp(1, doc.pagesCount);
      final page = await doc.getPage(clamped);
      final dims = _dimensionsFor(size, page.width, page.height);

      final rendered = await page.render(
        width: dims.$1,
        height: dims.$2,
        format: pdfx.PdfPageImageFormat.jpeg,
        quality: 82,
        backgroundColor: '#FFFFFF',
      );
      await page.close();
      if (rendered == null) {
        return const Result.err(StorageFailure('Render returned null'));
      }
      await out.writeAsBytes(rendered.bytes, flush: true);
      return Result.ok(out);
    } catch (e, st) {
      appLogger.e('thumbnail render failed', error: e, stackTrace: st);
      return Result.err(StorageFailure('Render failed', cause: e));
    } finally {
      await doc?.close();
    }
  }

  /// Match the source page's aspect ratio while honouring the target
  /// size's longest-edge cap. Books on a shelf look uniform at fixed
  /// pixel widths, but A4 vs Letter vs landscape pages should still
  /// keep their proportions.
  (double, double) _dimensionsFor(ThumbSize size, double w, double h) {
    final cap = switch (size) {
      ThumbSize.xsmall => 104.0,
      ThumbSize.small => 260.0,
      ThumbSize.medium => 520.0,
    };
    final maxSide = w > h ? w : h;
    if (maxSide == 0) return (cap * (w / h), cap);
    final scale = cap / maxSide;
    return (w * scale, h * scale);
  }

  String _cacheKey({
    required String path,
    required DateTime mtime,
    required ThumbSize size,
    required int pageNumber,
  }) {
    final raw =
        '$path|${mtime.millisecondsSinceEpoch}|${size.name}|p$pageNumber';
    return sha1.convert(utf8.encode(raw)).toString();
  }

  /// Wipe the entire thumbnail cache. Used by Settings → "Free up space"
  /// and on app launch when the user toggled the privacy "no caching"
  /// preference (not yet implemented but the seam is here).
  Future<void> clearCache() async {
    try {
      final dir = _cacheDir ?? await _ensureCacheDir();
      if (dir.existsSync()) {
        await for (final entity in dir.list()) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (e) {
      appLogger.w('thumbnail cache clear failed: $e');
    }
  }
}

/// Cached-future provider keyed by (path, size, page) so multiple
/// consumers pointing at the same thumbnail dedupe their renders. The
/// `family` cache is memoised across rebuilds, so once a thumbnail
/// loads its `AsyncData` flows through to every consumer instantly.
final thumbnailFileProvider = FutureProvider.autoDispose
    .family<File?, ThumbnailRequest>((ref, req) async {
  final svc = ref.watch(thumbnailServiceProvider);
  final r = await svc.thumbnailFor(
    req.pdfPath,
    size: req.size,
    pageNumber: req.pageNumber,
  );
  return r.fold((f) => f, (_) => null);
});

class ThumbnailRequest {
  const ThumbnailRequest({
    required this.pdfPath,
    this.size = ThumbSize.small,
    this.pageNumber = 1,
  });
  final String pdfPath;
  final ThumbSize size;
  final int pageNumber;

  @override
  bool operator ==(Object other) =>
      other is ThumbnailRequest &&
      other.pdfPath == pdfPath &&
      other.size == size &&
      other.pageNumber == pageNumber;

  @override
  int get hashCode => Object.hash(pdfPath, size, pageNumber);
}
