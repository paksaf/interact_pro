// INTERACT analytics — Dart port of analytics.ts. Sink-agnostic event client;
// posts batches to the same /api/analytics collector the web uses (unified
// dashboards). dependency-free (dart:io). Same event names as the web.
import 'dart:convert';
import 'dart:io';

class GrowthEvents {
  static const appOpen = 'app_open';
  static const sessionStart = 'session_start';
  static const win = 'win_moment';
  static const signup = 'signup';
  static const activated = 'activated';
  static const inviteSent = 'invite_sent';
  static const purchase = 'purchase';
}

class Analytics {
  final String app;
  final String endpoint; // e.g. https://pro.interactpak.com/api/analytics
  String? userId;
  Map<String, String> attrib;
  final List<Map<String, dynamic>> _q = [];

  Analytics({
    required this.app,
    required this.endpoint,
    this.userId,
    this.attrib = const {},
  });

  void identify(String id, [Map<String, String>? a]) {
    userId = id;
    if (a != null) attrib = {...attrib, ...a};
  }

  void touchSession() {
    // optional: gate sessionStart by a 30-min gap via SharedPreferences
    track(GrowthEvents.sessionStart);
  }

  void track(String name, [Map<String, dynamic>? props]) {
    _q.add({'name': name, 'props': props, 'ts': DateTime.now().toIso8601String()});
    // fire-and-forget
    flush();
  }

  Future<void> flush() async {
    if (_q.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_q);
    _q.clear();
    // FIXED 2026-08-05 — the client was created inside the try and closed only
    // on the SUCCESS path, so every failed send (offline, DNS, timeout) leaked
    // one HttpClient and its socket. `track()` calls `flush()` on every single
    // event, so on a flaky connection this leaked per-event and never
    // recovered. Now the client is closed in a `finally`, and the request has
    // a timeout — previously there was none at all, so a black-holed
    // connection could hang the future indefinitely.
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.postUrl(Uri.parse(endpoint));
      req.headers.set('content-type', 'application/json');
      req.add(utf8.encode(jsonEncode({
        'app': app,
        'userId': userId,
        'attrib': attrib,
        'events': batch,
      })));
      await req.close().timeout(const Duration(seconds: 15));
    } catch (_) {
      _q.insertAll(0, batch); // requeue on failure
    } finally {
      // `force: false` lets an in-flight successful response drain cleanly.
      client?.close();
    }
  }
}
