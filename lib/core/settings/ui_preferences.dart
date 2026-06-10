// SPDX-License-Identifier: AGPL-3.0
//
// UI preferences for the Pro shell — read-once-write-through to
// SharedPreferences, exposed as Riverpod state so widgets rebuild on
// change. Currently just the icon-labels toggle; expand here as more
// shell-level prefs come up.

import 'dart:io' show Platform;
import 'dart:ui' show window;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Snapshot of the user's shell-level UI preferences. Immutable; the
/// notifier emits a new instance on every change so consumers can
/// `ref.watch` safely.
class UiPreferences {
  const UiPreferences({
    required this.showIconLabels,
    required this.showAdvancedIcons,
  });

  /// When true, toolbar IconButtons render with a small text label
  /// underneath (the IconButton's `tooltip` value, abbreviated). Helps
  /// discoverability on TV (D-pad users can't easily reveal tooltips)
  /// and on tablets where there's room to spare.
  final bool showIconLabels;

  /// When true, ALL icons render regardless of device capability — i.e.
  /// the [CapabilityGate] wrappers (camera, mic, share, …) become
  /// transparent and let their children through. Default false: we
  /// hide environment-irrelevant icons (mic on TV, camera on TV, etc.).
  /// Power users who want to see everything flip this in Settings →
  /// Display. Per task #156.
  final bool showAdvancedIcons;

  UiPreferences copyWith({
    bool? showIconLabels,
    bool? showAdvancedIcons,
  }) =>
      UiPreferences(
        showIconLabels: showIconLabels ?? this.showIconLabels,
        showAdvancedIcons: showAdvancedIcons ?? this.showAdvancedIcons,
      );
}

/// True when the current device is large enough to be a TV. Same
/// heuristic the rest of the app uses for the import-fallback sheet
/// (home_screen.dart line ~174). Plain top-level so the initial-default
/// computation can run without a BuildContext.
bool isTvLikeDevice() {
  // Compute from the physical display the engine reports, not from a
  // BuildContext — this runs at notifier construction time. shortestSide
  // ≥ 720 logical pixels covers every 1080p+ TV but never a phone or
  // tablet in portrait. Restricted to Android/Linux because iOS and
  // macOS TVs aren't currently a target.
  final v = window.physicalSize / window.devicePixelRatio;
  final shortest = v.shortestSide;
  return shortest >= 720 && (Platform.isAndroid || Platform.isLinux);
}

class UiPreferencesNotifier extends StateNotifier<UiPreferences> {
  UiPreferencesNotifier()
      : super(UiPreferences(
          showIconLabels: isTvLikeDevice(),
          // Default OFF — hide environment-irrelevant icons. User opts
          // in via Settings → Display if they want to see everything.
          showAdvancedIcons: false,
        )) {
    _load();
  }

  // Bump this if the stored shape ever changes incompatibly so old
  // values get treated as missing and the default kicks in again.
  static const _kShowIconLabelsKey = 'ui.show_icon_labels.v1';
  static const _kShowAdvancedIconsKey = 'ui.show_advanced_icons.v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_kShowIconLabelsKey);
    if (stored != null) {
      state = state.copyWith(showIconLabels: stored);
    }
    final advStored = prefs.getBool(_kShowAdvancedIconsKey);
    if (advStored != null) {
      state = state.copyWith(showAdvancedIcons: advStored);
    }
    // If null, we keep the platform-default (true on TV, false on phone)
    // chosen at construction. First write from the user replaces it.
  }

  Future<void> setShowIconLabels(bool value) async {
    state = state.copyWith(showIconLabels: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowIconLabelsKey, value);
  }

  Future<void> setShowAdvancedIcons(bool value) async {
    state = state.copyWith(showAdvancedIcons: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowAdvancedIconsKey, value);
  }
}

final uiPreferencesProvider =
    StateNotifierProvider<UiPreferencesNotifier, UiPreferences>(
  (ref) => UiPreferencesNotifier(),
);
