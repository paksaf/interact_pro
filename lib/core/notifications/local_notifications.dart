import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/logger.dart';

/// Single channel for "incoming LAN share" notifications. We deliberately
/// don't fragment into per-kind channels — users only ever see "received
/// from <peer>", and channel proliferation makes the system Settings →
/// Notifications view confusing.
const String _kChannelIdLanIncoming = 'lan_incoming';
const String _kChannelNameLanIncoming = 'Received files';
const String _kChannelDescLanIncoming =
    'Posted when another device on your Wi-Fi sends a file to this one.';

/// Tap-payload encoder: route name + file path so the notification handler
/// can reopen the app on the right screen. Format: `route|path`.
String _encodePayload(String routeName, String path) =>
    jsonEncode({'route': routeName, 'path': path});

class _Payload {
  const _Payload({required this.routeName, required this.path});
  final String routeName;
  final String path;

  static _Payload? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final route = m['route'];
      final path = m['path'];
      if (route is String && path is String) {
        return _Payload(routeName: route, path: path);
      }
    } catch (_) {}
    return null;
  }
}

/// Wraps `flutter_local_notifications`. Singleton — initialised once at
/// app boot from `IncomingFileBootstrap.initState` (or wherever the app
/// first wires up the lifecycle observers).
class LocalNotifications {
  LocalNotifications._();
  static final LocalNotifications instance = LocalNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();

  /// Single-shot init; safe to call multiple times. Sets up the Android
  /// notification channel and asks for runtime permission on Android 13+.
  Future<void> init({void Function(String routeName, String path)? onTap}) async {
    if (_initialised) return;
    _initialised = true;

    // Note: iOS / macOS DarwinInitializationSettings + per-platform
    // permissions are not configured here because the LAN cast feature
    // is Android-first (TVs) — but the plugin's init is identical and
    // can be extended without rewriting callers. See README.
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const init = InitializationSettings(android: android);

    await _plugin.initialize(
      init,
      onDidReceiveNotificationResponse: (resp) {
        final payload = _Payload.tryDecode(resp.payload);
        if (payload != null) {
          onTap?.call(payload.routeName, payload.path);
        }
      },
    );

    // Create the channel explicitly. The plugin auto-creates on first
    // post but doing it up-front means the channel appears in system
    // Settings even before a notification has been delivered.
    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        _kChannelIdLanIncoming,
        _kChannelNameLanIncoming,
        description: _kChannelDescLanIncoming,
        importance: Importance.high,
        enableLights: true,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      // Android 13+ requires runtime perm for notifications.
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  bool _initialised = false;

  /// Post a "received from <peer>" notification. Tap opens the app and
  /// routes to [routeName] with [path] as `extra`.
  Future<void> showIncomingShare({
    required String peerName,
    required String filePath,
    required String fileBasename,
    required String routeName,
  }) async {
    if (!_initialised) {
      appLogger.w('LocalNotifications.showIncomingShare called before init()');
      return;
    }

    const androidDetails = AndroidNotificationDetails(
      _kChannelIdLanIncoming,
      _kChannelNameLanIncoming,
      channelDescription: _kChannelDescLanIncoming,
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'Received',
      icon: '@mipmap/ic_launcher',
      // Auto-cancel when tapped — there's nothing useful left in the
      // tray after the user has opened the file.
      autoCancel: true,
      // Show the basename as the big-text expanded view; collapsed
      // view shows just the title / first line.
      styleInformation: BigTextStyleInformation(''),
    );
    const details = NotificationDetails(android: androidDetails);

    // Notification id derived from the file path's hashCode — collisions
    // are fine; same id just replaces the older notification, which is
    // exactly what we want when a user shares the same file twice.
    final id = filePath.hashCode & 0x7FFFFFFF;

    await _plugin.show(
      id,
      'Received from $peerName',
      fileBasename,
      details,
      payload: _encodePayload(routeName, filePath),
    );
  }
}

/// App lifecycle observer that knows whether the app is currently visible
/// to the user. Watched by `IncomingFileBootstrap` to decide between
/// in-app navigation (foreground) and notification (background).
class AppForegroundTracker extends ChangeNotifier with WidgetsBindingObserver {
  AppForegroundTracker() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// True when the Flutter engine reports the app as resumed (visible
  /// and accepting input). False during paused / inactive / detached /
  /// hidden — i.e. the user has switched away.
  bool get isForeground => _isForeground;
  bool _isForeground = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final next = state == AppLifecycleState.resumed;
    if (next != _isForeground) {
      _isForeground = next;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appForegroundTrackerProvider = Provider<AppForegroundTracker>((ref) {
  final tracker = AppForegroundTracker();
  ref.onDispose(tracker.dispose);
  return tracker;
});
