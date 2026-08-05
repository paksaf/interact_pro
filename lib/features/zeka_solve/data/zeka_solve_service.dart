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

  /// Host that serves `/api/zeka/ai`.
  ///
  /// Defaults to `_auth.baseUrl` (pro.interactpak.com) — i.e. TODAY'S
  /// behaviour is preserved exactly, so this change is non-breaking. That
  /// default is however known-wrong (see the trace note in `_post`): the real
  /// route is on interactpak.com and additionally needs a Zeka JWT, so
  /// repointing alone converts a 404 into a 401.
  ///
  /// Once the auth question is settled, this becomes a build-flag change with
  /// no code edit:
  ///     flutter build apk --dart-define=ZEKA_BASE_URL=https://interactpak.com
  String get _zekaBaseUrl {
    const fromDefine = String.fromEnvironment('ZEKA_BASE_URL');
    return fromDefine.isNotEmpty ? fromDefine : _auth.baseUrl;
  }

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
      // ⚠️ BROKEN IN PRODUCTION — traced 2026-08-05. Two separate faults:
      //
      // 1. WRONG HOST. `_auth.baseUrl` is https://pro.interactpak.com, but
      //    `/api/zeka/ai` does NOT exist there. It lives on interactpak.com
      //    (`interactpak-nextjs/src/app/api/zeka/ai/route.ts`). Caddy routes
      //    non-`/api/ocr/*`,`/api/tts/*` paths on pro.interactpak.com to the
      //    Express pro-api, which has a catch-all 404 — so every Zeka Solve
      //    request 404s. pro-api exposes no zeka route of its own.
      //
      // 2. THE COMMENT THAT USED TO BE HERE WAS FALSE. It claimed the route
      //    "accepts anonymous calls (rate-limited by IP)" and that a bearer
      //    merely "bumps the per-user quota". The real route REQUIRES auth —
      //    no user id ⇒ 401 `sign_in_required` — and then gates on
      //    entitlement ⇒ 402 `premium_required` without an AI plan. It also
      //    wants a *Zeka* JWT from `/api/auth/zeka/verify`, which is a
      //    different credential from this app's own `/api/auth/otp/*` token.
      //
      // Therefore simply repointing the host is NOT a complete fix — it would
      // turn a 404 into a 401. Making this work needs a product decision on
      // how Interact Pro users authenticate to Zeka (mint a Zeka JWT? share
      // fleet SSO? proxy via pro-api with a server-side key?). Left
      // deliberately unchanged pending that call; `ZEKA_BASE_URL` below makes
      // the host a one-flag change once it is made.
      final headers = <String, String>{
        if (isJson) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final uri = Uri.parse('$_zekaBaseUrl/api/zeka/ai');
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
