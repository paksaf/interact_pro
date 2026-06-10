import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

import '../domain/ink_stroke.dart';

/// Thin wrapper over `google_mlkit_digital_ink_recognition`. Keeps every
/// reference to the SDK in this one file so the rest of the feature
/// stays plain Dart and easy to fake in tests.
///
/// Lifecycle: callers create a datasource per language tag (recognisers
/// are language-specific and cheap to instantiate). The repository
/// caches the most recent one so back-to-back recognitions in the same
/// language don't pay the construction cost twice.
class MlkitHandwritingDatasource {
  MlkitHandwritingDatasource(this.languageTag)
      : _recogniser = mlkit.DigitalInkRecognizer(languageCode: languageTag);

  final String languageTag;
  final mlkit.DigitalInkRecognizer _recogniser;
  final mlkit.DigitalInkRecognizerModelManager _modelManager =
      mlkit.DigitalInkRecognizerModelManager();

  /// Convert our [InkCapture] into ML Kit's `Ink` and forward to the
  /// recogniser. Returns the raw ML Kit candidates; the repository maps
  /// them into our domain types.
  Future<List<mlkit.RecognitionCandidate>> recognise(InkCapture capture) async {
    final ink = mlkit.Ink();
    ink.strokes = capture.strokes
        .where((s) => s.isNotEmpty)
        .map((s) {
          final stroke = mlkit.Stroke();
          stroke.points = s.points
              .map((p) => mlkit.StrokePoint(
                    x: p.x,
                    y: p.y,
                    t: p.timestampMs,
                  ),)
              .toList();
          return stroke;
        })
        .toList();
    if (ink.strokes.isEmpty) return const [];
    return _recogniser.recognize(ink);
  }

  /// True iff the language model is already on disk.
  Future<bool> isModelDownloaded() => _modelManager.isModelDownloaded(languageTag);

  /// Pull the model down. ML Kit shows no progress callback on the
  /// download — wrap UI feedback in a "this may take a minute on the
  /// first run" spinner.
  Future<bool> downloadModel() => _modelManager.downloadModel(languageTag);

  Future<bool> deleteModel() => _modelManager.deleteModel(languageTag);

  Future<void> close() => _recogniser.close();
}
