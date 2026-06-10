import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../voice/data/stt_controller.dart';
import '../../../voice/presentation/widgets/voice_dictation_button.dart';

/// Returned by [VoiceTextNoteSheet] when the user taps **Insert**.
/// Holds whatever text the user typed or dictated. Returns `null` on cancel.
class VoiceTextNoteResult {
  const VoiceTextNoteResult({required this.text});
  final String text;
}

/// Bottom sheet that lets the user compose a short text annotation by
/// typing OR speaking. Wraps [VoiceDictationButton] and pipes its
/// `onResult` callback into the editable [TextField] so dictation is
/// always editable before commit.
///
/// Live partial-transcript preview is read off [sttStateProvider] so the
/// user can see the recognizer working.
class VoiceTextNoteSheet extends ConsumerStatefulWidget {
  const VoiceTextNoteSheet({
    this.initialText = '',
    this.localeId = 'en_US',
    super.key,
  });

  final String initialText;
  final String localeId;

  @override
  ConsumerState<VoiceTextNoteSheet> createState() => _VoiceTextNoteSheetState();
}

class _VoiceTextNoteSheetState extends ConsumerState<VoiceTextNoteSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Called by [VoiceDictationButton] each time the recognizer emits a
  /// final result. We *append* to the existing text rather than replace
  /// so the user can dictate in chunks (mic toggle → speak → toggle off,
  /// repeat) without losing what they had.
  void _onDictationResult(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final existing = _ctrl.text.trim();
    final merged = existing.isEmpty ? t : '$existing $t';
    setState(() {
      _ctrl
        ..text = merged
        ..selection = TextSelection.collapsed(offset: merged.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final stt = ref.watch(sttStateProvider);
    final partial = stt.partial.trim();
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return Padding(
      // Lift the sheet above the soft keyboard.
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.text_fields),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Add text note',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Type, or tap the mic to dictate…',
                  border: OutlineInputBorder(),
                ),
              ),
              if (stt.isListening || partial.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      if (stt.isListening) ...[
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          partial.isEmpty ? 'Listening…' : partial,
                          style: const TextStyle(fontStyle: FontStyle.italic),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  // The mic itself. onResult appends to the text field.
                  VoiceDictationButton(
                    onResult: _onDictationResult,
                    localeId: widget.localeId,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      stt.isListening
                          ? 'Tap to stop'
                          : 'Tap mic to speak — first time asks for permission.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Insert on current page'),
                    onPressed: () {
                      final text = _ctrl.text.trim();
                      if (text.isEmpty) return;
                      Navigator.of(context).pop(
                        VoiceTextNoteResult(text: text),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
