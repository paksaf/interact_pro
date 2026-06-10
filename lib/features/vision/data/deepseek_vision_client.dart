import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/api_config.dart';
import '../../../core/error/failures.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../domain/vision_request.dart';
import '../domain/vision_result.dart';
import '../domain/vision_service.dart';

/// DeepSeek vision implementation of [VisionService].
///
/// Reuses the same auth model as the existing translation client:
///   • Direct mode — `--dart-define=DEEPSEEK_API_KEY=...` baked in (or
///     written into secure storage at runtime). Convenient for dev.
///   • Proxy mode — `--dart-define=DEEPSEEK_PROXY_URL=...` points the
///     client at a backend that injects the key server-side and
///     enforces per-user rate limits. Strongly preferred for shipped
///     builds since a long-lived API key inside an app binary is
///     extractable.
///
/// Uses OpenAI-compatible chat-completions with multimodal `content`
/// arrays (text + image_url blocks). Image is base64-encoded inline as
/// a data URL — works without us hosting the image anywhere.
///
/// Model NAME is a build-time define (`DEEPSEEK_VISION_MODEL`) so
/// swapping vendors / model revs doesn't require a code change. The
/// default is the most recent vision-capable DeepSeek SKU as of May 2026
/// — verify against `deepseek.com/api-docs` for your account before
/// shipping. If the wrong name is picked the server returns a clean
/// 400 with the message exposed in the UI's error banner.
final deepSeekVisionClientProvider = Provider<VisionService>((ref) {
  final client = DeepSeekVisionClient(ref.watch(secureStoreProvider));
  if (ApiConfig.deepSeekProxyUrl.isNotEmpty) {
    client.setProxyEndpoint(ApiConfig.deepSeekProxyUrl);
  }
  return client;
});

class DeepSeekVisionClient implements VisionService {
  DeepSeekVisionClient(
    this._secure, {
    http.Client? httpClient,
    String? model,
  })  : _http = httpClient ?? http.Client(),
        _model = model ?? _resolveDefaultModel();

  static const _kKeyName = 'deepseek_api_key';
  static const _defaultEndpoint = 'https://api.deepseek.com/v1/chat/completions';

  final SecureStore _secure;
  final http.Client _http;
  final String _model;
  String? _proxyEndpoint;

  /// Resolves the model name in this priority order:
  ///   1. `--dart-define=DEEPSEEK_VISION_MODEL=...`
  ///   2. Fallback default — verify against your account.
  static String _resolveDefaultModel() {
    const fromDefine = String.fromEnvironment('DEEPSEEK_VISION_MODEL');
    if (fromDefine.isNotEmpty) return fromDefine;
    // `deepseek-vl2` is DeepSeek's hosted vision model line as of
    // late 2025. If your contract uses a different one (e.g.
    // `deepseek-chat` with vision enabled, or `deepseek-vl-7b-chat`),
    // override via the build define above.
    return 'deepseek-vl2';
  }

  void setProxyEndpoint(String url) => _proxyEndpoint = url;

  Future<String?> _getApiKey() async {
    final stored = await _secure.read(_kKeyName);
    if (stored != null && stored.isNotEmpty) return stored;
    return ApiConfig.deepSeekApiKey.isEmpty ? null : ApiConfig.deepSeekApiKey;
  }

  @override
  Future<bool> isConfigured() async {
    if (_proxyEndpoint != null) return true;
    final key = await _getApiKey();
    return key != null && key.isNotEmpty;
  }

  @override
  Future<Result<VisionResult>> analyse(VisionRequest request) async {
    try {
      final imageFile = File(request.imagePath);
      if (!imageFile.existsSync()) {
        return Result.err(
          UnknownFailure('Image not found: ${request.imagePath}'),
        );
      }
      final bytes = await imageFile.readAsBytes();
      final mime = _guessMime(request.imagePath);
      final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';

      final endpoint = Uri.parse(_proxyEndpoint ?? _defaultEndpoint);
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (_proxyEndpoint == null) {
        final key = await _getApiKey();
        if (key == null || key.isEmpty) {
          return const Result.err(AuthFailure(
            'DeepSeek API key not set. Add a key in Settings or use a proxy.',
          ),);
        }
        headers['Authorization'] = 'Bearer $key';
      } else if (ApiConfig.appTranslateToken.isNotEmpty) {
        // Same shared secret the translation proxy already enforces —
        // one credential covers both endpoints.
        headers['X-App-Token'] = ApiConfig.appTranslateToken;
      }

      final body = jsonEncode({
        'model': _model,
        'messages': [
          {'role': 'system', 'content': _systemPrompt(request)},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': _userPrompt(request)},
              {
                'type': 'image_url',
                'image_url': {'url': dataUrl},
              },
            ],
          },
        ],
        // Low temperature for transcription / extraction tasks; bump
        // up only for [VisionTask.describe] where some flair is fine.
        'temperature': request.task == VisionTask.describe ? 0.4 : 0.1,
        'stream': false,
      });

