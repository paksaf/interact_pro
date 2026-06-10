import 'package:flutter/material.dart';

import '../device/device_info.dart';

/// Single source of truth for "is this device acting like a phone, a
/// tablet, or a desktop right now". Width-driven, not platform-driven —
/// a phone in landscape with the on-screen keyboard up is still phone-
/// ish, while an iPad in Slide Over with a 320pt presentation is
/// effectively phone-shaped and should render the phone layout.
///
/// Breakpoints picked to match Material 3 window-size classes:
///   • compact:  < 600  — phones, narrow split views
///   • medium:  600–839 — tablet portrait, foldable inner display, large phones
///   • expanded: ≥ 840  — tablet landscape, desktop, iPad Stage Manager
///
/// Usage from any widget:
/// ```dart
/// final size = WindowSize.of(context);
/// if (size.isExpanded) { ... two-pane layout ... }
/// ```
enum WindowSize {
  compact,
  medium,
  expanded;

  bool get isCompact => this == WindowSize.compact;
  bool get isMedium => this == WindowSize.medium;
  bool get isExpanded => this == WindowSize.expanded;

  /// True for medium AND expanded — i.e. "anything wider than a phone".
  /// Most layout switches use this rather than checking individual sizes.
  bool get isTabletOrWider =>
      this == WindowSize.medium || this == WindowSize.expanded;

  static WindowSize of(BuildContext context) {
    // OS-reported TV form factor overrides dimension math. Sony Bravia
    // VH21 can launch the activity in a 304×540 compact window where
    // every dimension-based heuristic says "phone" — but UiModeManager
    // still correctly reports TELEVISION. Trust it.
    if (DeviceInfo.isAndroidTv) return WindowSize.expanded;

    final size = MediaQuery.of(context).size;
    final w = size.width;
    final h = size.height;
    // Use the LONGER side (not just width) so a TV in landscape — which
    // sometimes reports a narrow logical width because of system overscan
    // and density quirks — still resolves to "expanded". Without this,
    // some Android TVs ended up showing the phone-narrow column layout
    // even though they had a 1920×1080 screen because their reported
    // logical width came in below 600.
    final longest = w > h ? w : h;
    if (longest >= 1200) return WindowSize.expanded; // TV / desktop / iPad landscape
    if (w >= 840) return WindowSize.expanded;
    if (w >= 600) return WindowSize.medium;
    return WindowSize.compact;
  }

  /// True if the device hardware reports tablet-like physical
  /// dimensions, regardless of current window size. Useful for choosing
  /// font scale / icon density at runtime, since "I'm on an iPad mini"
  /// is meaningfully different from "I'm in Slide Over on an iPad mini".
  ///
  /// Heuristic: shortest side ≥ 600 dp. Roughly matches Android's
  /// historical `sw600dp` resource qualifier and works on every iPad
  /// (including iPad mini) but not on phones.
  static bool isTabletDevice(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return size.shortestSide >= 600;
  }
}

/// Lays children out either in a `Row` (tablets / desktop) or as a
/// stack-of-pages with a back button (phones). The first child is the
/// "master" pane, the second is the "detail" pane.
///
/// The master pane is given a fixed [masterWidth] when the row layout is
/// active so the detail pane gets all remaining flex.
class AdaptivePane extends StatelessWidget {
  const AdaptivePane({
    required this.master,
    required this.detail,
    this.masterWidth = 320,
    this.divider = true,
    super.key,
  });

  final Widget master;
  final Widget detail;
  final double masterWidth;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final size = WindowSize.of(context);
    if (!size.isTabletOrWider) {
      // On phones the parent screen is responsible for navigating
      // master → detail via go_router; we just show the master.
      return master;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: masterWidth, child: master),
        if (divider)
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        Expanded(child: detail),
      ],
    );
  }
}

/// Wraps a phone-shaped form (Settings, Login, paywall, etc.) so it
/// renders as a centered card with bounded width on tablet/TV instead
/// of stretching edge-to-edge.
///
/// On a 1920×1080 TV a single-column ListView with full-width
/// `ListTile`s ends up with a foot-wide tap target on each row — it
/// looks like a phone form blown up to monitor size. Constraining the
/// inner width to ~720dp keeps the visual reading rhythm a user
/// recognizes from a tablet, while still letting tall content scroll
/// naturally. On phones the wrapper is a no-op so the form keeps its
/// existing edge-to-edge layout.
///
/// Usage:
/// ```dart
/// body: LandscapeFormBody(
///   child: ListView( ... ),
/// )
/// ```
class LandscapeFormBody extends StatelessWidget {
  const LandscapeFormBody({
    required this.child,
    this.maxWidth = 720,
    super.key,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final size = WindowSize.of(context);
    if (!size.isTabletOrWider) return child;
    return Align(
      // Anchor to top so a short form sits near the AppBar rather than
      // floating in the middle of a TV screen. The horizontal axis is
      // still centered via the ConstrainedBox below.
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
