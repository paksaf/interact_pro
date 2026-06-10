// SPDX-License-Identifier: AGPL-3.0
//
// TtsService — engine-agnostic facade for text-to-speech across:
//
//   • SystemTtsService — wraps flutter_tts, uses the device's installed
//     TTS engine. Free, offline, voice quality depends on what the user
//     has installed (Google TTS, RH Voice for Urdu, eSpeak, etc).
//   • PiperTtsService — calls the Phase 1.5 backend at /api/tts/speak,
//     downloads WAV bytes, plays via audioplayers. Quality ranges from
//     "natural" (en_US-amy-medium) to "OK for prose" (community ur_PK).
//     Requires INTERACT_PRO_AI_SECRET to be baked into the build.
//
// The BookViewer's speaker button reads `activeTtsServiceProvider` and
// asks the resolved engine to speak the current page. Default is
// SystemTts (works on every device with zero config); users opt in to
// Piper via Settings → Read aloud.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';

/// Karaoke progress snapshot — emitted by [TtsService.progressNotifier]
/// as playback moves through the text. UI uses this to highlight the
/// current word in a footer strip (BookViewer "now reading" chip).
///
/// `words` is the tokenised input — pre-split by the service so the UI
/// doesn't have to re-do the regex. `currentWordIndex` is 0-based; -1
/// means "not started yet" and `words.length` means "finished".
@immutable
class TtsProgress {
  const TtsProgress({
    required this.words,
    required this.currentWordIndex,
  });

  final List<String> words;
  final int currentWordIndex;

  bool get isActive =>
      currentWordIndex >= 0 && currentWordIndex < words.length;

  static const TtsProgress idle = TtsProgress(words: [], currentWordIndex: -1);
}

/// Tokenise text into words for karaoke highlighting. Splits on
/// whitespace, keeps punctuation attached to the trailing word so the
/// highlight visually matches what you read ("hello," not "hello").
List<String> _tokeniseWords(String text) {
  final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return const [];
  return cleaned.split(' ');
}

/// For each word in [words], find its starting char offset in the
/// original [text]. Used by SystemTtsService.setProgressHandler to
/// translate the engine's char position back to a word index. Returns
/// a list parallel to [words]; result[i] is the index in [text] where
/// word i begins.
List<int> _computeWordStarts(String text, List<String> words) {
  final starts = <int>[];
  var cursor = 0;
  for (final w in words) {
    final idx = text.indexOf(w, cursor);
    if (idx < 0) {
      // Word not found verbatim (e.g., engine collapsed whitespace) —
      // fall back to current cursor. Better than throwing and aborts
      // gracefully: the highlight may drift a word but playback works.
      starts.add(cursor);
    } else {
      starts.add(idx);
      cursor = idx + w.length;
    }
  }
  return starts;
}

