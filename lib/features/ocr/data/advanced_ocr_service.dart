// SPDX-License-Identifier: AGPL-3.0
//
// AdvancedOcrService — Flutter client for the Phase 1 Python AI backend
// at pro.interactpak.com /api/ocr/advanced (Surya OCR + Tesseract
// fallback).
//
// The on-device pipeline (ML Kit + Tesseract) stays the default. This
// service is engaged only when the user flips the "Advanced layout
// analysis" toggle on the OCR screen, which itself is hidden until the
// AI backend is configured (i.e. INTERACT_PRO_AI_SECRET was provided
// at build time).
//
// Contract: see ../../../../interact-pro-ai-backend/README.md
//
// The bearer-token model mirrors Comms Hub's INTERACT_HUB_TOKEN — a
// shared random hex secret baked into the build via --dart-define.
// Public APK ships without one, so the toggle stays disabled for
// regular users until we promote the build with the production secret.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';

/// One detected block on the page. Mirrors the JSON envelope returned
/// by the FastAPI service. `bbox` is [x0, y0, x1, y1] in original
/// image pixel coords.
@immutable
class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.bbox,
    required this.type,
    required this.confidence,
  });
  final String text;
  final List<double> bbox;
  final String type; // "text" | "table" | "figure" | "header" | "caption"
  final double confidence;

  factory OcrBlock.fromJson(Map<String, dynamic> j) => OcrBlock(
        text: j['text'] as String? ?? '',
        bbox: ((j['bbox'] as List?) ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(growable: false),
        type: j['type'] as String? ?? 'text',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
      );
}

@immutable
class OcrTable {
  const OcrTable({required this.csv, required this.bbox});
  final String csv;
  final List<double> bbox;

  factory OcrTable.fromJson(Map<String, dynamic> j) => OcrTable(
        csv: j['csv'] as String? ?? '',
        bbox: ((j['bbox'] as List?) ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(growable: false),
      );
}

@immutable
class AdvancedOcrResult {
  const AdvancedOcrResult({
    required this.engine,
    required this.blocks,
    required this.tables,
    required this.languageDetected,
    required this.elapsedMs,
  });

  /// "surya" or "tesseract" — the server picks the engine. Always
  /// returned so the UI can surface "Engine: Surya · 1234 ms".
  final String engine;
  final List<OcrBlock> blocks;
  final List<OcrTable> tables;
  final String? languageDetected;
  final int elapsedMs;

  /// Convenience: concatenate every block's text in reading order
  /// (top-to-bottom by bbox.y0). The text-only view the OCR screen
  /// renders today plugs straight into this.
  String get flatText {
    final sorted = [...blocks]
      ..sort((a, b) {
        final ay = a.bbox.isNotEmpty ? a.bbox[1] : 0;
        final by = b.bbox.isNotEmpty ? b.bbox[1] : 0;
        return ay.compareTo(by);
      });
    return sorted.map((b) => b.text).join('\n');
  }

  factory AdvancedOcrResult.fromJson(Map<String, dynamic> j) =>
      AdvancedOcrResult(
        engine: j['engine'] as String? ?? 'unknown',
        blocks: ((j['blocks'] as List?) ?? const [])
            .map((e) => OcrBlock.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        tables: ((j['tables'] as List?) ?? const [])
            .map((e) => OcrTable.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        languageDetected: j['language_detected'] as String?,
        elapsedMs: (j['elapsed_ms'] as num?)?.toInt() ?? 0,
      );
}

class AdvancedOcrFailure implements Exception {
  AdvancedOcrFailure(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() => 'AdvancedOcrFailure($message)';
}

class AdvancedOcrService {
  AdvancedOcrService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Available when the build has INTERACT_PRO_AI_SECRET set. The OCR
  /// screen reads this to decide whether to render the toggle at all.
  bool get isAvailable => AppConstants.aiBackendConfigured;

  /// Send a single page image to the AI backend and parse the result.
  ///
  /// `imageBytes` — PNG or JPEG of one rendered page. If you have the
  /// PDF page index, pass `pageHint` so server-side logs are useful.
  /// `lang` — optional ISO 639-1 code. The server auto-detects when
  /// omitted; the hint just biases recognition.
  Future<AdvancedOcrResult> analyze({
    required Uint8List imageBytes,
    int? pageHint,
    String? lang,
  }) async {
    if (!isAvailable) {
      throw AdvancedOcrFailure(
        'Advanced OCR is not configured on this build. '
        'Reach out to the admin to enable it.',
      );
    }

    final uri = Uri.parse(
      '${AppConstants.aiBackendBaseUrl}${AppConstants.aiAdvancedOcrPath}',
    );
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${AppConstants.aiBackendSecret}'
      ..files.add(http.MultipartFile.fromBytes(
        'image',
        imageBytes,
        filename: 'page.png',
      ));
    if (pageHint != null) req.fields['page_hint'] = pageHint.toString();
    if (lang != null && lang.isNotEmpty) req.fields['lang'] = lang;

    try {
      final streamed =
          await _client.send(req).timeout(const Duration(seconds: 90));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        appLogger.w(
          'AdvancedOCR: HTTP ${streamed.statusCode} — $body',
        );
        throw AdvancedOcrFailure(
          'Server returned ${streamed.statusCode}.',
        );
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final result = AdvancedOcrResult.fromJson(json);
      appLogger.i(
        'AdvancedOCR: engine=${result.engine} blocks=${result.blocks.length} '
        'elapsed=${result.elapsedMs}ms',
      );
      return result;
    } on AdvancedOcrFailure {
      rethrow;
    } catch (e, st) {
      appLogger.e('AdvancedOCR request failed', error: e, stackTrace: st);
      throw AdvancedOcrFailure('Network or parsing error.', cause: e);
    }
  }

  void close() => _client.close();
}

final advancedOcrServiceProvider = Provider<AdvancedOcrService>((ref) {
  final svc = AdvancedOcrService();
  ref.onDispose(svc.close);
  return svc;
});
