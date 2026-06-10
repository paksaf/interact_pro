import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../../core/device/device_capabilities.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/utils/logger.dart';
import '../../../core/widgets/labeled_icon_button.dart';
import '../../auth/data/auth_api_client.dart' show authRepositoryProvider;
import '../data/voice_command_controller.dart';

/// Floating mic button + bottom sheet that listens for a single voice
/// command and routes the app to the right place.
///
/// Coverage today (matched as case-insensitive substrings — order matters):
///   "settings"       → /settings
///   "scan" / "scanner"→ /scanner
///   "import" / "open"→ home (so user sees the Import button)
///   "library" / "books"→ /library
///   "drive" / "cloud"→ /drive
///   "ocr"            → /ocr
///   "handwrit"       → /handwriting
///   "translate"      → translation sheet trigger (open viewer hint)
///   "upgrade" / "pro"→ /paywall
///   "nearby" / "tv" / "cast" → /nearby
///   "sign out" / "logout"→ /login (also calls authRepo.signOut() — TODO)
///   "help" / "support"→ /support-chat
///
/// Anything else → snackbar "I didn't catch that — try saying 'open scanner'".
///
/// Designed as a minimum-viable scaffold. The intent parser is dumb on
/// purpose: a substring match is enough for a 12-command vocabulary and
/// avoids pulling in an NLU library. When the command set grows past 30
/// entries, replace this with a proper intent classifier.
///
/// On TVs: this button lives top-right of the home AppBar. Pressing the
/// remote's mic button (when wired via the next iteration) will fire the
/// same flow programmatically.
class VoiceCommandButton extends ConsumerStatefulWidget {
  const VoiceCommandButton({super.key});

  @override
  ConsumerState<VoiceCommandButton> createState() => _VoiceCommandButtonState();
}

class _VoiceCommandButtonState extends ConsumerState<VoiceCommandButton> {
  /// Listen flow is delegated to the singleton VoiceCommandController
  /// so the SAME flow can be triggered from the global keyboard handler
  /// in app.dart (TV remote SEARCH key) without duplicating the
  /// init/permission/sheet plumbing. See voice_command_controller.dart.
  Future<void> _listen() async {
    final controller = ref.read(voiceCommandControllerProvider);
    await controller.listen(
      context: context,
      sheetBuilder: (sheetCtx) => VoiceListenSheet(
        speech: controller.speech,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wrapped in LabeledIconButton so TVs / large tablets (where
    // showIconLabels defaults ON, see core/settings/ui_preferences.dart)
    // render "Voice" under the mic icon. Phones get the plain icon
    // since labels are off there by default. Without the label, TV
    // users have no way to discover the voice shortcut — the mic
    // glyph alone reads as "record" not "speak a command".
    // Microphone gate — Sony Bravia VH21 (and most other Android TVs)
    // doesn't expose a mic to apps; the voice listen sheet would just
    // spin forever. Hide the button there. Power users who pair a USB
    // mic and want to test can flip the "Show advanced controls"
    // toggle in Settings → Display.
    return CapabilityGate.microphone(
      child: LabeledIconButton(
        icon: const Icon(Icons.mic_none),
        label: 'Voice',
        tooltip: 'Voice command',
        onPressed: _listen,
      ),
    );
  }
}

class VoiceListenSheet extends ConsumerStatefulWidget {
  const VoiceListenSheet({required this.speech});
  final stt.SpeechToText speech;

  @override
  ConsumerState<VoiceListenSheet> createState() => VoiceListenSheetState();
}

class VoiceListenSheetState extends ConsumerState<VoiceListenSheet> {
  String _heard = '';
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    await widget.speech.listen(
      onResult: (r) {
        setState(() => _heard = r.recognizedWords);
        if (r.finalResult) _onFinal();
      },
      listenFor: const Duration(seconds: 6),
      pauseFor: const Duration(seconds: 2),
    );
  }

  void _onFinal() {
    if (_stopped) return;
    _stopped = true;
    final command = _heard.toLowerCase().trim();
    Navigator.of(context).pop();
    // Fire-and-forget — the route push inside _routeCommand happens
    // synchronously in most branches; the sign-out branch awaits
    // signOut() before pushing, but we don't block the listen-sheet
    // pop on that future. The user's intent is "do this thing"; UI
    // updates within the next frame.
    unawaited(_routeCommand(command));
  }

  Future<void> _routeCommand(String cmd) async {
    if (cmd.isEmpty) {
      _say("I didn't catch that — try saying 'open scanner'");
      return;
    }
    final router = GoRouter.of(context);
    if (cmd.contains('settings')) {
      router.pushNamed(AppRoutes.settings);
    } else if (cmd.contains('scan')) {
      router.pushNamed(AppRoutes.scanner);
    } else if (cmd.contains('library') || cmd.contains('books')) {
      router.pushNamed(AppRoutes.library);
    } else if (cmd.contains('drive') || cmd.contains('cloud')) {
      router.pushNamed(AppRoutes.driveBrowser);
    } else if (cmd.contains('ocr')) {
      router.pushNamed(AppRoutes.ocr);
    } else if (cmd.contains('handwrit') || cmd.contains('write')) {
      router.pushNamed(AppRoutes.handwriting);
    } else if (cmd.contains('upgrade') || cmd.contains('pro')) {
      router.pushNamed(AppRoutes.paywall);
    } else if (cmd.contains('nearby') ||
        cmd.contains('tv') ||
        cmd.contains('cast') ||
        cmd.contains('share')) {
      router.pushNamed(AppRoutes.nearbyDevices);
    } else if (cmd.contains('help') || cmd.contains('support')) {
      router.pushNamed(AppRoutes.supportChat);
    } else if (cmd.contains('home') || cmd.contains('back')) {
      router.goNamed(AppRoutes.home);
    } else if (cmd.contains('import') || cmd.contains('open')) {
      router.goNamed(AppRoutes.home);
      _say('Tap the green "Import PDF" button on screen.');
    } else if (cmd.contains('sign out') || cmd.contains('log out')) {
      // Pre-2026-05-13 this just pushed /login without actually
      // signing out — user re-entered the app and stayed signed in.
      // Now we await the repo's signOut() (clears local token + makes
      // the best-effort server call) before navigating, so the auth
      // state at /login matches what the user just asked for. If
      // signOut fails, log + continue — the route push still happens,
      // login screen will just show the still-signed-in banner.
      try {
        await ref.read(authRepositoryProvider).signOut();
      } catch (e, st) {
        appLogger.w('voice sign-out: signOut() failed', error: e, stackTrace: st);
      }
      if (!mounted) return;
      router.goNamed(AppRoutes.login);
    } else {
      _say('I heard "$cmd" but don\'t know that command yet.');
    }
  }

  void _say(String msg) {
    final ctx = context;
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    widget.speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.mic, size: 40, color: cs.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text(
              'Listening…',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _heard.isEmpty
                  ? 'Say a command — like "open scanner", "library", "settings", "share to TV", or "upgrade".'
                  : _heard,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                widget.speech.stop();
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