/// Pre-process text for TTS playback (#250 — 2026-05-20 bug batch):
///  - Insert a sentence break after `.` `?` `;` so the engine actually
///    pauses. Most engines pause on punctuation already, but Piper and
///    espeak-NG don't unless we feed them a hard token like `,` (≈300ms)
///    or doubled-newlines.
///  - Drop standalone punctuation tokens (`*`, `_`, `~`, leading/trailing
///    quotes/parens) that some engines read aloud as words ("asterisk",
///    "underscore").
///  - Expand digit runs into spelled-out numbers so "2026" reads as
///    "two thousand twenty-six" instead of "two zero two six". English
///    only at this layer; Urdu/PK locales rely on the device engine's
///    built-in normalization, which is reliable on Google TTS.
///  - Replace a small set of well-known emoji + onomatopoeia with their
///    spoken form (smile, wow, etc.) when the engine doesn't have an
///    expressive prosody hook. Unicode emojis NOT in the map get
///    stripped silently (better than the engine reading "U+1F600").
///
/// Returns the cleaned text. Tokenisation for karaoke runs AFTER this,
/// so the highlighted words match what the engine actually spoke.
String preprocessForTts(String text, {String? langHint}) {
  if (text.isEmpty) return text;

  var t = text;

  // 1. Strip the no-speak punctuation that ends up read aloud.
  t = t.replaceAll(RegExp(r'[*_~`]+'), ' ');
  // Repeated dots/dashes → single one so we don't get a 3-second pause
  // on every Markdown horizontal rule.
  t = t.replaceAll(RegExp(r'\.{3,}'), '. ');
  t = t.replaceAll(RegExp(r'-{2,}'), ' — ');

  // 2. Sentence pauses. We use a comma + space because every TTS engine
  // we ship (flutter_tts, Piper, espeak-NG) pauses on commas. SSML
  // <break time="800ms"/> would be cleaner but Piper strips SSML and
  // flutter_tts's SSML support varies by underlying engine.
  t = t.replaceAllMapped(
    RegExp(r'([.?;!])(\s+|$)'),
    (m) => '${m[1]}, ${m[2]}',
  );

  // 3. Number expansion (English only — Urdu engines normalize digits).
  final isEnglish = (langHint ?? 'en').toLowerCase().startsWith('en');
  if (isEnglish) {
    t = t.replaceAllMapped(RegExp(r'\b\d{1,9}\b'), (m) {
      final n = int.tryParse(m[0]!);
      if (n == null) return m[0]!;
      return _numberToWordsEn(n);
    });
  }

  // 4. Emoji + onomatopoeia. Map known forms to spoken text.
  const knownEmoji = <String, String>{
    '😀': 'smile', '😁': 'grin', '😂': 'laughing', '😍': 'love',
    '😢': 'sad', '😭': 'crying', '😡': 'angry', '😱': 'shocked',
    '👍': 'thumbs up', '👎': 'thumbs down', '❤': 'heart', '❤️': 'heart',
    '🔥': 'fire', '✨': 'sparkles', '🎉': 'celebration', '⚠': 'warning',
    '⚠️': 'warning',
  };
  knownEmoji.forEach((emoji, word) {
    t = t.replaceAll(emoji, ' $word, ');
  });
  // Strip any leftover emoji-range characters. The U+1F300–U+1FAFF
  // pictographic plane covers almost everything not in the map above.
  t = t.replaceAll(
    RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true),
    ' ',
  );

  // 5. Collapse whitespace introduced by the substitutions.
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t;
}

/// Compact English number-to-words. Handles 0..999_999_999 which
/// covers every page-number + chapter-number + year we'd ever see.
/// Above that, falls back to the raw digits (the engine can take it).
String _numberToWordsEn(int n) {
  if (n < 0) return 'minus ${_numberToWordsEn(-n)}';
  if (n == 0) return 'zero';
  const ones = [
    '', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
    'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
    'sixteen', 'seventeen', 'eighteen', 'nineteen',
  ];
  const tens = [
    '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy',
    'eighty', 'ninety',
  ];
  String chunk(int x) {
    if (x == 0) return '';
    if (x < 20) return ones[x];
    if (x < 100) {
      final t = tens[x ~/ 10];
      final r = x % 10;
      return r == 0 ? t : '$t-${ones[r]}';
    }
    final h = ones[x ~/ 100];
    final r = x % 100;
    return r == 0 ? '$h hundred' : '$h hundred ${chunk(r)}';
  }
  if (n < 1000) return chunk(n);
  if (n < 1000000) {
    final thousands = chunk(n ~/ 1000);
    final r = n % 1000;
    return r == 0 ? '$thousands thousand' : '$thousands thousand ${chunk(r)}';
  }
  // Million range
  final millions = chunk(n ~/ 1000000);
  final remainder = n % 1000000;
  if (remainder == 0) return '$millions million';
  return '$millions million ${_numberToWordsEn(remainder)}';
}

/// Which TTS engine to use. Persisted to prefs as a string.
///
/// system  — flutter_tts, uses installed OS engines. Offline.
/// piper   — Piper (cloud). Multi-lingual (EN/RU/TR/AR), natural.
/// kokoro  — Kokoro-82M (cloud). English-only, best free quality.
/// espeak  — eSpeak-NG (cloud). All languages, robotic but works.
enum TtsEngine { system, piper, kokoro, espeak }

