import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/deepseek_vision_client.dart';
import '../../domain/vision_service.dart';

/// Public-facing handle on the vision LLM. UI imports from here, never
/// directly from the data layer — that way swapping the implementation
/// (Anthropic / OpenAI / Gemini) is one provider override.
final visionServiceProvider = Provider<VisionService>((ref) {
  return ref.watch(deepSeekVisionClientProvider);
});

/// Async-resolved availability so the UI can disable the "use AI"
/// toggle and show a helpful empty state when no key / proxy is set.
final visionConfiguredProvider = FutureProvider<bool>((ref) async {
  return ref.watch(visionServiceProvider).isConfigured();
});
