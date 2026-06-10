// SPDX-License-Identifier: AGPL-3.0
//
// LocalVoiceIntent — rules-first local matcher for spoken commands.
//
// Cross-ported from Sahulat's voice_intent_service.dart (#257,
// 2026-05-20). Sahulat's variant hits /api/voice/intent on the server
// for the rules pass + AI fallback. Pro runs offline-first so the
// rules layer stays local; AI fallback is deliberately omitted here
// because BookViewer commands ("next page", "stop reading") are
// closed-vocabulary and don't benefit from a model round-trip.
//
// When `sahulat_common` lands (#237) the union of the two matchers
// can move into the shared package — Pro keeps the local rules, the
// (optional) server hop becomes a strategy plug-in for apps that
// have a backend.
//
// Coverage:
//   • Reading control:  read, read this, read aloud, start reading
//                       stop, stop reading, pause, pause reading
//                       next, next page, page forward
//                       previous, previous page, back, page back
//                       first page, last page, page <N>
//   • Bookmarking:      bookmark, bookmark this, save this page
//                       remove bookmark, unbookmark
//   • Display:          full screen, fullscreen, exit fullscreen
//                       zoom in, zoom out, fit
//   • Navigation:       home, library, settings, drive, scanner,
//                       ocr, handwriting, translate, paywall, nearby
//   • System:           help, what can you say
//
// Anything else returns a `BookCommand.unknown` with the original
// transcript so the caller can show a "didn't catch that" snackbar.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Coarse intent buckets — covers BookViewer-specific actions plus the
/// pre-existing navigation set. Extending: add a new enum value, add
/// the matching keyword list to `_keywords`, and the caller does the
/// rest. No model retraining, no server round-trip.
enum BookCommand {
  // Reading control
  readAloud,
  stopReading,
  pauseReading,
  nextPage,
  previousPage,
  firstPage,
  lastPage,
  jumpToPage, // payload: pageNumber

  // Bookmarking
  toggleBookmark,
  removeBookmark,

  // Display
  toggleFullscreen,
  exitFullscreen,
  zoomIn,
  zoomOut,
  fit,

  // Navigation (overlap with VoiceCommandButton routes)
  home,
  library,
  settings,
  drive,
  scanner,
  ocr,
  handwriting,
  translate,
  paywall,
  nearby,

  // System
  help,
  unknown,
}

/// Resolved intent. `pageNumber` is populated only when [command] is
/// [BookCommand.jumpToPage] — otherwise null. `originalTranscript`
/// keeps the raw spoken text so the caller can surface a "you said:
/// 'foo'" hint when the intent is `unknown`.
class VoiceIntent {
  const VoiceIntent({
    required this.command,
    required this.originalTranscript,
    this.pageNumber,
  });

  final BookCommand command;
  final String originalTranscript;
  final int? pageNumber;

  bool get isUnknown => command == BookCommand.unknown;
}

/// Ordered keyword bank. Order matters: earlier entries win on
/// ambiguous overlaps (e.g. "stop reading" matches stopReading before
/// the substring "read" can trigger readAloud).
const _keywords = <BookCommand, List<String>>{
  BookCommand.stopReading: ['stop reading', 'stop', 'silence', 'quiet'],
  BookCommand.pauseReading: ['pause reading', 'pause'],
  BookCommand.readAloud: [
    'read this page',
    'read this',
    'read aloud',
    'start reading',
    'read it',
    'read',
  ],
  BookCommand.nextPage: ['next page', 'next', 'page forward', 'forward'],
  BookCommand.previousPage: [
    'previous page',
    'previous',
    'page back',
    'go back',
    'back',
  ],
  BookCommand.firstPage: ['first page', 'beginning', 'start of book'],
  BookCommand.lastPage: ['last page', 'end of book', 'the end'],
  BookCommand.removeBookmark: ['remove bookmark', 'unbookmark', 'delete bookmark'],
  BookCommand.toggleBookmark: ['bookmark this', 'save this page', 'bookmark'],
  BookCommand.exitFullscreen: ['exit full screen', 'exit fullscreen'],
  BookCommand.toggleFullscreen: ['full screen', 'fullscreen'],
  BookCommand.zoomIn: ['zoom in', 'bigger', 'magnify'],
  BookCommand.zoomOut: ['zoom out', 'smaller'],
  BookCommand.fit: ['fit page', 'fit to screen', 'reset zoom'],
  BookCommand.home: ['home', 'go home', 'main screen'],
  BookCommand.library: ['library', 'books', 'my library'],
  BookCommand.settings: ['settings', 'preferences', 'options'],
  BookCommand.drive: ['drive', 'cloud', 'google drive'],
  BookCommand.scanner: ['scanner', 'scan'],
  BookCommand.ocr: ['ocr', 'extract text'],
  BookCommand.handwriting: ['handwriting', 'write by hand'],
  BookCommand.translate: ['translate', 'translation'],
  BookCommand.paywall: ['upgrade', 'pro', 'subscription'],
  BookCommand.nearby: ['nearby', 'pair', 'cast', 'tv'],
  BookCommand.help: ['help', 'what can you say', 'commands'],
};

/// Resolve a spoken transcript to a [VoiceIntent]. Whitespace +
/// punctuation are normalized; matching is case-insensitive substring.
/// Returns `unknown` for empty / unmatched input — callers should
/// branch on [VoiceIntent.isUnknown] to render the fallback snackbar.
VoiceIntent resolveVoiceIntent(String transcript) {
  final original = transcript;
  final t = transcript.toLowerCase().trim();
  if (t.isEmpty) {
    return VoiceIntent(command: BookCommand.unknown, originalTranscript: original);
  }

  // "page 42" / "go to page 12" / "jump to page 5" — extract the
  // number BEFORE the keyword sweep so "page back" doesn't get caught
  // as jumpToPage.
  final jumpMatch =
      RegExp(r'\b(?:page|p\.?|go to|jump to|open page)\s*(\d{1,4})\b').firstMatch(t);
  if (jumpMatch != null && !t.contains('back')) {
    final n = int.tryParse(jumpMatch.group(1)!);
    if (n != null && n > 0) {
      return VoiceIntent(
        command: BookCommand.jumpToPage,
        originalTranscript: original,
        pageNumber: n,
      );
    }
  }

  for (final entry in _keywords.entries) {
    for (final phrase in entry.value) {
      if (t.contains(phrase)) {
        return VoiceIntent(
          command: entry.key,
          originalTranscript: original,
        );
      }
    }
  }
  return VoiceIntent(command: BookCommand.unknown, originalTranscript: original);
}

/// Riverpod-exposed for parity with Sahulat's voiceIntentServiceProvider.
/// Stateless function exposed as a Provider so call sites can swap in a
/// fake during widget tests without monkey-patching the top-level.
final localVoiceIntentResolverProvider =
    Provider<VoiceIntent Function(String)>((ref) => resolveVoiceIntent);
