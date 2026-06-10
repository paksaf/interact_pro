// SPDX-License-Identifier: AGPL-3.0
//
// ZekaSolveService — Spike C.
//
// Proxies math / science / engineering questions to the existing
// pro.interactpak.com/api/zeka/ai endpoint (same one the standalone
// Zeka app uses). Pro reuses the same route — we don't ship a
// duplicate AI gateway. The DeepSeek/OpenAI key lives server-side in
// /etc/interact/pro-api.env (per zeka_multimodal_pipeline memory).
//
// Two entry points:
//
//   • solveText(question)              — plain text
//   • solveImage(question, pngBytes)   — text + image, e.g. the user
//                                        long-presses an equation and
//                                        we ship a 1600px crop. The
//                                        server already pins image
//                                        compression at 1600px/80q.
//
// Returns ZekaSolveResult with steps[] and a final answer line.
// Failures surface as ZekaSolveResult.error(...) — callers show that
// in the sheet without throwing.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/utils/logger.dart';
import '../../auth/data/auth_api_client.dart';

class ZekaSolveResult {
  const ZekaSolveResult({
    required this.ok,
    this.answer,
    this.steps = const [],
    this.provider,
    this.error,
  });

  factory ZekaSolveResult.error(String message) =>
      ZekaSolveResult(ok: false, error: message);

  factory ZekaSolveResult.fromJson(Map<String, dynamic> j) => ZekaSolveResult(
        ok: j['ok'] == true,
        answer: j['answer'] as String?,
        steps: ((j['steps'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        provider: j['provider'] as String?,
        error: j['error'] as String?,
      );

  final bool ok;
  final String? answer;
  final List<String> steps;
  final String? provider;
  final String? error;
}

class ZekaSolveService {
  ZekaSolveService(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final AuthApiClient _auth;
  final http.Client _http;

  /// Text-only question. Same JSON shape the standalone Zeka app
  /// uses: `{ "question": "..." }`.
  Future<ZekaSolveResult> solveText(String question) async {
    return _post(body: jsonEncode({'question': question}), isJson: true);
  }

  /// Multimodal — `question` + a PNG/JPEG crop. Server prompt has a
  /// TRANSCRIBE-ONLY exception so handwritten math screenshots return
  /// the latex/numeric transcription before solving. Mime defaults to
  /// `image/png` — pass `image/jpeg` for JPEG bytes.
  Future<ZekaSolveResult> solveImage({
    required String question,
    required Uint8List imageBytes,
    String imageMime = 'image/png',
  }) async {
    final imageBase64 = base64Encode(imageBytes);
    return _post(
      body: jsonEncode({
        'question': question,
        'imageBase64': imageBase64,
        'imageMime': imageMime,
      }),
      isJson: true,
    );
  }

  Future<ZekaSolveResult> _post({
    required String body,
    required bool isJson,
  }) async {
    try {
      final token = await _auth.bearerToken();
      // /api/zeka/ai accepts anonymous calls (rate-limited by IP).
      // Sending a bearer when we have one bumps the per-user quota.
      final headers = <String, String>{
        if (isJson) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final uri = Uri.parse('${_auth.baseUrl}/api/zeka/ai');
      final resp =
          await _http.post(uri, headers: headers, body: body).timeout(
                const Duration(seconds: 45),
              );
      if (resp.statusCode != 200) {
        appLogger.w('Zeka /ai HTTP ${resp.statusCode}: '
            '${resp.body.substring(0, resp.body.length.clamp(0, 200))}');
        return ZekaSolveResult.error('Zeka returned ${resp.statusCode}.');
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return ZekaSolveResult.fromJson(j);
    } catch (e) {
      appLogger.w('Zeka /ai failed: $e');
      return ZekaSolveResult.error('Network failure: $e');
    }
  }
}

final zekaSolveServiceProvider = Provider<ZekaSolveService>((ref) {
  return ZekaSolveService(ref.watch(authApiClientProvider));
});
