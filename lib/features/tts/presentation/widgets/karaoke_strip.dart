// SPDX-License-Identifier: AGPL-3.0
//
// KaraokeStrip — bottom-of-screen footer chip that highlights the
// currently spoken word as TTS plays. Subscribes to a
// `ValueListenable<TtsProgress>` from the active TtsService.
//
// Renders a horizontally-scrolling text strip with a ±5-word window
// around the current word. The current word is in bold cyan; words
// already read fade to the surface-variant colour; upcoming words are
// in the default body colour.
//
// Why a strip not a full overlay: on TV the BookViewer fills the
// screen edge-to-edge, and we don't want to obscure the actual page.
// The strip is 48dp tall, anchors to the bottom safe area, and
// auto-hides when the TtsService isn't speaking.
//
// Why a window not the whole text: a single OCR page can have 400+
// words. Rendering them all in a single Row would blow out the row's
// natural width and require complex auto-scroll math. Showing only
// the active word ± 5 neighbours keeps the layout simple and the
// "what was just said / what's coming up" context intact.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../data/tts_service.dart';

class KaraokeStrip extends StatelessWidget {
  const KaraokeStrip({required this.progress, super.key});

  /// Live progress notifier from the active TtsService. The widget
  /// rebuilds on each emission; idle state hides the strip entirely.
  final ValueListenable<TtsProgress> progress;

  static const int _windowRadius = 5;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TtsProgress>(
      valueListenable: progress,
      builder: (context, snap, _) {
        if (!snap.isActive) {
          // Reserve zero height when idle so BookViewer layout doesn't
          // jump when playback starts/stops. AnimatedSwitcher fades the
          // strip in/out cleanly.
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final words = snap.words;
        final cur = snap.currentWordIndex;
        final from = (cur - _windowRadius).clamp(0, words.length);
        final to = (cur + _windowRadius + 1).clamp(0, words.length);

        return SafeArea(
          top: false,
          left: false,
          right: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withOpacity(0.92),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: const Color(0xFF22D3EE).withOpacity(0.55),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF22D3EE).withOpacity(0.15),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.graphic_eq,
                  size: 18,
                  color: Color(0xFF22D3EE),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: theme.textTheme.bodyMedium,
                      children: [
                        for (var i = from; i < to; i++)
                          TextSpan(
                            text: '${words[i]}${i == to - 1 ? '' : ' '}',
                            style: TextStyle(
                              fontWeight: i == cur
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: i == cur
                                  ? const Color(0xFF22D3EE)
                                  : i < cur
                                      ? theme.colorScheme.onSurfaceVariant
                                          .withOpacity(0.55)
                                      : theme.colorScheme.onSurface,
                              fontSize: i == cur ? 16 : 14,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
