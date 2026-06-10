// SPDX-License-Identifier: AGPL-3.0
//
// Authoritative TV / form-factor detection.
//
// Background: the existing `WindowSize.isTabletDevice` /
// `shortestSide >= 720` heuristics can FAIL on Sony Bravia firmware
// that launches sideloaded apps in compact portrait windows around
// 300dp wide, even though the physical screen is 1920×1080. The
// MediaQuery numbers reflect the launched window, not the screen.
//
// This module exposes the OS-level answer via a Kotlin platform
// channel that reads `UiModeManager.currentModeType` directly. On
// any device that reports `UI_MODE_TYPE_TELEVISION` we trust the OS
// over dimension math.
//
// Lifecycle: probe once at app boot (in main()), stash the result in
// the static `DeviceInfo.isAndroidTv` field. Synchronous accesses
// from layout code never hit the channel again. Safe to call before
// MaterialApp mounts.

import 'dart:io';

import 'package:flutter/services.dart';

class DeviceInfo {
  /// Set once during boot. Defaults to false until the platform channel
  /// returns. On non-Android platforms it stays false (TV form factor
  /// is Android-only for Pro right now — Apple TV is not supported).
  static bool isAndroidTv = false;

  static const _channel = MethodChannel('interact_pro/device_info');

  /// Probe the OS for TV mode. Idempotent and cheap to call multiple
  /// times — caches the result in [isAndroidTv]. Wrap the call in a
  /// try/catch so a missing-channel error on iOS (or during widget
  /// tests) doesn't crash boot — the field stays at its default false.
  static Future<void> probe() async {
    if (!Platform.isAndroid) return;
    try {
      final result = await _channel.invokeMethod<bool>('isAndroidTv');
      isAndroidTv = result ?? false;
    } catch (_) {
      // Channel not registered (e.g. older APK, hot-restart without
      // platform-side reload) — fall back to false; layout code will
      // use shortestSide as the secondary signal.
      isAndroidTv = false;
    }
  }
}