      final sw = Stopwatch()..start();
      final resp = await _http
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 60));
      sw.stop();

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return Result.err(AuthFailure(
            'DeepSeek rejected the request (${resp.statusCode}). '
            'Check the API key / proxy token.'),);
      }
      if (resp.statusCode == 429) {
        return const Result.err(NetworkFailure(
            'Rate limited — try again in a moment.',),);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        appLogger.w('DeepSeek vision ${resp.statusCode}: ${resp.body}');
        return Result.err(NetworkFailure(
            'Vision service error (${resp.statusCode})',),);
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        return const Result.err(UnknownFailure('Empty vision response'));
      }
      final message = (choices.first as Map<String, dynamic>)['message']
          as Map<String, dynamic>;
      final content = (message['content'] as String?)?.trim() ?? '';

      final usage = json['usage'] as Map<String, dynamic>?;
      final totalTokens = usage?['total_tokens'] is num
          ? (usage!['total_tokens'] as num).toInt()
          : null;

      return Result.ok(VisionResult(
        text: content,
        elapsedMs: sw.elapsedMilliseconds,
        tokensUsed: totalTokens,
        modelName: (json['model'] as String?) ?? _model,
      ),);
    } on SocketException catch (e) {
      return Result.err(NetworkFailure('No network — check your connection',
          cause: e,),);
    } catch (e, st) {
      appLogger.e('DeepSeek vision call failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Vision call failed', cause: e));
    }
  }

  String _systemPrompt(VisionRequest req) {
    final lang = req.targetLanguage == null
        ? ''
        : 'The text is in ${req.targetLanguage}. ';
    switch (req.task) {
      case VisionTask.transcribeHandwriting:
        return '''You are an expert at transcribing handwritten notes from images.
${lang}Read every legible line of handwriting in the image and output the EXACT text.
${req.preserveLineBreaks ? "Preserve the original line breaks." : "Collapse all whitespace into single-spaced text on one paragraph."}
If a word is illegible, write [unreadable] in its place — do not guess.
Output ONLY the transcribed text — no preamble, no explanation, no quoting, no commentary.
If the entire image contains no handwriting, reply with the literal string: NO_HANDWRITING_FOUND.''';
      case VisionTask.extractPrintedText:
        return '''You are a careful OCR engine.
${lang}Extract every visible printed text element from the image — body text, headings, totals, line items, captions, etc.
Preserve the on-page reading order. Use newlines between visually distinct lines.
Do NOT translate, summarise, or rearrange. Do NOT add commentary.
If text is partially obscured but inferrable from context, transcribe it; otherwise mark with [unreadable].''';
      case VisionTask.describe:
        return '''You describe images for a sighted reader who wants a thorough but concise account.
Lead with what the image is (a photograph of X, a diagram of Y, a screenshot of Z), then list the salient details in order of importance.
2–4 short paragraphs at most. Avoid speculation about anything you cannot see.''';
      case VisionTask.answerQuestion:
        return '''You answer questions about a single supplied image.
Base your answer ONLY on what is visible in the image. If the image does not contain enough information to answer, say so plainly.
Keep answers short and direct unless the user asks for detail.''';
    }
  }

  String _userPrompt(VisionRequest req) {
    switch (req.task) {
      case VisionTask.transcribeHandwriting:
        return 'Transcribe the handwriting in this image.';
      case VisionTask.extractPrintedText:
        return 'Extract the printed text from this image.';
      case VisionTask.describe:
        return 'Describe this image.';
      case VisionTask.answerQuestion:
        return req.userQuestion ?? 'What is in this image?';
    }
  }

  String _guessMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg'; // best-effort default; DeepSeek accepts JPEG broadly
  }
}