/// One voice option surfaced to the picker UI. For system, the [id] is
/// `name|locale` (matching flutter_tts's setVoice schema). For Piper
/// it's the catalog voice id (e.g., 'en_US-amy-medium').
@immutable
class TtsVoiceOption {
  const TtsVoiceOption({
    required this.id,
    required this.label,
    required this.locale,
    this.description,
    this.available = true,
  });
  final String id;
  final String label;
  final String locale;
  final String? description;

  /// For Piper voices, false means the .onnx isn't on the server yet
  /// (run install.sh on the VPS to fetch). UI greys these out.
  final bool available;
}

/// User-controllable TTS preferences. Persisted under `tts.*` keys.
@immutable
class TtsSettings {
  const TtsSettings({
    required this.engine,
    required this.voiceId,
    required this.rate,
    required this.autoDetectLanguage,
    required this.highlightSpokenWords,
  });

  final TtsEngine engine;
  final String? voiceId;
  final double rate;

  /// When true, the BookViewer's TTS button passes the Surya-detected
  /// language hint into the active TtsService. Each service then picks
  /// the most appropriate voice for that language WITHOUT overwriting
  /// the user's saved [voiceId] preference. Default true — saves users
  /// from having to manually pick a Russian voice for a Russian PDF.
  final bool autoDetectLanguage;

  /// Karaoke mode — when true the active TtsService emits per-word
  /// progress events and the BookViewer renders a footer chip
  /// highlighting the current word. Default true. SystemTts uses
  /// native word-boundary callbacks; Remote engines estimate by
  /// playback position / total duration.
  final bool highlightSpokenWords;

  static const TtsSettings defaults = TtsSettings(
    engine: TtsEngine.system,
    voiceId: null,
    rate: 0.45,
    autoDetectLanguage: true,
    highlightSpokenWords: true,
  );

  TtsSettings copyWith({
    TtsEngine? engine,
    String? voiceId,
    double? rate,
    bool? autoDetectLanguage,
    bool? highlightSpokenWords,
  }) =>
      TtsSettings(
        engine: engine ?? this.engine,
        voiceId: voiceId ?? this.voiceId,
        rate: rate ?? this.rate,
        autoDetectLanguage: autoDetectLanguage ?? this.autoDetectLanguage,
        highlightSpokenWords:
            highlightSpokenWords ?? this.highlightSpokenWords,
      );

  Future<void> save(SharedPreferences p) async {
    await p.setString('tts.engine', engine.name);
    if (voiceId == null) {
      await p.remove('tts.voice');
    } else {
      await p.setString('tts.voice', voiceId!);
    }
    await p.setDouble('tts.rate', rate);
    await p.setBool('tts.autoDetect', autoDetectLanguage);
    await p.setBool('tts.highlight', highlightSpokenWords);
  }

  static TtsSettings load(SharedPreferences p) {
    final raw = p.getString('tts.engine');
    final engine = TtsEngine.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => TtsEngine.system,
    );
    return TtsSettings(
      engine: engine,
      voiceId: p.getString('tts.voice'),
      rate: p.getDouble('tts.rate') ?? 0.45,
      autoDetectLanguage: p.getBool('tts.autoDetect') ?? true,
      highlightSpokenWords: p.getBool('tts.highlight') ?? true,
    );
  }
}

abstract class TtsService {
  Future<void> speak(String text, {String? langHint});
  Future<void> stop();
  Future<List<TtsVoiceOption>> listVoices();
  bool get isPlaying;
  Listenable get playingListenable;

  /// Karaoke progress — current word index as playback advances.
  /// Emits [TtsProgress.idle] when not playing. UI subscribes and
  /// re-renders the "now reading" footer chip on each tick.
  ValueListenable<TtsProgress> get progressNotifier;
}

