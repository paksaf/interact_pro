import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/handwriting_repository_impl.dart';
import '../../data/transcript_to_pdf.dart';
import '../../domain/handwriting_repository.dart';
import '../../domain/handwriting_result.dart';
import '../../domain/ink_stroke.dart';
import '../../domain/supported_languages.dart';

/// Reactive state for the handwriting screen.
///
/// We deliberately keep the captured strokes OUT of the [HandwritingState]
/// — they belong to the canvas widget, which owns rendering and gesture
/// handling. The controller takes the capture as an argument when the
/// user (or the continuous-mode debouncer) hits "Recognise" and emits
/// the result back.
class HandwritingState {
  const HandwritingState({
    this.languageTag = 'en-US',
    this.modelDownloaded = false,
    this.checking = false,
    this.downloading = false,
    this.recognising = false,
    this.continuousMode = false,
    this.savingPdf = false,
    this.lastSavedPdfPath,
    this.result,
    this.bufferedText = '',
    this.error,
  });

  final String languageTag;
  final bool modelDownloaded;
  final bool checking;
  final bool downloading;
  final bool recognising;

  /// True when "Recognise as you write" is on. The screen schedules a
  /// debounced recognition after every stroke completes; the controller
  /// itself just exposes the toggle.
  final bool continuousMode;

  final bool savingPdf;

  /// Most recent PDF the user saved their transcript as. The screen
  /// shows a snackbar with an "Open" action when this changes.
  final String? lastSavedPdfPath;

  final HandwritingResult? result;

  /// Running text the user has accumulated by tapping "Append" on
  /// recognition results. Persists across recognitions until the user
  /// taps "Clear" or shares.
  final String bufferedText;

  final String? error;

