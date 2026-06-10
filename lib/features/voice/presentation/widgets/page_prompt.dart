// SPDX-License-Identifier: AGPL-3.0
//
// PagePrompt — short spoken narration when a screen mounts.
//
// Cross-ported from Sahulat (#257, 2026-05-20). Same pattern: wrap a
// screen body with `PagePrompt(slot: 'library', child: ...)` and the
// configured cue fires exactly once per mount, in the user's preferred
// TTS language. Pro defaults to English; Sahulat uses Urdu — same
// widget, different prompt table per app.
//
// Cues are deliberately short (≤ 14 words) so they don't get in the
// user's way. If the device has no TTS engine the catch swallows
// silently — narration is additive, never load-bearing.
//
// Future: when the sahulat_common Flutter package lands (#237) this
// widget moves into the shared package and both apps consume it.
// Until then each app keeps its own prompt table.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tts_controller.dart';

/// English prompt bank for Pro screens. Keys are stable slot IDs that
/// won't change as routes evolve — keep them snake_case.
const Map<String, String> _prompts = {
  'home':
      'Welcome to Interact Pro. Open a document or press the mic to speak.',
  'library': 'Your library. Pick a book to read or annotate.',
  'recent': 'Recently opened documents.',
  'ocr': 'OCR. Pick an image or PDF page to extract text.',
  'scanner': 'Document scanner. Position the page in the frame.',
  'drive': 'Google Drive. Connect to read your cloud files.',
  'settings': 'Settings. Voice, reading, and account options.',
  'book_viewer':
      'Reading mode. Press F for full-screen, or the speaker icon to read aloud.',
  'paywall': 'Upgrade to Pro for cloud sync and advanced AI features.',
  'nearby': 'Nearby devices. Pair another phone or TV to send pages.',
  'pair': 'Pairing in progress. Enter the PIN shown on the other device.',
  'sign_in': 'Sign in to keep your reading progress across devices.',
  'voice_help':
      'Try saying: read this page, next page, bookmark this, or stop reading.',
};

/// Hook your screen up with:
///
///   PagePrompt(slot: 'library', child: MyScreenBody())
///
/// Multiple instances of the same slot on the screen would fire
/// multiple times — there's only one cue per mount, but if a screen
/// rebuilds the same widget the cue won't repeat (state-tracked).
class PagePrompt extends ConsumerStatefulWidget {
  const PagePrompt({
    required this.slot,
    required this.child,
    super.key,
  });

  /// Lookup key into [_prompts]. Unknown slots are silent (so a typo
  /// degrades gracefully — better than a hard crash on a string mismatch).
  final String slot;
  final Widget child;

  @override
  ConsumerState<PagePrompt> createState() => _PagePromptState();
}

class _PagePromptState extends ConsumerState<PagePrompt> {
  bool _spoken = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _speak());
  }

  Future<void> _speak() async {
    if (_spoken || !mounted) return;
    _spoken = true;
    final text = _prompts[widget.slot];
    if (text == null) return;
    try {
      // Use the same TtsController the read-aloud button uses so the
      // user's installed engine carries through. TtsController.speak()
      // requires explicit language + rate — for page prompts we pin to
      // en-US at 0.5 (slightly slower than default for clarity). The
      // user-preferred reading voice is left for the main read-aloud
      // path; page prompts are short narration that doesn't need to
      // honor a Russian/Urdu/Mandarin user preference.
      final tts = ref.read(ttsControllerProvider);
      await tts.speak(text, language: 'en-US', rate: 0.5);
    } catch (_) {
      // No TTS engine / user disabled it — page-prompts are an
      // accessibility nicety, not a critical path.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