class SystemTtsService extends ChangeNotifier implements TtsService {
  SystemTtsService() {
    // Fire-and-forget engine wiring. These three calls are documented
    // requirements for setProgressHandler to actually emit per-word
    // events:
    //
    //   • awaitSpeakCompletion(true) — without this, flutter_tts on
    //     iOS returns from `speak()` immediately and discards the
    //     progress stream. Karaoke never advances.
    //   • setSharedInstance(true) — iOS only; shares the AVAudio
    //     session so our handler isn't muted by background-audio
    //     priority rules. Throws on Android — try/catch silently.
    //   • setQueueMode(0) — Android only; "QUEUE_FLUSH" so repeat
    //     speak() calls replace the prior utterance instead of
    //     queueing (otherwise the second tap doesn't restart).
    //
    // All three are idempotent — safe to call before every speak()
    // too, but doing them once in the ctor avoids the per-call cost.
    _initEngine();
    _tts.setCompletionHandler(() {
      _isPlaying = false;
      _progress.value = TtsProgress.idle;
      notifyListeners();
    });
    _tts.setCancelHandler(() {
      _isPlaying = false;
      _progress.value = TtsProgress.idle;
      notifyListeners();
    });
    // Per-word progress on supported engines (Android Google TTS, iOS
    // AVSpeechSynthesizer). [start] / [end] are character offsets into
    // the text we passed to speak(); [word] is the spoken token.
    // Some engines emit charactersWord and one progress event per word;
    // others emit per-character — collapse to word index by tracking
    // which word the [start] offset falls into.
    _tts.setProgressHandler((text, start, end, word) {
      if (_words.isEmpty) return;
      // start/end are UTF-16 indices into the original text. We
      // pre-computed each word's starting char offset in _wordStarts.
      // Use upper_bound - 1 to find which word contains [start].
      var lo = 0;
      var hi = _wordStarts.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (_wordStarts[mid] <= start) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      _progress.value = TtsProgress(words: _words, currentWordIndex: lo);
    });
  }

  final FlutterTts _tts = FlutterTts();
  bool _isPlaying = false;
  TtsSettings? _settings;
  final ValueNotifier<TtsProgress> _progress =
      ValueNotifier<TtsProgress>(TtsProgress.idle);
  List<String> _words = const [];
  List<int> _wordStarts = const [];

  Future<void> _initEngine() async {
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {/* unlikely; safe to ignore */}
    if (Platform.isIOS) {
      try {
        await _tts.setSharedInstance(true);
      } catch (_) {/* iOS only */}
    }
    if (Platform.isAndroid) {
      try {
        await _tts.setQueueMode(0); // QUEUE_FLUSH
      } catch (_) {/* method added in flutter_tts 4.x — older = no-op */}
    }
  }

  @override
  bool get isPlaying => _isPlaying;
  @override
  Listenable get playingListenable => this;
  @override
  ValueListenable<TtsProgress> get progressNotifier => _progress;

  void applySettings(TtsSettings s) => _settings = s;

  @override
  Future<void> speak(String text, {String? langHint}) async {
    final s = _settings ?? TtsSettings.defaults;
    await _tts.setSpeechRate(s.rate);
    // When auto-detect is on AND we got a language hint from OCR,
    // tell the device's TTS engine to switch to that locale BEFORE
    // we set a specific voice. flutter_tts will pick a sensible
    // installed voice for that locale if the saved voiceId doesn't
    // belong to it.
    final useDetected = s.autoDetectLanguage && langHint != null;
    if (useDetected) {
      try {
        await _tts.setLanguage(langHint);
      } catch (_) {/* device may not have this locale installed */}
    } else if (s.voiceId != null && s.voiceId!.contains('|')) {
      final parts = s.voiceId!.split('|');
      await _tts.setVoice({'name': parts[0], 'locale': parts[1]});
    }
    // Preprocess text: punctuation pauses, drop no-speak symbols,
    // expand numbers, normalise emoji. See preprocessForTts docs.
    final spoken = preprocessForTts(text, langHint: langHint);
    // Pre-tokenise for karaoke. We compute each word's starting char
    // index in the original string so setProgressHandler can map the
    // engine's char-offset back to a word index in O(log n).
    if (s.highlightSpokenWords) {
      _words = _tokeniseWords(spoken);
      _wordStarts = _computeWordStarts(spoken, _words);
      _progress.value = TtsProgress(words: _words, currentWordIndex: -1);
    } else {
      _words = const [];
      _wordStarts = const [];
      _progress.value = TtsProgress.idle;
    }
    _isPlaying = true;
    notifyListeners();
    await _tts.speak(spoken);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    _isPlaying = false;
    _progress.value = TtsProgress.idle;
    notifyListeners();
  }

