import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/permissions/app_permissions.dart';
import '../../../../core/permissions/permission_dialog.dart';
import '../../data/stt_controller.dart';

/// FAB-style mic button. Pass [onResult] to receive the dictated text.
///
/// First tap requests microphone (and on iOS also speech recognition).
/// Subsequent taps toggle listen/stop without re-prompting.
class VoiceDictationButton extends ConsumerWidget {
  const VoiceDictationButton({
    required this.onResult,
    this.localeId = 'en_US',
    super.key,
  });

  final void Function(String text) onResult;
  final String localeId;

  Future<bool> _ensurePermissions(BuildContext context) async {
    final mic = await ensurePermission(
      context: context,
      request: AppPermissions.requestMicrophone,
      featureLabel: 'Microphone',
      reason: 'Voice dictation needs the microphone to capture your speech.',
    );
    if (!mic) return false;

    // iOS additionally requires NSSpeechRecognitionUsageDescription;
    // Android's recognizer doesn't need a separate runtime permission.
    if (Platform.isIOS) {
      if (!context.mounted) return false;
      final speech = await ensurePermission(
        context: context,
        request: AppPermissions.requestSpeechRecognition,
        featureLabel: 'Speech recognition',
        reason: 'Apple speech recognition is what turns your voice into text.',
      );
      if (!speech) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sttStateProvider);
    final notifier = ref.read(sttStateProvider.notifier);

    ref.listen<SttState>(sttStateProvider, (_, next) {
      if (next.finalText.isNotEmpty) onResult(next.finalText);
    });

    return FloatingActionButton(
      heroTag: 'voice_dictation',
      backgroundColor: state.isListening ? Colors.red : null,
      onPressed: () async {
        if (state.isListening) {
          notifier.stop();
          return;
        }
        final ok = await _ensurePermissions(context);
        if (!ok) return;
        await notifier.start(localeId: localeId);
      },
      child: Icon(state.isListening ? Icons.stop : Icons.mic),
    );
  }
}
