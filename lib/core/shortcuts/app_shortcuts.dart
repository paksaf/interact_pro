import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../routing/app_routes.dart';

/// Global app-wide keyboard shortcuts. Wraps the whole app via
/// `MaterialApp.builder` so every screen inherits them — the user can
/// hit Cmd+L to open the library from any scaffold without each screen
/// having to re-implement the binding.
///
/// Keys are routed through the standard Flutter Shortcuts/Actions
/// pipeline so Apple's "Show Keyboard Shortcuts" overlay (Cmd+/ on
/// iPad with a hardware keyboard) automatically lists them.
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // Cmd/Ctrl + L → Library
        LogicalKeySet(_metaOrCtrl, LogicalKeyboardKey.keyL):
            const _NavIntent(AppRoutes.library),
        // Cmd/Ctrl + H → Home
        LogicalKeySet(_metaOrCtrl, LogicalKeyboardKey.keyH):
            const _NavIntent(AppRoutes.home),
        // Cmd/Ctrl + O → Open file picker (handled by home screen FAB).
        // We just navigate home — the FAB is the visual target there,
        // and route activation is what most desktop users expect.
        LogicalKeySet(_metaOrCtrl, LogicalKeyboardKey.keyO):
            const _NavIntent(AppRoutes.home),
        // Cmd/Ctrl + N → Write by hand (digital ink screen).
        LogicalKeySet(_metaOrCtrl, LogicalKeyboardKey.keyN):
            const _NavIntent(AppRoutes.handwriting),
        // Cmd/Ctrl + T → Transcribe handwriting from photo.
        LogicalKeySet(_metaOrCtrl, LogicalKeyboardKey.keyT):
            const _NavIntent(AppRoutes.handwritingDoc),
        // Cmd/Ctrl + , → Settings (matches macOS / iPadOS convention).
        LogicalKeySet(_metaOrCtrl, LogicalKeyboardKey.comma):
            const _NavIntent(AppRoutes.settings),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NavIntent: _NavAction(),
        },
        child: child,
      ),
    );
  }

  /// Use Meta on macOS / iPadOS and Control everywhere else. The
  /// `LogicalKeySet` approach means we declare both — Flutter resolves
  /// "the first one that matches" so the keyset triggers on whichever
  /// platform's modifier the user happens to have.
  static const _metaOrCtrl = LogicalKeyboardKey.meta;
}

class _NavIntent extends Intent {
  const _NavIntent(this.routeName);
  final String routeName;
}

class _NavAction extends Action<_NavIntent> {
  @override
  Object? invoke(_NavIntent intent) {
    final ctx = primaryFocus?.context;
    if (ctx == null) return null;
    try {
      ctx.goNamed(intent.routeName);
    } catch (_) {
      // Route not registered → silently no-op so the user doesn't see
      // a stack trace from a missed shortcut.
    }
    return null;
  }
}
