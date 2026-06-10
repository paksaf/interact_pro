import '../../../core/utils/result.dart';
import 'vision_request.dart';
import 'vision_result.dart';

/// Vision-LLM facade. Today there's exactly one implementation
/// ([DeepSeekVisionClient]) — the abstract type is here so a future
/// Anthropic / OpenAI / Gemini implementation drops in by overriding
/// the provider, with no UI changes.
abstract class VisionService {
  /// True iff the service has the credentials it needs (a DeepSeek key
  /// or a configured proxy URL). UI binds to this to gate the "use
  /// AI" toggle in screens that have an on-device fallback.
  Future<bool> isConfigured();

  Future<Result<VisionResult>> analyse(VisionRequest request);
}
