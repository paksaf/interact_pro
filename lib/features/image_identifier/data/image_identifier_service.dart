import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../vision/domain/vision_request.dart';
import '../../vision/domain/vision_service.dart';
import '../../vision/presentation/providers/vision_provider.dart';
import '../domain/identifier_result.dart';

/// Runs Google ML Kit's on-device image labeler and text recognizer on a
/// local image file. Uses the v8.x model bundled with the host app so the
/// first call still works offline (no model download required).
///
/// PRD-style triggers:
///   • Object identification — "what is this?" — labels with confidence.
///   • Text-from-photo — receipts, signage, business cards — OCR extract.
///   • Deep analysis — when the user toggles "Use AI", we additionally
///     call the [VisionService] for a full natural-language description
///     that goes beyond labels (handles relationships, intent, mood,
///     multi-object scenes the on-device labeler can only enumerate).
final imageIdentifierServiceProvider = Provider<ImageIdentifierService>((ref) {
  final svc = ImageIdentifierService(
    vision: ref.watch(visionServiceProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

class ImageIdentifierService {
  ImageIdentifierService({
    ImageLabeler? labeler,
    TextRecognizer? textRecognizer,
    VisionService? vision,
  })  : _labeler = labeler ??
            // Threshold 0.3 (low) so the UI's user-controlled confidence
            // slider has real headroom to work with. Higher thresholds
            // would mean dragging the slider down past the model's gate
            // is a no-op — we'd rather hand the UI more raw labels and
            // let it filter dynamically without re-running the model.
            ImageLabeler(
              options: ImageLabelerOptions(confidenceThreshold: 0.3),
            ),
        _text = textRecognizer ?? TextRecognizer(script: TextRecognitionScript.latin),
        _vision = vision;

  final ImageLabeler _labeler;
  final TextRecognizer _text;
  final VisionService? _vision;

  /// Fast, on-device pass. No network. Always called.
  Future<Result<ImageIdentifyResult>> identify(String imagePath) async {
    final stopwatch = Stopwatch()..start();
    try {
      final input = InputImage.fromFilePath(imagePath);

      // Run both pipelines in parallel — they don't share state and
      // doing them sequentially adds ~150ms of unnecessary latency on
      // large photos.
      final results = await Future.wait([
        _labeler.processImage(input),
        _text.processImage(input),
      ]);
      final rawLabels = results[0] as List<ImageLabel>;
      final recognised = results[1] as RecognizedText;

      // Take more labels (25 vs the old 10) so the user's confidence
      // slider can dial in. Each label gets bucketed into a domain
      // category at this point (cheap one-pass classification) so the
      // UI doesn't have to re-categorise on every slider tick.
      final labels = (rawLabels..sort((a, b) => b.confidence.compareTo(a.confidence)))
          .take(25)
          .map((l) => IdentifierLabel(
                text: l.label,
                confidence: l.confidence,
                category: categorizeLabel(l.label),
              ),)
          .toList();

      stopwatch.stop();
      return Result.ok(ImageIdentifyResult(
        imagePath: imagePath,
        labels: labels,
        extractedText: recognised.text.trim(),
        processingMs: stopwatch.elapsedMilliseconds,
      ),);
    } catch (e, st) {
      appLogger.e('image identify failed', error: e, stackTrace: st);
      return Result.err(UnknownFailure('Image identification failed', cause: e));
    }
  }

  /// Deep pass: on-device labeler + text recognition, AND a vision LLM
  /// call for a natural-language description. The result enriches the
  /// existing card — labels and extracted text still come from ML Kit
  /// (snappy, cheap), the description comes from the LLM (slow, paid,
  /// far more capable).
  ///
  /// Falls back to a plain [identify] when [_vision] isn't configured
  /// or returns an error — the LLM step is strictly additive so a
  /// degraded result is better than no result.
  Future<Result<ImageIdentifyResult>> identifyDeep(String imagePath) async {
    final shallow = await identify(imagePath);
    return shallow.fold<Future<Result<ImageIdentifyResult>>>(
      (base) async {
        final vision = _vision;
        if (vision == null || !await vision.isConfigured()) {
          // No AI configured — just return what the on-device pass got.
          // The screen surfaces a hint when the toggle is on but
          // unavailable; we don't double-error.
          return Result.ok(base);
        }

        final aiResult = await vision.analyse(VisionRequest(
          imagePath: imagePath,
          task: VisionTask.describe,
        ),);

        return aiResult.fold<Result<ImageIdentifyResult>>(
          (vr) => Result.ok(ImageIdentifyResult(
            imagePath: base.imagePath,
            labels: base.labels,
            extractedText: base.extractedText,
            processingMs: base.processingMs,
            aiDescription: vr.text,
            aiElapsedMs: vr.elapsedMs,
          ),),
          // AI errored but on-device worked — surface the on-device
          // result and let the screen show a soft warning.
          (_) => Result.ok(base),
        );
      },
      (failure) async => Result.err(failure),
    ).then((value) => value);
  }

  Future<void> dispose() async {
    await _labeler.close();
    await _text.close();
  }
}
