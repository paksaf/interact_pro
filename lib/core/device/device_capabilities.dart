// SPDX-License-Identifier: AGPL-3.0
//
// DeviceCapabilities — central question-answerer for "does THIS device
// support feature X". Used to hide icons / actions that exist in the
// codebase but make no sense on the current device class.
//
// Examples of icon clutter we wanted to clean up (task #156):
//   • Microphone button on Android TV — Sony Bravia VH21 has no mic
//     exposed to apps. The button is dead weight.
//   • "Scan document" camera button on TV — TVs don't have cameras
//     and the activity crashes on launch.
//   • "Share via Bluetooth" on TV — no Bluetooth out path; tap = error.
//   • LAN cast send button on phone with no peers paired — surfacing
//     the icon implies it'll work; hidden until a paired device exists.
//
// All capability checks combine:
//   • OS form-factor (DeviceInfo.isAndroidTv)
//   • Platform.isAndroid / isIOS for OS-specific assumptions
//   • Optionally a user preference to OVERRIDE the hide and show
//     everything ("Show advanced controls" toggle in Settings).
//
// Usage:
//   if (DeviceCapabilities.of(context).hasCamera) IconButton(...)
//   CapabilityGate.camera(child: IconButton(...))   // sugar wrapper

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/ui_preferences.dart';
import 'device_info.dart';

/// One device class's view of what's possible. Cheap to construct —
/// values are O(1) lookups against [DeviceInfo] + dart:io.
@immutable
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.hasCamera,
    required this.hasMicrophone,
    required this.hasTouch,
    required this.canShare,
    required this.canHandwrite,
    required this.canCastReceive,
    required this.canCastSend,
    required this.isTv,
  });

  /// Phone/tablet have a rear+front camera; Android TV does not
  /// (Bravia firmware doesn't expose any usable camera intent).
  final bool hasCamera;

  /// Apps can record audio on phone/tablet. TVs route audio through
  /// the soundbar/HDMI and don't expose a microphone to user apps.
  final bool hasMicrophone;

  /// True when the user can touch the screen. TV is D-pad only.
  /// Used for hiding pinch-zoom hints, drag-to-reorder affordances, etc.
  final bool hasTouch;

  /// Whether the OS share-sheet exists. Always on iOS/Android phone +
  /// tablet; on Android TV the ACTION_SEND chooser launches but most
  /// targets are gone (no installed messaging apps), so we suppress.
  final bool canShare;

  /// Phone/tablet can write with a finger or stylus on a Signature
  /// pad / annotation overlay. TV has no pointer device that makes
  /// handwriting work — D-pad cannot draw curves.
  final bool canHandwrite;

  /// This device can RECEIVE a Pro-to-Pro cast (be the "TV" end).
  /// Only Android TV qualifies — phones/tablets are senders.
  final bool canCastReceive;

  /// This device can SEND a Pro-to-Pro cast (be the "phone" end).
  /// Phones + tablets always; TV can't (it IS the receiver).
  final bool canCastSend;

  /// OS-reported TV form factor. Convenience accessor; the same value
  /// is also factored into the per-feature flags above.
  final bool isTv;

  /// Compute capabilities from the current device + platform. Pure
  /// function — call from build() with no concern about cost.
  static DeviceCapabilities current() {
    final tv = DeviceInfo.isAndroidTv;
    final android = Platform.isAndroid;
    final ios = Platform.isIOS;
    final phoneOrTablet = (android && !tv) || ios;
    return DeviceCapabilities(
      hasCamera: phoneOrTablet,
      hasMicrophone: phoneOrTablet,
      hasTouch: !tv,
      canShare: phoneOrTablet,
      canHandwrite: phoneOrTablet,
      canCastReceive: tv,
      canCastSend: phoneOrTablet,
      isTv: tv,
    );
  }

  /// Apply the user's "show advanced controls" override. When the
  /// override is ON, every capability gate reports true so power users
  /// can still see the icon (and accept the tap-and-fail consequence).
  /// Defaults to OFF — environment-irrelevant icons stay hidden.
  DeviceCapabilities overriddenIf(bool showAll) {
    if (!showAll) return this;
    return const DeviceCapabilities(
      hasCamera: true,
      hasMicrophone: true,
      hasTouch: true,
      canShare: true,
      canHandwrite: true,
      canCastReceive: true,
      canCastSend: true,
      isTv: false,
    );
  }

  /// Riverpod-aware accessor — prefer [CapabilityGate] for widget use
  /// since it rebuilds reactively. This method is a one-shot snapshot
  /// for non-widget code (e.g. deciding whether to wire a global
  /// keyboard shortcut at boot).
  static DeviceCapabilities read(WidgetRef ref) {
    final prefs = ref.read(uiPreferencesProvider);
    return current().overriddenIf(prefs.showAdvancedIcons);
  }
}

/// Tiny helper widget that conditionally renders [child] based on a
/// capability check. The single-line constructors document what kind
/// of capability is being gated.
///
/// ```dart
/// CapabilityGate.camera(child: IconButton(icon: Icon(Icons.camera), …)),
/// ```
class CapabilityGate extends ConsumerWidget {
  const CapabilityGate.camera({required this.child, super.key})
      : _check = _Capability.camera;
  const CapabilityGate.microphone({required this.child, super.key})
      : _check = _Capability.microphone;
  const CapabilityGate.touch({required this.child, super.key})
      : _check = _Capability.touch;
  const CapabilityGate.share({required this.child, super.key})
      : _check = _Capability.share;
  const CapabilityGate.handwrite({required this.child, super.key})
      : _check = _Capability.handwrite;
  const CapabilityGate.castSend({required this.child, super.key})
      : _check = _Capability.castSend;
  const CapabilityGate.castReceive({required this.child, super.key})
      : _check = _Capability.castReceive;

  /// Hide when on TV (sugar for "phone-only" actions).
  const CapabilityGate.notTv({required this.child, super.key})
      : _check = _Capability.notTv;

  /// Show only on TV.
  const CapabilityGate.tvOnly({required this.child, super.key})
      : _check = _Capability.tvOnly;

  final Widget child;
  final _Capability _check;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(uiPreferencesProvider);
    final caps = DeviceCapabilities.current().overriddenIf(prefs.showAdvancedIcons);
    final allow = switch (_check) {
      _Capability.camera => caps.hasCamera,
      _Capability.microphone => caps.hasMicrophone,
      _Capability.touch => caps.hasTouch,
      _Capability.share => caps.canShare,
      _Capability.handwrite => caps.canHandwrite,
      _Capability.castSend => caps.canCastSend,
      _Capability.castReceive => caps.canCastReceive,
      _Capability.notTv => !caps.isTv,
      _Capability.tvOnly => caps.isTv,
    };
    return allow ? child : const SizedBox.shrink();
  }
}

enum _Capability {
  camera,
  microphone,
  touch,
  share,
  handwrite,
  castSend,
  castReceive,
  notTv,
  tvOnly,
}
