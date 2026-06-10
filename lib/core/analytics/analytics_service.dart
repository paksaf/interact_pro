import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/api_config.dart';
import '../utils/logger.dart';

/// Lightweight, transport-agnostic analytics for first-party admin
/// dashboards (interactpak.com).
///
/// **Design choices**
/// * No third-party SDK. Events POST as JSON to your own backend at
///   [ApiConfig.analyticsEndpointUrl] — *you* control retention, exposure,
///   and what gets shown publicly.
/// * Anonymous user id (UUID v4) generated on first launch and persisted.
///   No PII collected. The id is the unit of "visitor" you'd render on the
///   marketing dashboard.
/// * Opt-out is honored locally (`prefs.analytics_opt_out`) — no events
///   leave the device when set.
/// * Events batch in memory and flush either on `flush()` or every
///   [_flushIntervalSeconds]. Failed flushes drop the batch (no retry
///   storm; analytics is best-effort, not exactly-once).
abstract class AnalyticsService {
  Future<void> init();
  Future<void> track(String event, {Map<String, dynamic>? properties});
  Future<void> flush();
  Future<void> setOptOut(bool optOut);
  Future<bool> isOptedOut();

  /// Stable per-install anonymous identifier.
  Future<String> visitorId();
}

/// Pre-defined event names. Use these constants instead of string literals
/// at call sites so the dashboard schema stays consistent.
class AnalyticsEvents {
  AnalyticsEvents._();

  static const appOpen = 'app_open';
  static const featureUsed = 'feature_used';
  static const paywallViewed = 'paywall_viewed';
  static const trialStarted = 'trial_started';
  static const trialExpired = 'trial_expired';
  static const purchaseStarted = 'purchase_started';
  static const purchaseCompleted = 'purchase_completed';
  static const purchaseRestored = 'purchase_restored';
  static const supportLinkClicked = 'support_link_clicked';
  static const documentImported = 'document_imported';
  static const ocrRun = 'ocr_run';
  static const translationRun = 'translation_run';
  static const driveSync = 'drive_sync';
}

final analyticsServiceProvider = Provider<AnalyticsService>((Ref ref) {
  final svc = HttpAnalyticsService();
  ref.onDispose(svc.dispose);
  // Lazy init — fire-and-forget; first track() also lazy-inits.
  unawaited(svc.init());
  return svc;
});

class HttpAnalyticsService implements AnalyticsService {
  static const _kVisitorIdKey = 'analytics.visitor_id';
  static const _kOptOutKey = 'analytics.opt_out';
  static const _flushIntervalSeconds = 30;
  static const _maxQueue = 100;

  final List<Map<String, dynamic>> _queue = [];
  Timer? _flushTimer;
  String? _cachedVisitorId;
  bool _initialized = false;

  http.Client _client = http.Client();

  /// Replace the http client (used by tests).
  void setHttpClient(http.Client client) {
    _client.close();
    _client = client;
  }

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await visitorId();
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      const Duration(seconds: _flushIntervalSeconds),
      (_) => unawaited(flush()),
    );
  }

  @override
  Future<String> visitorId() async {
    if (_cachedVisitorId != null) return _cachedVisitorId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kVisitorIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_kVisitorIdKey, id);
    }
    _cachedVisitorId = id;
    return id;
  }

  @override
  Future<bool> isOptedOut() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOptOutKey) ?? false;
  }

  @override
  Future<void> setOptOut(bool optOut) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOptOutKey, optOut);
    if (optOut) _queue.clear();
  }

  @override
  Future<void> track(String event,
      {Map<String, dynamic>? properties,}) async {
    if (!_initialized) await init();
    if (await isOptedOut()) return;

    final payload = <String, dynamic>{
      'event': event,
      'visitor_id': await visitorId(),
      'ts': DateTime.now().toUtc().toIso8601String(),
      'platform': _platformName,
      'is_debug': kDebugMode,
      if (properties != null && properties.isNotEmpty)
        'properties': properties,
    };

    _queue.add(payload);
    if (_queue.length >= _maxQueue) {
      unawaited(flush());
    }
  }

  @override
  Future<void> flush() async {
    if (_queue.isEmpty) return;
    if (ApiConfig.analyticsEndpointUrl.isEmpty) {
      // No backend configured — drop the queue (events were tracked locally
      // for the session and that's the contract in dev mode).
      _queue.clear();
      return;
    }
    if (await isOptedOut()) {
      _queue.clear();
      return;
    }

    final batch = List<Map<String, dynamic>>.from(_queue);
    _queue.clear();

    try {
      final resp = await _client
          .post(
            Uri.parse(ApiConfig.analyticsEndpointUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'events': batch}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        appLogger.w(
          'analytics flush ${resp.statusCode}: ${resp.body.substring(0, resp.body.length > 200 ? 200 : resp.body.length)}',
        );
      }
    } catch (e) {
      // Best-effort — never throw out of analytics.
      appLogger.w('analytics flush failed: $e');
    }
  }

  String get _platformName {
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {
      // Web / unsupported platform.
    }
    return 'unknown';
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    _client.close();
  }
}
