import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../domain/handwriting_repository.dart';
import '../domain/handwriting_result.dart';
import '../domain/ink_stroke.dart';
import 'mlkit_handwriting_datasource.dart';

/// Adds a few responsibilities on top of the bare ML Kit datasource:
///   • caches the active datasource so back-to-back recognitions in the
///     same language don't reopen the recogniser;
///   • wraps every SDK call in `Result<T>` with a typed `OcrFailure` so
///     the UI never has to try/catch ML Kit exceptions;
///   • disposes the previous datasource on language switch (recognisers
///     hold native handles — leaking them is benign in practice but
///     makes Profile mode noisier).
final handwritingRepositoryProvider = Provider<HandwritingRepository>((ref) {
  final repo = HandwritingRepositoryImpl();
  ref.onDispose(repo.dispose);
  return repo;
});

class HandwritingRepositoryImpl implements HandwritingRepository {
  MlkitHandwritingDatasource? _active;

  Future<MlkitHandwritingDatasource> _ensureFor(String languageTag) async {
    final current = _active;
    if (current != null && current.languageTag == languageTag) return current;
    if (current != null) {
      try {
        await current.close();
      } catch (e) {
        appLogger.w('Closing previous handwriting datasource failed: $e');
      }
    }
    final next = MlkitHandwritingDatasource(languageTag);
    _active = next;
    return next;
  }

  @override
  Future<Result<bool>> isModelDownloaded(String languageTag) async {
    try {
      final ds = await _ensureFor(languageTag);
      final ok = await ds.isModelDownloaded();
      return Result.ok(ok);
    } catch (e, st) {
      appLogger.e('isModelDownloaded failed', error: e, stackTrace: st);
      return Result.err(OcrFailure('Could not check model state', cause: e));
    }
  }

  @override
  Future<Result<void>> downloadModel(String languageTag) async {
    try {
      final ds = await _ensureFor(languageTag);
      // 90-second hard timeout — pre-2026-05-13 this was unbounded
      // and the UI hung indefinitely waiting for ML Kit's internal
      // CDN fetch (Urdu / Arabic / Chinese language packs frequently
      // stall on slow links + Google CDN edge throttling per user
      // reports). The cap makes the failure recoverable from the UI
      // and gives controller logic a chance to surface a retry
      // affordance instead of an indeterminate spinner.
      final ok = await ds.downloadModel().timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          appLogger.w(
            'downloadModel("$languageTag") exceeded 90s — '
            'returning false so the UI can offer retry. Note: ML Kit '
            'may still complete the download in the background.',
          );
          return false;
        },
      );
      if (!ok) {
        return Result.err(
          OcrFailure(
            'Model download for "$languageTag" timed out after 90 seconds. '
            'Check your network and tap retry.',
          ),
        );
      }
      return const Result.ok(null);
    } catch (e, st) {
      appLogger.e('downloadModel failed', error: e, stackTrace: st);
      return Result.err(OcrFailure('Model download failed', cause: e));
    }
  }

  @override
  Future<Result<void>> deleteModel(String languageTag) async {
    try {
      final ds = await _ensureFor(languageTag);
      final ok = await ds.deleteModel();
      if (!ok) {
        return Result.err(
          OcrFailure('Could not delete model for "$languageTag"'),
        );
      }
      return const Result.ok(null);
    } catch (e, st) {
      appLogger.e('deleteModel failed', error: e, stackTrace: st);
      return Result.err(OcrFailure('Model delete failed', cause: e));
    }
  }

  @override
  Future<Result<HandwritingResult>> recognise({
    required InkCapture capture,
    required String languageTag,
  }) async {
    if (capture.isEmpty) {
      return Result.ok(HandwritingResult(
        candidates: const [],
        languageCode: languageTag,
        elapsedMs: 0,
      ),);
    }
    try {
      final ds = await _ensureFor(languageTag);
      final sw = Stopwatch()..start();
      final raw = await ds.recognise(capture);
      sw.stop();

      final candidates = raw
          .map((c) => HandwritingCandidate(text: c.text, score: c.score ?? 0.0))
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));

      return Result.ok(HandwritingResult(
        candidates: candidates,
        languageCode: languageTag,
        elapsedMs: sw.elapsedMilliseconds,
      ),);
    } catch (e, st) {
      appLogger.e('handwriting recognise failed', error: e, stackTrace: st);
      return Result.err(OcrFailure('Recognition failed', cause: e));
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _active?.close();
    } catch (_) {}
    _active = null;
  }
}
