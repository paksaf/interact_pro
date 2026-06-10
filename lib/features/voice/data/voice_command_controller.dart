// SPDX-License-Identifier: AGPL-3.0
//
// Voice command controller — singleton owner of the SpeechToText
// instance plus a callable `listen(context)` method. Originally the
// listen flow lived inline in VoiceCommandButton's state, which made
// it impossible to invoke from anywhere else in the app (e.g. from a
// global keyboard shortcut on TV).
//
// Refactored 2026-05-13 so both the home AppBar button AND a global
// `HardwareKeyboard` handler in app.dart can fire the same flow. On
// Android TV the handler captures KEYCODE_SEARCH (Sony Bravia
// magnifying-glass remote button — not pre-empted by Google Assistant
// the way KEYCODE_ASSIST is) and calls `listen(context)` directly.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../../core/permissions/app_permissions.dart';
import '../../../core/utils/logger.dart';

class VoiceCommandController {
  VoiceCommandController();

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialised = false;
  bool _busy = false;

  /// Direct access for the sheet widget that needs to wire result
  /// callbacks. Treat as read-only from outside; mutation goes through
  /// `listen()` / `cancel()`.
  stt.SpeechToText get speech => _speech;

  Future<bool> ensureInit() async {
    if (_initialised) return true;
    final ok = await _speech.initialize(
      onError: (e) => appLogger.w('SpeechToText error: $e'),
      onStatus: (s) => appLogger.i('SpeechToText status: $s'),
    );
    _initialised = ok;
    return ok;
  }

  /// Show the voice-listen sheet. Safe to call from anywhere with a
  /// `BuildContext` — re-entry is guarded by `_busy` so rapid double-
  /// invocation (e.g. user mashes the remote SEARCH key while the
  /// sheet is already opening) is a no-op.
  ///
  /// The sheet widget is passed in from the call site so this file
  /// stays decoupled from the widget tree — VoiceCommandButton hands
  /// its own `_VoiceListenSheet` over here; the app-shell handler
  /// imports the same widget and does likewise.
  Future<void> listen({
    required BuildContext context,
    required WidgetBuilder sheetBuilder,
  }) async {
    if (_busy) return;
    _busy = true;
    try {
      final ok = await ensureInit();
      if (!context.mounted) return;
      if (!ok) {
        // Init failure ≈ mic permission denial. Surface an actionable
        // snackbar with a Settings deep-link. Identical UX to the
        // VoiceCommandButton path (#28) — kept consistent on purpose
        // so TV users see the same message whether they tap or use
        // the remote.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Voice unavailable — microphone permission denied.',
            ),
            action: SnackBarAction(
              label: 'Open Settings',
              onPressed: () => AppPermissions.openSettings(),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isDismissible: true,
        builder: sheetBuilder,
      );
    } finally {
      _busy = false;
    }
  }
}

/// Singleton — held across the app's lifetime. SpeechToText is
/// expensive to spin up (~300ms init on first use) so we keep one
/// instance and reuse it.
final voiceCommandControllerProvider = Provider<VoiceCommandController>((ref) {
  return VoiceCommandController();
});
