import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/utils/logger.dart';

/// What the server's `/api/version` returns.
class VersionInfo {
  const VersionInfo({
    required this.latest,
    required this.url,
    required this.notes,
    required this.minimumSupported,
  });

  /// e.g. "2.0.2+3" — `pubspec.yaml`-style version+build. Null when
  /// the server hasn't published a manifest yet.
  final String? latest;

  /// Where to download the new APK / IPA.
  final String url;

  /// Short release notes shown in the banner / dialog.
  final String notes;

  /// Optional floor — versions older than this should HARD-prompt the
  /// user to update (the rest are soft-prompts they can dismiss).
  final String? minimumSupported;

  factory VersionInfo.fromJson(Map<String, dynamic> j) {
    return VersionInfo(
      latest: j['latest'] as String?,
      url: (j['url'] as String?) ?? 'https://pro.interactpak.com/InteractPro.apk',
      notes: (j['notes'] as String?) ?? '',
      minimumSupported: j['minimumSupported'] as String?,
    );
  }
}

class UpdateStatus {
  const UpdateStatus({
    required this.hasUpdate,
    required this.required,
    required this.current,
    this.latest,
  });

  final bool hasUpdate;
  final bool required;
  final String current;
  final VersionInfo? latest;
}

/// Polls `/api/version` once on app open and decides whether the
/// running build is stale. Pure read — never auto-installs anything,
/// the user always taps Download.
class VersionCheckService {
  VersionCheckService({http.Client? httpClient, String? baseUrl})
      : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? _defaultBaseUrl;

  static const _defaultBaseUrl = String.fromEnvironment(
    'AUTH_BASE_URL',
    defaultValue: 'https://pro.interactpak.com',
  );

  final http.Client _http;
  final String _baseUrl;

  Future<UpdateStatus> check() async {
    final pkg = await PackageInfo.fromPlatform();
    // Match pubspec convention: "2.0.1+2" — `version+build`.
    final current = '${pkg.version}+${pkg.buildNumber}';

    VersionInfo? remote;
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/api/version'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        remote = VersionInfo.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      appLogger.w('version check failed: $e');
    }

    if (remote == null || remote.latest == null) {
      return UpdateStatus(hasUpdate: false, required: false, current: current);
    }

    final hasUpdate = _isNewer(remote.latest!, current);
    final required = remote.minimumSupported != null &&
        _isNewer(remote.minimumSupported!, current);

    return UpdateStatus(
      hasUpdate: hasUpdate,
      required: required,
      current: current,
      latest: remote,
    );
  }

  /// Compare `a` and `b` as `major.minor.patch+build`. Returns true if
  /// `a` is strictly newer. Hand-rolled because semver packages bring
  /// extra dependencies for what's a 20-line problem.
  static bool _isNewer(String a, String b) {
    int compareSection(String x, String y) {
      final xs = x.split(RegExp(r'[\.+]')).map((s) => int.tryParse(s) ?? 0).toList();
      final ys = y.split(RegExp(r'[\.+]')).map((s) => int.tryParse(s) ?? 0).toList();
      final n = xs.length > ys.length ? xs.length : ys.length;
      for (var i = 0; i < n; i++) {
        final xi = i < xs.length ? xs[i] : 0;
        final yi = i < ys.length ? ys[i] : 0;
        if (xi != yi) return xi - yi;
      }
      return 0;
    }

    return compareSection(a, b) > 0;
  }
}

final versionCheckServiceProvider = Provider<VersionCheckService>((ref) {
  return VersionCheckService();
});

/// Auto-fires once when the home screen mounts. Result fans out to the
/// banner; cached for the rest of the session so repeated home-screen
/// renders don't re-poll.
final updateStatusProvider = FutureProvider<UpdateStatus>((ref) async {
  return ref.watch(versionCheckServiceProvider).check();
});
