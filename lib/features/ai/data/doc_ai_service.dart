// SPDX-License-Identifier: AGPL-3.0
//
// DocAiService (market-fit Gate B, 2026-06-12) — chat-with-document, the
// feature ChatPDF / Acrobat AI lead with and the one Interact Pro lacked.
// Extracts the PDF's text on-device (Syncfusion PdfTextExtractor) and sends
// it to pro-api /api/ai/doc-chat, which grounds a DeepSeek answer in the
// text. Pro/trial-gated server-side; a 402 surfaces an upgrade hint.
//
// For long PDFs we send the current page ± a window so a 500-page book can't
// blow the token budget; "Summarize whole doc" sends from page 1 up to the
// server's char cap.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../../core/constants/app_constants.dart';

enum DocAiMode { ask, summarize, extract, translate }

class DocAiResult {
  DocAiResult({required this.ok, this.answer, this.error, this.upgrade = false, this.truncated = false});
  final bool ok;
  final String? answer;
  final String? error;
  final bool upgrade; // 402 — needs Pro/trial
  final bool truncated;
}

class DocAiService {
  DocAiService({FlutterSecureStorage? secure, http.Client? client})
      : _secure = secure ?? const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true)),
        _client = client ?? http.Client();

  final FlutterSecureStorage _secure;
  final http.Client _client;
  static const _kJwtKey = 'auth_jwt';

  /// Extract text from [filePath]. If [aroundPage] is given (1-based), returns
  /// a window of pages centred on it (default ±2) so long docs stay bounded;
  /// otherwise extracts from page 1. Returns '' for scanned/image-only PDFs.
  Future<String> extractText(String filePath, {int? aroundPage, int window = 2}) async {
    final bytes = await File(filePath).readAsBytes();
    final doc = sf.PdfDocument(inputBytes: bytes);
    try {
      final extractor = sf.PdfTextExtractor(doc);
      final total = doc.pages.count;
      int start = 0, end = total - 1;
      if (aroundPage != null) {
        start = (aroundPage - 1 - window).clamp(0, total - 1);
        end = (aroundPage - 1 + window).clamp(0, total - 1);
      }
      final buf = StringBuffer();
      for (var i = start; i <= end; i++) {
        buf.writeln(extractor.extractText(startPageIndex: i, endPageIndex: i));
        if (buf.length > 28000) break; // safety; server caps at 24k too
      }
      return buf.toString().trim();
    } finally {
      doc.dispose();
    }
  }

  Future<DocAiResult> chat({
    required String docText,
    DocAiMode mode = DocAiMode.ask,
    String? question,
    String? targetLang,
    List<Map<String, String>> history = const [],
  }) async {
    final jwt = await _secure.read(key: _kJwtKey);
    if (jwt == null) {
      return DocAiResult(ok: false, error: 'Please sign in to use the AI assistant.');
    }
    final uri = Uri.parse('${AppConstants.aiBackendBaseUrl}/api/ai/doc-chat');
    try {
      final res = await _client
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $jwt',
              },
              body: jsonEncode({
                'docText': docText,
                'mode': mode.name,
                if (question != null) 'question': question,
                if (targetLang != null) 'targetLang': targetLang,
                'history': history,
              }))
          .timeout(const Duration(seconds: 35));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 402) {
        return DocAiResult(ok: false, upgrade: true, error: 'AI assistant is a Pro feature.');
      }
      if (res.statusCode >= 400 || j['ok'] != true) {
        return DocAiResult(ok: false, error: (j['error'] ?? 'AI error').toString());
      }
      return DocAiResult(ok: true, answer: j['answer']?.toString(), truncated: j['truncated'] == true);
    } catch (e) {
      return DocAiResult(ok: false, error: 'Could not reach the AI service. $e');
    }
  }
}
