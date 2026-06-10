import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../handwriting/data/transcript_to_pdf.dart';
import '../../../handwriting/domain/supported_languages.dart';
import '../../../vision/domain/vision_request.dart';
import '../../../vision/presentation/providers/vision_provider.dart';
import '../../data/onboard_text_recognizer.dart';
import '../../domain/transcribe_engine.dart';

/// Reactive state for the handwritten-document transcription screen.
class HandwritingDocState {
  const HandwritingDocState({
    this.imagePath,
    this.languageTag = 'en-US',
    this.engine = TranscribeEngine.onDevice,
    this.cloudAvailable = false,
    this.transcribing = false,
    this.savingPdf = false,
    this.transcript = '',
    this.detectedLanguage,
    this.elapsedMs,
    this.tokensUsed,
    this.error,
  });

  /// Local file path of the picked / scanned image, or null before the
  /// user has chosen one.
  final String? imagePath;

  final String languageTag;
  final TranscribeEngine engine;

  /// True iff the vision LLM has credentials configured. The engine
  /// toggle is locked to on-device when this is false.
  final bool cloudAvailable;

  final bool transcribing;
  final bool savingPdf;

  /// Editable transcript that mirrors what the engine produced. The
  /// screen lets the user tidy it up before saving / sharing.
  final String transcript;

  final String? detectedLanguage;
  final int? elapsedMs;
  final int? tokensUsed;
  final String? error;

  HandwritingDocState copyWith({
    String? imagePath,
    String? languageTag,
    TranscribeEngine? engine,
    bool? cloudAvailable,
    bool? transcribing,
    bool? savingPdf,
    String? transcript,
    String? detectedLanguage,
    int? elapsedMs,
    int? tokensUsed,
    String? error,
    bool clearError = false,
    bool clearImage = false,
  }) {
    return HandwritingDocState(
      imagePath: clearImage ? null : (imagePath ?? this.imagePath),
      languageTag: languageTag ?? this.languageTag,
      engine: engine ?? this.engine,
      cloudAvailable: cloudAvailable ?? this.cloudAvailable,
      transcribing: transcribing ?? this.transcribing,
      savingPdf: savingPdf ?? this.savingPdf,
      transcript: transcript ?? this.transcript,
      detectedLanguage: detectedLanguage ?? this.detectedLanguage,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      tokensUsed: tokensUsed ?? this.tokensUsed,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final handwritingDocControllerProvider = StateNotifierProvider.autoDispose<
    HandwritingDocController, HandwritingDocState>((ref) {
  final controller = HandwritingDocController(ref);
  controller._refreshCloudAvailability();
  return controller;
});

class HandwritingDocController extends StateNotifier<HandwritingDocState> {
  HandwritingDocController(this._ref) : super(const HandwritingDocState());

  final Ref _ref;
  final OnDeviceTextRecognizer _onDevice = OnDeviceTextRecognizer();

  Future<void> _refreshCloudAvailability() async {
    final ok = await _ref.read(visionConfiguredProvider.future);
    if (!mounted) return;
    state = state.copyWith(
      cloudAvailable: ok,
      // Default to cloud when available — handwriting transcription is
      // the primary use case here, and the cloud path's quality on
      // cursive is the whole reason this screen exists.
      engine: ok ? TranscribeEngine.cloud : TranscribeEngine.onDevice,
    );
  }

  void setImagePath(String path) {
    state = state.copyWith(
      imagePath: path,
      transcript: '',
      clearError: true,
    );
  }

  void clearImage() {
    state = state.copyWith(clearImage: true, transcript: '', clearError: true);
  }

  void setLanguage(String tag) {
    if (state.languageTag == tag) return;
    state = state.copyWith(languageTag: tag, clearError: true);
  }

  void setEngine(TranscribeEngine engine) {
    if (engine == TranscribeEngine.cloud && !state.cloudAvailable) {
      state = state.copyWith(
        error: 'AI transcription needs a DeepSeek key. Set DEEPSEEK_API_KEY '
            'or DEEPSEEK_PROXY_URL at build time.',
      );
      return;
    }
    state = state.copyWith(engine: engine, clearError: true);
  }

  /// Update the transcript text — the screen wires this to a TextField
  /// `onChanged` so the user can fix recognition mistakes inline.
  void editTranscript(String text) {
    state = state.copyWith(transcript: text);
  }

  Future<void> transcribe() async {
    if (state.transcribing) return;
    final path = state.imagePath;
    if (path == null) {
      state = state.copyWith(error: 'Pick or scan an image first.');
      return;
    }
    state = state.copyWith(transcribing: true, clearError: true);
    switch (state.engine) {
      case TranscribeEngine.onDevice:
        await _runOnDevice(path);
      case TranscribeEngine.cloud:
        await _runCloud(path);
    }
  }

  Future<void> _runOnDevice(String path) async {
    final script = mlKitScriptForLanguageTag(state.languageTag);
    final sw = Stopwatch()..start();
    final r = await _onDevice.recognise(imagePath: path, script: script);
    sw.stop();
    if (!mounted) return;
    r.fold(
      (text) => state = state.copyWith(
        transcribing: false,
        transcript: text.trim(),
        elapsedMs: sw.elapsedMilliseconds,
        // ML Kit's text recogniser doesn't emit language metadata —
        // record what we asked for so the UI's "language detected"
        // label has something to show.
        detectedLanguage: state.languageTag,
        tokensUsed: null,
      ),
      (failure) => state = state.copyWith(
        transcribing: false,
        error: failure.message,
      ),
    );
  }

  Future<void> _runCloud(String path) async {
    final svc = _ref.read(visionServiceProvider);
    final r = await svc.analyse(VisionRequest(
      imagePath: path,
      task: VisionTask.transcribeHandwriting,
      targetLanguage: state.languageTag,
      preserveLineBreaks: true,
    ),);
    if (!mounted) return;
    r.fold(
      (result) {
        // Honour the model's NO_HANDWRITING_FOUND sentinel by surfacing
        // it as a friendly message rather than dropping that string into
        // the transcript field.
        if (result.text == 'NO_HANDWRITING_FOUND') {
          state = state.copyWith(
            transcribing: false,
            transcript: '',
            error: 'No handwriting detected in this image.',
            elapsedMs: result.elapsedMs,
          );
          return;
        }
        state = state.copyWith(
          transcribing: false,
          transcript: result.text.trim(),
          elapsedMs: result.elapsedMs,
          detectedLanguage: result.detectedLanguage ?? state.languageTag,
          tokensUsed: result.tokensUsed,
        );
      },
      (failure) => state = state.copyWith(
        transcribing: false,
        error: failure.message,
      ),
    );
  }

  Future<String?> saveAsPdf({String? title}) async {
    if (state.savingPdf) return null;
    if (state.transcript.trim().isEmpty) {
      state = state.copyWith(error: 'Transcript is empty.');
      return null;
    }
    state = state.copyWith(savingPdf: true, clearError: true);
    final pdfSvc = _ref.read(transcriptToPdfProvider);
    final r = await pdfSvc.save(
      text: state.transcript,
      languageTag: state.languageTag,
      title: title ??
          'Transcription ${HandwritingLanguage.byTag(state.languageTag).label}',
    );
    return r.fold<String?>(
      (path) {
        state = state.copyWith(savingPdf: false);
        return path;
      },
      (failure) {
        state = state.copyWith(savingPdf: false, error: failure.message);
        return null;
      },
    );
  }
}
