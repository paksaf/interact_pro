// SPDX-License-Identifier: AGPL-3.0
//
// OfficeConverter — Spike E client.
//
// Uploads a Word / Excel / PowerPoint / Pages / Numbers / Keynote /
// RTF / ODF file to pro.interactpak.com/api/convert/to-pdf and writes
// the returned PDF to the local app-cache dir. Cached by sha256
// hashed locally — re-opening the same .docx skips the network round
// trip entirely.
//
// Use: from IncomingFileListener, when an incoming share has
// ShareKind.document AND a supported Office mime, call
// `OfficeConverter.toPdf(file)`. The returned local PDF path goes
// straight into the normal viewer flow (PdfRepository.open).
//
// Failure mode: returns null and logs. Caller should fall back to
// the existing handoff path (open_filex → installed Office app).

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/logger.dart';
import '../../auth/data/auth_api_client.dart';

class OfficeConverter {
  OfficeConverter(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final AuthApiClient _auth;
  final http.Client _http;

  /// MIME types the server will accept. Used to short-circuit the
  /// upload path entirely for files we already know we can't convert
  /// (the server would return 415 anyway, but a local check saves a
  /// round trip on flaky networks).
  static const Set<String> supportedMimes = {
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/rtf',
    'application/vnd.oasis.opendocument.text',
    'application/vnd.oasis.opendocument.spreadsheet',
    'application/vnd.oasis.opendocument.presentation',
    'application/vnd.apple.pages',
    'application/vnd.apple.numbers',
    'application/vnd.apple.keynote',
  };

  /// Returns the local PDF path on success, null on failure. Pure
  /// disk on the cache-hit path.
  Future<String?> toPdf(File source) async {
    final bytes = await source.readAsBytes();
    final hash = sha256.convert(bytes).toString();

    // Cache check — keep converted PDFs in the app's temp dir under
    // `office-convert/<sha>.pdf`. The OS may evict them under
    // pressure; a re-conversion is idempotent and cheap on the
    // server's HIT path.
    final cacheDir = Directory(p.join(
      (await getTemporaryDirectory()).path,
      'office-convert',
    ));
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    final cachePath = p.join(cacheDir.path, '$hash.pdf');
    final cached = File(cachePath);
    if (cached.existsSync() && cached.lengthSync() > 0) {
      return cachePath;
    }

    final mime = _guessMime(source.path);
    if (!supportedMimes.contains(mime)) {
      appLogger.w('OfficeConverter: unsupported mime $mime — skipping');
      return null;
    }

    try {
      final token = await _auth.bearerToken();
      if (token == null) {
        appLogger.w('OfficeConverter: not signed in — falling back to handoff');
        return null;
      }
      final uri =
          Uri.parse('${_auth.baseUrl}/api/convert/to-pdf');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: p.basename(source.path),
            contentType: MediaType.parse(mime),
          ),
        );
      final streamed =
          await _http.send(req).timeout(const Duration(seconds: 90));
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        appLogger.w(
            'OfficeConverter: HTTP ${streamed.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}');
        return null;
      }
      final pdfBytes = await streamed.stream.toBytes();
      await cached.writeAsBytes(pdfBytes);
      return cachePath;
    } catch (e) {
      appLogger.w('OfficeConverter: failed: $e');
      return null;
    }
  }

  /// Crude mime guess by extension. The server re-checks anyway so
  /// "wrong but in-set" guesses are harmless; "right but out-of-set"
  /// would cause us to skip a conversion we could've done. Worth a
  /// proper `mime` package import later.
  String _guessMime(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.doc': return 'application/msword';
      case '.docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case '.xls': return 'application/vnd.ms-excel';
      case '.xlsx': return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case '.ppt': return 'application/vnd.ms-powerpoint';
      case '.pptx': return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case '.rtf': return 'application/rtf';
      case '.odt': return 'application/vnd.oasis.opendocument.text';
      case '.ods': return 'application/vnd.oasis.opendocument.spreadsheet';
      case '.odp': return 'application/vnd.oasis.opendocument.presentation';
      case '.pages': return 'application/vnd.apple.pages';
      case '.numbers': return 'application/vnd.apple.numbers';
      case '.key': return 'application/vnd.apple.keynote';
      default: return 'application/octet-stream';
    }
  }
}

final officeConverterProvider = Provider<OfficeConverter>((ref) {
  return OfficeConverter(ref.watch(authApiClientProvider));
});
