import '../../../core/utils/result.dart';
import 'handwriting_result.dart';
import 'ink_stroke.dart';

/// Surface the UI talks to. Hides the ML Kit plumbing (separate model
/// manager + recogniser) behind one cohesive API.
abstract class HandwritingRepository {
  /// True iff a recognition model for [languageTag] is already on disk
  /// and ready to use without a network round-trip.
  Future<Result<bool>> isModelDownloaded(String languageTag);

  /// Pull the model down. Idempotent — if already present, completes
  /// immediately. Network-bound on first call (10–20MB depending on
  /// language). Returns a stream so the UI can show a spinner while
  /// it's running, but doesn't surface byte progress (ML Kit doesn't
  /// expose that on download).
  Future<Result<void>> downloadModel(String languageTag);

  /// Best-effort delete from on-device storage. Used by the language
  /// picker's "free up space" affordance.
  Future<Result<void>> deleteModel(String languageTag);

  /// Recognise [capture] using the [languageTag] model. Caller is
  /// responsible for ensuring the model is downloaded — this method
  /// returns a domain failure rather than auto-downloading, so the UI
  /// can confirm with the user before consuming bandwidth.
  Future<Result<HandwritingResult>> recognise({
    required InkCapture capture,
    required String languageTag,
  });

  /// Drop any in-memory recogniser state. Cheap to call; useful between
  /// language switches so we don't keep multiple recognisers alive.
  Future<void> dispose();
}
