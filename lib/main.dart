import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/analytics/analytics_service.dart';
import 'core/device/device_info.dart';
import 'core/utils/logger.dart';
import 'features/drive_sync/data/datasources/sync_worker.dart';

/// Detects "TV / large landscape" form factors so we can serve them landscape
/// instead of locking to portrait.
///
/// Three signals, in order of authority:
///   1. [DeviceInfo.isAndroidTv] — set from the Kotlin
///      UiModeManager probe. Most reliable; survives Sony's compact-
///      window quirk where shortestSide reports ~300dp.
///   2. shortest-side ≥ 600dp — covers tablets + most TVs.
///   3. otherwise portrait (phone).
bool _shouldRunLandscape() {
  if (!Platform.isAndroid) return false;
  if (DeviceInfo.isAndroidTv) return true;
  final view = PlatformDispatcher.instance.views.first;
  final size = view.physicalSize / view.devicePixelRatio; // logical px
  return size.shortestSide >= 600;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Probe the OS-reported form factor BEFORE the orientation lock so
  // Sony Bravia (which reports shortestSide ~300 in compact mode) still
  // lands in landscape via the UiModeManager signal. Synchronous after
  // this completes; layout code never hits the channel again.
  await DeviceInfo.probe();

  if (_shouldRunLandscape()) {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } else {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  await Workmanager().initialize(
    syncWorkerDispatcher,
    isInDebugMode: false,
  );

  // Pre-build the ProviderContainer so we can fire an `app_open` event before
  // the first frame — gives the admin dashboard accurate session counts.
  final container = ProviderContainer(
    observers: <ProviderObserver>[const RiverpodLogger()],
  );
  unawaited(container.read(analyticsServiceProvider).track(
        AnalyticsEvents.appOpen,
      ),);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const InteractProApp(),
    ),
  );
}