  @override
  Future<List<TtsVoiceOption>> listVoices() async {
    try {
      final voices = await _tts.getVoices;
      if (voices is! List) return const [];
      return voices.whereType<Map>().map((m) {
        final name = (m['name'] ?? '').toString();
        final locale = (m['locale'] ?? '').toString();
        return TtsVoiceOption(
          id: '$name|$locale',
          label: name.isEmpty ? locale : '$name ($locale)',
          locale: locale,
        );
      }).toList();
    } catch (e) {
      appLogger.w('SystemTts.listVoices failed', error: e);
      return const [];
    }
  }
}

/// Server-backed engine — Piper / Kokoro / eSpeak share the same
/// /api/tts/{voices,speak} contract; only the `engine` form field
/// differs. One instance per [TtsEngine] keeps caches & player
/// independent so switching engines doesn't reset playback state.
class RemoteTtsService extends ChangeNotifier implements TtsService {
  RemoteTtsService(this.engineName, {http.Client? client, AudioPlayer? player})
      : _client = client ?? http.Client(),
        _player = player ?? AudioPlayer() {
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      final wasPlaying = _isPlaying;
      _isPlaying = state == PlayerState.playing;
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        _progress.value = TtsProgress.idle;
      }
      if (wasPlaying != _isPlaying) notifyListeners();
    });
    // Cache duration when the audio loads — we need it to estimate the
    // current word index from the elapsed position. Without duration,
    // karaoke falls back to "no highlight" but playback still works.
    _durSub = _player.onDurationChanged.listen((d) => _totalDuration = d);
    // Per-position events drive the karaoke index. audioplayers emits
    // these ~10×/sec on Android, fine for word-granularity highlighting
    // (typical English at 150 WPM = ~2.5 words/sec).
    _posSub = _player.onPositionChanged.listen(_onPosition);
  }

  /// "piper" / "kokoro" / "espeak" — sent as the `engine` form field
  /// in /api/tts/speak.
  final String engineName;

  final http.Client _client;
  final AudioPlayer _player;
  late final StreamSubscription _stateSub;
  late final StreamSubscription _durSub;
  late final StreamSubscription _posSub;
  bool _isPlaying = false;
  TtsSettings? _settings;
  final ValueNotifier<TtsProgress> _progress =
      ValueNotifier<TtsProgress>(TtsProgress.idle);
  List<String> _words = const [];
  Duration _totalDuration = Duration.zero;
  bool _highlightOn = false;

  /// Previously-played temp file. Deleted at the start of the next
  /// `speak()` so the cache doesn't bloat across many utterances.
  File? _lastTempFile;

  @override
  bool get isPlaying => _isPlaying;
  @override
  Listenable get playingListenable => this;
  @override
  ValueListenable<TtsProgress> get progressNotifier => _progress;

  void applySettings(TtsSettings s) => _settings = s;

  /// Linear-estimate the current word from playback position. Engines
  /// like Piper/Kokoro don't expose word-boundary callbacks — we assume
  /// uniform speech rate across the utterance. Good enough for visual
  /// feedback; off by a word here and there on long sentences.
  void _onPosition(Duration pos) {
    if (!_highlightOn || _words.isEmpty) return;
    final totalMs = _totalDuration.inMilliseconds;
    if (totalMs <= 0) return;
    final fraction = pos.inMilliseconds / totalMs;
    final idx = (fraction * _words.length).floor().clamp(0, _words.length - 1);
    final current = _progress.value;
    if (current.currentWordIndex != idx) {
      _progress.value = TtsProgress(words: _words, currentWordIndex: idx);
    }
  }

  @override
  Future<void> speak(String text, {String? langHint}) async {
    if (!AppConstants.aiBackendConfigured) {
      throw StateError(
        '$engineName TTS needs INTERACT_PRO_AI_SECRET baked at build time.',
      );
    }
    final s = _settings ?? TtsSettings.defaults;
    // Apply the same prosody preprocessor used by SystemTtsService —
    // sentence pauses, number expansion, emoji normalisation. Piper +
    // Kokoro especially benefit because they don't do text
    // normalisation on the server side. See preprocessForTts docs.
    final spoken = preprocessForTts(text, langHint: langHint);
    final uri = Uri.parse('${AppConstants.aiBackendBaseUrl}/api/tts/speak');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${AppConstants.aiBackendSecret}'
      ..fields['text'] = spoken
      ..fields['engine'] = engineName
      ..fields['rate'] = s.rate.toStringAsFixed(2);
    // Auto-detect mode: pass the OCR-detected language and SKIP the
    // saved voice id. Server picks the first available voice in that
    // locale (e.g., Russian text → first Russian voice for this
    // engine). When auto-detect is OFF, the saved voice wins.
    final useDetected = s.autoDetectLanguage && langHint != null;
    if (useDetected) {
      req.fields['lang'] = langHint;
    } else if (s.voiceId != null) {
      req.fields['voice'] = s.voiceId!;
    }

    final streamed =
        await _client.send(req).timeout(const Duration(seconds: 60));
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw Exception('$engineName /speak ${streamed.statusCode}: $body');
    }
    final bytes = await streamed.stream.toBytes();
    appLogger.i('$engineName TTS: ${bytes.length} bytes, '
        'voice=${streamed.headers['x-voice-id'] ?? "?"}',);

    // Prime karaoke state BEFORE play() so the first position-change
    // event has the word list to look up. Pre-parse the WAV header for
    // duration as a fallback — audioplayers' BytesSource often never
    // emits onDurationChanged, leaving _totalDuration at 0 and the
    // karaoke index frozen at word 0. The header parse below is
    // deterministic; onDurationChanged later overwrites if the
    // platform does emit.
    _highlightOn = s.highlightSpokenWords;
    if (_highlightOn) {
      // Tokenise the PREPROCESSED text — that's what the engine spoke,
      // so karaoke indices align with audio position. Tokenising the
      // raw input would highlight words that were never vocalised.
      _words = _tokeniseWords(spoken);
      _totalDuration = _parseWavDuration(bytes) ?? Duration.zero;
      _progress.value = TtsProgress(words: _words, currentWordIndex: -1);
    } else {
      _words = const [];
      _progress.value = TtsProgress.idle;
    }

    // Switch from BytesSource → DeviceFileSource. BytesSource on
    // audioplayers 5.x doesn't reliably probe duration on Android
    // and is silently broken on web. Writing the WAV to the temp
    // dir adds one fs.write per utterance (~10ms for ~200KB) but
    // unlocks reliable seek/duration/position events that karaoke
    // depends on.
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File(
      '${tmpDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await tmpFile.writeAsBytes(bytes);
    // Best-effort delete of the previous utterance's file. We don't
    // wait for it — if it fails (locked, already deleted), the OS
    // will reap the temp dir eventually.
    final prev = _lastTempFile;
    if (prev != null) {
      // ignore: discarded_futures
      prev.delete().catchError((_) => prev);
    }
    _lastTempFile = tmpFile;
    await _player.play(DeviceFileSource(tmpFile.path));
  }

  /// Parses RIFF/WAVE header bytes to extract duration. Returns null
  /// for any non-WAV or malformed payload (caller falls back to
  /// onDurationChanged, which may or may not fire).
  ///
  /// Layout reference (canonical 44-byte PCM header):
  ///   bytes  0– 3 = "RIFF"
  ///   bytes  8–11 = "WAVE"
  ///   bytes 24–27 = sample rate (LE u32)
  ///   bytes 28–31 = byte rate   (LE u32, = sampleRate * channels * bytesPerSample)
  ///   bytes 40–43 = data chunk size (LE u32)
  /// duration_seconds = data_size / byte_rate
  Duration? _parseWavDuration(Uint8List bytes) {
    if (bytes.length < 44) return null;
    if (bytes[0] != 0x52 || bytes[1] != 0x49 ||
        bytes[2] != 0x46 || bytes[3] != 0x46) return null; // "RIFF"
    if (bytes[8] != 0x57 || bytes[9] != 0x41 ||
        bytes[10] != 0x56 || bytes[11] != 0x45) return null; // "WAVE"
    try {
      final bd = ByteData.sublistView(bytes, 0, 44);
      final byteRate = bd.getUint32(28, Endian.little);
      final dataSize = bd.getUint32(40, Endian.little);
      if (byteRate == 0) return null;
      final ms = (dataSize / byteRate * 1000).round();
      return Duration(milliseconds: ms);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
    _progress.value = TtsProgress.idle;
    notifyListeners();
  }

  /// Lists voices for THIS engine only, by filtering the unified
  /// /api/tts/voices catalog server-side returns.
  @override
  Future<List<TtsVoiceOption>> listVoices() async {
    if (!AppConstants.aiBackendConfigured) return const [];
    try {
      final resp = await _client.get(
        Uri.parse('${AppConstants.aiBackendBaseUrl}/api/tts/voices'),
        headers: {'Authorization': 'Bearer ${AppConstants.aiBackendSecret}'},
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (j['voices'] as List?) ?? const [];
      return list
          .whereType<Map>()
          .where((m) => m['engine'] == engineName)
          .map((m) => TtsVoiceOption(
                id: m['id'] as String? ?? '',
                label: m['label'] as String? ?? m['id'] as String? ?? '?',
                locale: m['locale'] as String? ?? '',
                description: m['description'] as String?,
                available: m['available'] == true,
              ),)
          .toList();
    } catch (e) {
      appLogger.w('$engineName.listVoices failed', error: e);
      return const [];
    }
  }

  @override
  void dispose() {
    _stateSub.cancel();
    _durSub.cancel();
    _posSub.cancel();
    _progress.dispose();
    _player.dispose();
    _client.close();
    super.dispose();
  }
}

/// Backwards-compat alias — existing code that referenced PiperTtsService.
typedef PiperTtsService = RemoteTtsService;

final ttsSettingsProvider = FutureProvider<TtsSettings>((ref) async {
  final p = await SharedPreferences.getInstance();
  return TtsSettings.load(p);
});

final systemTtsProvider = Provider<SystemTtsService>((ref) {
  final s = SystemTtsService();
  ref.onDispose(s.dispose);
  return s;
});

final piperTtsProvider = Provider<RemoteTtsService>((ref) {
  final s = RemoteTtsService('piper');
  ref.onDispose(s.dispose);
  return s;
});

final kokoroTtsProvider = Provider<RemoteTtsService>((ref) {
  final s = RemoteTtsService('kokoro');
  ref.onDispose(s.dispose);
  return s;
});

final espeakTtsProvider = Provider<RemoteTtsService>((ref) {
  final s = RemoteTtsService('espeak');
  ref.onDispose(s.dispose);
  return s;
});

/// Returns the currently-active TtsService with settings applied.
/// Use from the BookViewer's speaker button.
final activeTtsServiceProvider = FutureProvider<TtsService>((ref) async {
  final settings = await ref.watch(ttsSettingsProvider.future);
  switch (settings.engine) {
    case TtsEngine.system:
      final svc = ref.read(systemTtsProvider);
      svc.applySettings(settings);
      return svc;
    case TtsEngine.piper:
      final svc = ref.read(piperTtsProvider);
      svc.applySettings(settings);
      return svc;
    case TtsEngine.kokoro:
      final svc = ref.read(kokoroTtsProvider);
      svc.applySettings(settings);
      return svc;
    case TtsEngine.espeak:
      final svc = ref.read(espeakTtsProvider);
      svc.applySettings(settings);
      return svc;
  }
});
