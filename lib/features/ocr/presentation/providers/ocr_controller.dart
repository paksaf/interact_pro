import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/app_database.dart' as db;
import '../../../../core/utils/logger.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../data/repositories/ocr_repository_impl.dart';
import '../../domain/entities/ocr_result.dart';

class OcrJobState {
  const OcrJobState({
    this.totalPages = 0,
    this.completedPages = const <OcrPageResult>[],
    this.error,
    this.isRunning = false,
    this.fromCache = false,
    this.cachedFullText,
  });

  final int totalPages;
  final List<OcrPageResult> completedPages;
  final String? error;
  final bool isRunning;

  /// True when the result was served from the [OcrCache] table without
  /// re-running ML Kit. UI uses this to badge the result.
  final bool fromCache;

  /// Full extracted text when [fromCache] is true. The per-block payload
  /// isn't cached (it'd bloat the DB row); when the user wants block-level
  /// data they need to re-run with cache off.
  final String? cachedFullText;

  double get progress =>
      totalPages == 0 ? 0 : completedPages.length / totalPages;

  /// Concatenated text from every page's recognition pass. Falls back to
  /// [cachedFullText] when the result came from cache.
  String get fullText {
    if (cachedFullText != null) return cachedFullText!;
    return completedPages
        .map((p) => '── Page ${p.pageIndex + 1} ──\n${p.text}')
        .join('\n\n');
  }

  OcrJobState copyWith({
    int? totalPages,
    List<OcrPageResult>? completedPages,
    String? error,
    bool? isRunning,
    bool? fromCache,
    String? cachedFullText,
  }) =>
      OcrJobState(
        totalPages: totalPages ?? this.totalPages,
        completedPages: completedPages ?? this.completedPages,
        error: error,
        isRunning: isRunning ?? this.isRunning,
        fromCache: fromCache ?? this.fromCache,
        cachedFullText: cachedFullText ?? this.cachedFullText,
      );
}

class OcrController extends AutoDisposeNotifier<OcrJobState> {
  @override
  OcrJobState build() => const OcrJobState();

  /// Reset back to idle — used when the user navigates back into the OCR
  /// screen with a different document, so stale results don't leak.
  void reset() => state = const OcrJobState();

  Future<void> run(
    PdfDocument doc, {
    OcrAccuracyMode mode = OcrAccuracyMode.fast,
    OcrLanguage language = OcrLanguage.latin,
    bool useCache = true,
  }) async {
    state = OcrJobState(totalPages: doc.pageCount, isRunning: true);

    // ── Cache lookup. SHA-1 the file content so a rename/move doesn't
    // ── invalidate the cache, only true content changes do.
    final database = ref.read(db.appDatabaseProvider);
    String? hash;
    try {
      final bytes = await File(doc.path).readAsBytes();
      hash = sha1.convert(bytes).toString();
      if (useCache) {
        final cached = await database.cachedOcr(hash);
        if (cached != null) {
          appLogger.i('OCR: cache hit for $hash (${cached.pageCount}p)');
          state = OcrJobState(
            totalPages: cached.pageCount,
            isRunning: false,
            fromCache: true,
            cachedFullText: cached.fullText,
            // Empty completedPages so UI's "save .txt" path knows to use
            // cachedFullText — the export sheet special-cases this below.
            completedPages: const <OcrPageResult>[],
          );
          return;
        }
      }
    } catch (e, st) {
      appLogger.w('OCR: cache lookup failed', error: e, stackTrace: st);
      // Soft-fail to live OCR — caching is an optimization, not correctness.
    }

    // ── Live ML Kit run. Stream pages as they finish so the user sees
    // ── progress instead of staring at an indeterminate spinner.
    final repo = await ref.read(ocrRepositoryProvider.future);
    final List<OcrPageResult> done = <OcrPageResult>[];
    bool hadError = false;
    await for (final r in repo.recognise(doc, mode: mode, language: language)) {
      r.fold(
        (OcrPageResult p) {
          done.add(p);
          state = state.copyWith(completedPages: List<OcrPageResult>.of(done));
        },
        (failure) {
          hadError = true;
          state = state.copyWith(
            error: failure.message,
            isRunning: false,
          );
        },
      );
      if (hadError) break;
    }
    if (hadError) return;

    // ── Persist to cache so the second run is instant. Best-effort —
    // ── failure here doesn't block the UI from showing results.
    if (hash != null && done.isNotEmpty) {
      final fullText = done
          .map((p) => '── Page ${p.pageIndex + 1} ──\n${p.text}')
          .join('\n\n');
      try {
        await database.upsertOcrCache(
          fileHash: hash,
          fullText: fullText,
          pageCount: done.length,
        );
        appLogger.i('OCR: cached ${done.length} pages for $hash');
      } catch (e, st) {
        appLogger.w('OCR: cache write failed', error: e, stackTrace: st);
      }
    }

    state = state.copyWith(isRunning: false);
  }
}

final AutoDisposeNotifierProvider<OcrController, OcrJobState>
    ocrControllerProvider =
    AutoDisposeNotifierProvider<OcrController, OcrJobState>(
        OcrController.new,);
