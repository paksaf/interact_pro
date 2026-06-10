import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/translation_entities.dart';

/// Two-layer cache for DeepSeek translations:
///
/// 1. In-process LRU (fast, capped at [_maxEntries]) for the current session.
/// 2. SharedPreferences-backed persistent cache so the same request after a
///    restart still avoids the network.
///
/// Keyed by SHA-1 of `target|source|text` so identical paragraphs hit cache
/// across pages and documents.
abstract class TranslationCache {
  Future<TranslationResult?> get(TranslationRequest req);
  Future<void> put(TranslationRequest req, TranslationResult result);
  Future<void> clear();
}

final translationCacheProvider = Provider<TranslationCache>((Ref ref) {
  return _SharedPrefsTranslationCache();
});

class _SharedPrefsTranslationCache implements TranslationCache {
  static const _prefix = 'translation_cache.';
  static const _maxEntries = 256;

  final LinkedHashMap<String, TranslationResult> _memo =
      LinkedHashMap<String, TranslationResult>();

  String _key(TranslationRequest r) {
    final raw = '${r.targetLanguage}|${r.sourceLanguage}|${r.text}';
    return _prefix + sha1.convert(utf8.encode(raw)).toString();
  }

  @override
  Future<TranslationResult?> get(TranslationRequest req) async {
    final k = _key(req);

    // Fast path: in-memory.
    final inMemo = _memo.remove(k);
    if (inMemo != null) {
      _memo[k] = inMemo; // mark as MRU
      return inMemo;
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(k);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final res = TranslationResult(
        translatedText: json['t'] as String,
        detectedSourceLanguage: (json['s'] as String?) ?? req.sourceLanguage,
        targetLanguage: (json['l'] as String?) ?? req.targetLanguage,
      );
      _put(k, res);
      return res;
    } catch (_) {
      await prefs.remove(k);
      return null;
    }
  }

  @override
  Future<void> put(TranslationRequest req, TranslationResult result) async {
    final k = _key(req);
    _put(k, result);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      k,
      jsonEncode({
        't': result.translatedText,
        's': result.detectedSourceLanguage,
        'l': result.targetLanguage,
      }),
    );
  }

  void _put(String k, TranslationResult v) {
    _memo.remove(k);
    _memo[k] = v;
    while (_memo.length > _maxEntries) {
      _memo.remove(_memo.keys.first);
    }
  }

  @override
  Future<void> clear() async {
    _memo.clear();
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