  HandwritingState copyWith({
    String? languageTag,
    bool? modelDownloaded,
    bool? checking,
    bool? downloading,
    bool? recognising,
    bool? continuousMode,
    bool? savingPdf,
    String? lastSavedPdfPath,
    HandwritingResult? result,
    String? bufferedText,
    String? error,
    bool clearError = false,
    bool clearResult = false,
    bool clearLastSavedPdf = false,
  }) {
    return HandwritingState(
      languageTag: languageTag ?? this.languageTag,
      modelDownloaded: modelDownloaded ?? this.modelDownloaded,
      checking: checking ?? this.checking,
      downloading: downloading ?? this.downloading,
      recognising: recognising ?? this.recognising,
      continuousMode: continuousMode ?? this.continuousMode,
      savingPdf: savingPdf ?? this.savingPdf,
      lastSavedPdfPath: clearLastSavedPdf
          ? null
          : (lastSavedPdfPath ?? this.lastSavedPdfPath),
      result: clearResult ? null : (result ?? this.result),
      bufferedText: bufferedText ?? this.bufferedText,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final handwritingControllerProvider =
    StateNotifierProvider.autoDispose<HandwritingController, HandwritingState>((ref) {
  return HandwritingController(
    ref.watch(handwritingRepositoryProvider),
    ref.watch(transcriptToPdfProvider),
  );
});

class HandwritingController extends StateNotifier<HandwritingState> {
  HandwritingController(this._repo, this._transcriptToPdf)
      : super(const HandwritingState()) {
    refreshModelState();
  }

  final HandwritingRepository _repo;
  final TranscriptToPdf _transcriptToPdf;

  Future<void> setLanguage(String tag) async {
    if (state.languageTag == tag) return;
    state = state.copyWith(
      languageTag: tag,
      clearResult: true,
      clearError: true,
    );
    await refreshModelState();
  }

  Future<void> refreshModelState() async {
    state = state.copyWith(checking: true, clearError: true);
    final r = await _repo.isModelDownloaded(state.languageTag);
    r.fold(
      (downloaded) =>
          state = state.copyWith(checking: false, modelDownloaded: downloaded),
      (failure) => state = state.copyWith(
        checking: false,
        modelDownloaded: false,
        error: failure.message,
      ),
    );
  }

  Future<void> downloadModel() async {
    if (state.downloading) return;
    state = state.copyWith(downloading: true, clearError: true);
    final r = await _repo.downloadModel(state.languageTag);
    r.fold(
      (_) => state = state.copyWith(
        downloading: false,
        modelDownloaded: true,
      ),
      (failure) => state = state.copyWith(
        downloading: false,
        error: failure.message,
      ),
    );
  }

  Future<void> deleteModel(String languageTag) async {
    final r = await _repo.deleteModel(languageTag);
    r.fold(
      (_) {
        if (languageTag == state.languageTag) {
          state = state.copyWith(modelDownloaded: false);
        }
      },
      (failure) => state = state.copyWith(error: failure.message),
    );
  }

  /// Toggle "Recognise as you write". Turning it on is purely a state
  /// flip — the screen owns the debounce timer and listens to the
  /// canvas to fire `recognise(...)` 1s after the most recent stroke
  /// completes. Turning it off doesn't cancel an in-flight recognition.
  void setContinuousMode(bool enabled) {
    if (state.continuousMode == enabled) return;
    state = state.copyWith(continuousMode: enabled);
  }

  /// Hard cap on recognise calls. ML Kit's native recognizer occasionally
  /// hangs on a corrupt model file; without a timeout the user sees the
  /// "Reading…" spinner forever and force-quits the app. 20s is generous
  /// for normal recognition (which is sub-second once the model is loaded).
  static const Duration _recogniseTimeout = Duration(seconds: 20);

  /// Hard cap on first-time model downloads. ML Kit doesn't expose
  /// per-byte progress, so we just bound the total wait. 90s covers a
  /// 15-25 MB download on a 2 Mbps connection (rural PK floor).
  static const Duration _downloadTimeout = Duration(seconds: 90);

  Future<void> recognise(InkCapture capture) async {
    if (state.recognising) return;
    if (capture.isEmpty) return;

    // ── Auto-download the model if missing ──────────────────────────
    // The old behaviour was to error out and tell the user to tap a
    // separate Download button. That was exactly the "Recognise → US
    // English not downloaded" dead-end the user reported. Now we just
    // download in-place and continue.
    if (!state.modelDownloaded) {
      final downloaded = await _ensureModelReady();
      if (!downloaded) return; // _ensureModelReady set the error already
    }

    state = state.copyWith(recognising: true, clearError: true);
    try {
      final r = await _repo
          .recognise(
            capture: capture,
            languageTag: state.languageTag,
          )
          .timeout(_recogniseTimeout);
      r.fold(
        (result) => state = state.copyWith(
          recognising: false,
          result: result,
        ),
        (failure) => state = state.copyWith(
          recognising: false,
          error: failure.message,
        ),
      );
    } on TimeoutException {
      state = state.copyWith(
        recognising: false,
        error: 'Recognition timed out. The model may be corrupted — '
            'long-press the language chip and choose "Re-download model".',
      );
    } catch (e) {
      state = state.copyWith(
        recognising: false,
        error: 'Recognition failed: $e',
      );
    }
  }

  /// Returns true if the model is on disk and ready (either it already
  /// was, or we just successfully downloaded it).
  /// Failures set `state.error` and return false. Idempotent — safe to
  /// call from `recognise()` AND `setLanguage()` independently.
  Future<bool> _ensureModelReady() async {
    if (state.modelDownloaded) return true;
    if (state.downloading) {
      // Another caller is already downloading; wait briefly. We don't
      // join their future directly because it's tied to copyWith state
      // — polling once with a short backoff is simpler and good enough.
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (state.modelDownloaded) return true;
        if (!state.downloading) break;
      }
      return state.modelDownloaded;
    }

    state = state.copyWith(downloading: true, clearError: true);
    try {
      final r = await _repo
          .downloadModel(state.languageTag)
          .timeout(_downloadTimeout);
      return r.fold<bool>(
        (_) {
          state = state.copyWith(downloading: false, modelDownloaded: true);
          return true;
        },
        (failure) {
          state = state.copyWith(
            downloading: false,
            error: 'Could not download the '
                '${HandwritingLanguage.byTag(state.languageTag).label} model: '
                '${failure.message}. Check your internet connection and try again.',
          );
          return false;
        },
      );
    } on TimeoutException {
      state = state.copyWith(
        downloading: false,
        error: 'Download timed out — please check your connection and retry.',
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        downloading: false,
        error: 'Download failed: $e',
      );
      return false;
    }
  }

  /// Append [text] (typically the top recognition candidate) to the
  /// running buffer with a single space separator. Skipped when [text]
  /// is empty so the user tapping "Append" with nothing in the result
  /// is a no-op rather than padding the buffer with whitespace.
  void appendToBuffer(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final next = state.bufferedText.isEmpty
        ? trimmed
        : '${state.bufferedText} $trimmed';
    state = state.copyWith(bufferedText: next, clearResult: true);
  }

  void replaceBuffer(String text) {
    state = state.copyWith(bufferedText: text.trim(), clearResult: true);
  }

  void clearBuffer() {
    state = state.copyWith(
      bufferedText: '',
      clearResult: true,
      clearLastSavedPdf: true,
    );
  }

  void clearResult() {
    state = state.copyWith(clearResult: true);
  }

  /// Generate a PDF from the current buffer and index it into the app's
  /// PDF library. Returns the file path (or `null` on failure — the
  /// reason lives in `state.error`).
  ///
  /// Doesn't clear the buffer afterwards: users often save mid-session
  /// and keep writing. The screen offers "Open" / "Clear" affordances
  /// after a successful save.
  Future<String?> saveBufferAsPdf({String? title}) async {
    if (state.savingPdf) return null;
    if (state.bufferedText.trim().isEmpty) {
      state = state.copyWith(error: 'Buffer is empty — nothing to save.');
      return null;
    }
    state = state.copyWith(savingPdf: true, clearError: true);
    final r = await _transcriptToPdf.save(
      text: state.bufferedText,
      languageTag: state.languageTag,
      title: title,
    );
    return r.fold<String?>(
      (path) {
        state = state.copyWith(savingPdf: false, lastSavedPdfPath: path);
        return path;
      },
      (failure) {
        state = state.copyWith(
          savingPdf: false,
          error: failure.message,
        );
        return null;
      },
    );
  }
}
