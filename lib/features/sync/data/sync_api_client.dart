import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../auth/data/auth_api_client.dart';

/// Client for the per-user document storage API on the VPS. The auth
/// JWT (issued by `pro.interactpak.com/api/auth`) authenticates every
/// call; the server scopes storage by user id.
///
/// Backend contract (`pro.interactpak.com/api/sync`):
///
/// `GET  /api/sync/manifest`
///   → `200 { documents: [{ id, name, sizeBytes, mtime, sha256, version }] }`
///   Used by the client to diff local vs cloud and decide what to upload
///   / download. `version` is a server-side monotonic counter so we can
///   detect "another device updated this".
///
/// `POST /api/sync/upload`            multipart: `pdf` (file) + `meta` (json)
///   → `200 { id, version, sha256 }` on success
///   → `409` if `If-Match: <expected version>` doesn't match — surfaces
///       the conflict so the client can prompt "keep mine / theirs / both".
///   Note: server enforces per-user storage quota (100MB free, 10GB Pro).
///
/// `GET  /api/sync/download/{id}`
///   → `200 application/pdf` (stream)
///   → `404` if id unknown / not owned by caller.
///
/// `DELETE /api/sync/{id}`
///   → `204` on success.
///
/// `GET  /api/sync/quota`
///   → `200 { usedBytes, totalBytes, planLabel }` — for the storage
///       indicator on the Settings screen.
class SyncApiClient {
  SyncApiClient(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final AuthApiClient _auth;
  final http.Client _http;

  String get _baseUrl => _auth.baseUrl;

  Future<Map<String, String>> _authHeaders() async {
    final token = await _auth.bearerToken();
    if (token == null) {
      throw const FormatException('No auth token — sign in first.');
    }
    return {'Authorization': 'Bearer $token'};
  }

  Future<Result<List<RemoteDoc>>> manifest() async {
    try {
      final headers = await _authHeaders();
      final resp = await _http
          .get(Uri.parse('$_baseUrl/api/sync/manifest'), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 401) {
        return const Result.err(AuthFailure('Session expired — sign in again.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
            'Manifest fetch failed (${resp.statusCode})',),);
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final docs = (json['documents'] as List<dynamic>)
          .map((e) => RemoteDoc.fromJson(e as Map<String, dynamic>))
          .toList();
      return Result.ok(docs);
    } catch (e, st) {
      appLogger.e('manifest failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Manifest fetch failed', cause: e));
    }
  }

  Future<Result<RemoteDoc>> upload({
    required File file,
    String? expectedVersion,
  }) async {
    try {
      final headers = await _authHeaders();
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/sync/upload'),
      );
      req.headers.addAll(headers);
      if (expectedVersion != null) {
        req.headers['If-Match'] = expectedVersion;
      }
      req.fields['meta'] = jsonEncode({
        'name': p.basename(file.path),
        'sizeBytes': file.lengthSync(),
        'mtime': file.lastModifiedSync().toIso8601String(),
      });
      // contentType: omitted — http resolves application/pdf from the
      // `.pdf` extension. Avoids pulling http_parser explicitly.
      req.files.add(await http.MultipartFile.fromPath(
        'pdf',
        file.path,
      ),);
      final streamed = await req.send().timeout(const Duration(minutes: 2));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 409) {
        return const Result.err(NetworkFailure(
            'Conflict — the cloud version is newer.',),);
      }
      if (resp.statusCode == 401) {
        return const Result.err(AuthFailure('Session expired — sign in again.'));
      }
      if (resp.statusCode == 413) {
        return const Result.err(NetworkFailure(
            'File exceeds your storage quota.',),);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
            'Upload failed (${resp.statusCode})',),);
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Result.ok(RemoteDoc.fromJson(json));
    } catch (e, st) {
      appLogger.e('upload failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Upload failed', cause: e));
    }
  }

  /// Streams the requested document into [destFile]. Returns the file
  /// path on success.
  Future<Result<String>> download({
    required String id,
    required File destFile,
  }) async {
    try {
      final headers = await _authHeaders();
      final req = http.Request('GET', Uri.parse('$_baseUrl/api/sync/download/$id'));
      req.headers.addAll(headers);
      final streamed = await req.send().timeout(const Duration(minutes: 5));
      if (streamed.statusCode == 404) {
        return const Result.err(NetworkFailure('Not found in cloud.'));
      }
      if (streamed.statusCode == 401) {
        return const Result.err(AuthFailure('Session expired — sign in again.'));
      }
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        return Result.err(
            NetworkFailure('Download failed (${streamed.statusCode})'),);
      }
      final sink = destFile.openWrite();
      await streamed.stream.pipe(sink);
      await sink.close();
      return Result.ok(destFile.path);
    } catch (e, st) {
      appLogger.e('download failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Download failed', cause: e));
    }
  }

  Future<Result<QuotaStatus>> quota() async {
    try {
      final headers = await _authHeaders();
      final resp = await _http
          .get(Uri.parse('$_baseUrl/api/sync/quota'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 401) {
        return const Result.err(AuthFailure('Session expired.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const Result.err(NetworkFailure('Quota fetch failed.'));
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Result.ok(QuotaStatus(
        usedBytes: (json['usedBytes'] as num).toInt(),
        totalBytes: (json['totalBytes'] as num).toInt(),
        planLabel: (json['planLabel'] as String?) ?? 'Free',
      ),);
    } catch (e, st) {
      appLogger.e('quota failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Quota fetch failed', cause: e));
    }
  }
}

class RemoteDoc {
  const RemoteDoc({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.mtime,
    required this.sha256,
    required this.version,
  });
  final String id;
  final String name;
  final int sizeBytes;
  final DateTime mtime;
  final String sha256;
  final String version;

  factory RemoteDoc.fromJson(Map<String, dynamic> j) => RemoteDoc(
        id: j['id'] as String,
        name: j['name'] as String,
        sizeBytes: (j['sizeBytes'] as num).toInt(),
        mtime: DateTime.parse(j['mtime'] as String),
        sha256: j['sha256'] as String,
        version: j['version'].toString(),
      );
}

class QuotaStatus {
  const QuotaStatus({
    required this.usedBytes,
    required this.totalBytes,
    required this.planLabel,
  });
  final int usedBytes;
  final int totalBytes;
  final String planLabel;
  double get usedFraction =>
      totalBytes == 0 ? 0 : (usedBytes / totalBytes).clamp(0.0, 1.0);
}

final syncApiClientProvider = Provider<SyncApiClient>((ref) {
  return SyncApiClient(ref.watch(authApiClientProvider));
});
