import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/api_config.dart';
import '../../../core/error/failures.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../domain/translation_entities.dart';
import 'translation_cache.dart';

final deepSeekClientProvider = Provider<DeepSeekClient>((Ref ref) {
  final client = DeepSeekClient(
    ref.watch(secureStoreProvider),
    cache: ref.watch(translationCacheProvider),
  );
  // Prefer build-time config if it's there. Direct in-app keys are still
  // honored for power users who set one via `setApiKey`.
  if (ApiConfig.deepSeekProxyUrl.isNotEmpty) {
    client.setProxyEndpoint(ApiConfig.deepSeekProxyUrl);
  }
  return client;
});

/// Direct client for DeepSeek's chat-completions API.
///
/// SECURITY NOTE: shipping a long-lived API key inside a mobile app is
/// risky — anyone can extract it via decompilation.
///
/// For production, proxy through your own backend so the key never leaves
/// your servers, and have the backend enforce per-user rate limits + Pro
/// subscription checks. This client supports either path:
///   • [setApiKey] writes a key into platform-secure storage (dev / power user).
///   • [setProxyEndpoint] points the client at your backend that injects
///     the key server-side and enforces auth.
class DeepSeekClient {
  DeepSeekClient(this._secure, {http.Client? httpClient, TranslationCache? cache})
      : _http = httpClient ?? http.Client(),
        _cache = cache;

  static const _kKeyName = 'deepseek_api_key';
  static const _defaultEndpoint = 'https://api.deepseek.com/v1/chat/completions';
  static const _model = 'deepseek-chat';

  final SecureStore _secure;
  final http.Client _http;
  final TranslationCache? _cache;
  String? _proxyEndpoint;

  /// Point the client at your backend instead of api.deepseek.com directly.
  /// Recommended for production builds.
  void setProxyEndpoint(String url) => _proxyEndpoint = url;

  Future<void> setApiKey(String key) => _secure.write(_kKeyName, key);

  /// Prefer (in order): runtime override via `setApiKey`, then a key supplied
  /// by `--dart-define=DEEPSEEK_API_KEY=...` at build time.
  Future<String?> _getApiKey() async {
    final stored = await _secure.read(_kKeyName);
    if (stored != null && stored.isNotEmpty) return stored;
    return ApiConfig.deepSeekApiKey.isEmpty ? null : ApiConfig.deepSeekApiKey;
  }

  Future<Result<TranslationResult>> translate(TranslationRequest req) async {
    // Cache hit short-circuits the network entirely.
    if (_cache != null) {
      final hit = await _cache.get(req);
      if (hit != null) return Result.ok(hit);
    }

    try {
      final endpoint = Uri.parse(_proxyEndpoint ?? _defaultEndpoint);
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (_proxyEndpoint == null) {
        final key = await _getApiKey();
        if (key == null || key.isEmpty) {
          return const Result.err(AuthFailure('DeepSeek API key not set'));
        }
        headers['Authorization'] = 'Bearer $key';
      } else if (ApiConfig.appTranslateToken.isNotEmpty) {
        // Proxy mode + APP_TRANSLATE_TOKEN baked in at build time → send
        // it so the proxy's APP_SHARED_SECRET gate accepts the call.
        headers['X-App-Token'] = ApiConfig.appTranslateToken;
      }

      final body = jsonEncode({
        'model': _model,
        'messages': [
          {'role': 'system', 'content': _buildSystemPrompt(req)},
          {'role': 'user', 'content': req.text},
        ],
        'temperature': 0.2,
        'stream': false,
      });

      final resp = await _http
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode == 429) {
        return const Result.err(
          NetworkFailure('Rate limited — try again in a moment.'),
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        appLogger.w('DeepSeek error ${resp.statusCode}: ${resp.body}');
        return Result.err(NetworkFailure(
          'Translation service error (${resp.statusCode})',
        ),);
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        return const Result.err(UnknownFailure('Empty translation response'));
      }
      final message = (choices.first as Map<String, dynamic>)['message']
          as Map<String, dynamic>;
      final content = (message['content'] as String?)?.trim() ?? '';

      final result = TranslationResult(
        translatedText: content,
        detectedSourceLanguage: req.sourceLanguage,
        targetLanguage: req.targetLanguage,
      );
      if (_cache != null) await _cache.put(req, result);
      return Result.ok(result);
    } catch (e, st) {
      appLogger.e('translate failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Translation failed', cause: e));
    }
  }

  String _buildSystemPrompt(TranslationRequest req) {
    final tgt = SupportedLanguages.all[req.targetLanguage] ?? req.targetLanguage;
    final preserve = req.preserveFormatting
        ? 'Preserve line breaks, paragraph structure, lists, numbering, '
          'and any visible formatting cues. '
        : '';
    return '''You are a professional translator. Translate the user's text to $tgt.
Output ONLY the translated text — no preamble, no explanations, no quotes around the result.
${preserve}If the input is already in the target language, return it unchanged.''';
  }
}
