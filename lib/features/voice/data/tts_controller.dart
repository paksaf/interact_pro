import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';

/// Each voice on the device — `name` is the human-friendly identifier the
/// platform uses, `locale` is the BCP-47 language tag the voice was built
/// for. `flutter_tts.setVoice({name, locale})` consumes both.
class TtsVoice {
  const TtsVoice({required this.name, required this.locale});
  final String name;
  final String locale;

  Map<String, String> toMap() => {'name': name, 'locale': locale};

  @override
  String toString() => '$name ($locale)';
}

final ttsControllerProvider = Provider<TtsController>((ref) {
  final ctrl = TtsController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

class TtsState {
  const TtsState({
    this.isSpeaking = false,
    this.language = 'en-US',
    this.rate = 0.5,
    this.voiceName,
    this.voiceLocale,
  });
  final bool isSpeaking;
  final String language;
  final double rate;
  final String? voiceName;
  final String? voiceLocale;

  TtsState copyWith({
    bool? isSpeaking,
    String? language,
    double? rate,
    String? voiceName,
    String? voiceLocale,
    bool clearVoice = false,
  }) =>
      TtsState(
        isSpeaking: isSpeaking ?? this.isSpeaking,
        language: language ?? this.language,
        rate: rate ?? this.rate,
        voiceName: clearVoice ? null : (voiceName ?? this.voiceName),
        voiceLocale: clearVoice ? null : (voiceLocale ?? this.voiceLocale),
      );
}

final ttsStateProvider =
    StateNotifierProvider<TtsStateNotifier, TtsState>((ref) {
  return TtsStateNotifier(ref);
});

class TtsStateNotifier extends StateNotifier<TtsState> {
  TtsStateNotifier(this._ref) : super(const TtsState()) {
    final ctrl = _ref.read(ttsControllerProvider);
    ctrl.onStart = () => state = state.copyWith(isSpeaking: true);
    ctrl.onComplete = () => state = state.copyWith(isSpeaking: false);
    ctrl.onCancel = () => state = state.copyWith(isSpeaking: false);
    // Hydrate from persisted prefs on startup so the user's last choice
    // of language/voice/rate carries across app restarts.
    _loadPrefs();
  }
  final Ref _ref;

  static const _kLang = 'tts.language';
  static const _kRate = 'tts.rate';
  static const _kVoiceName = 'tts.voice_name';
  static const _kVoiceLocale = 'tts.voice_locale';

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = state.copyWith(
        language: prefs.getString(_kLang) ?? state.language,
        rate: prefs.getDouble(_kRate) ?? state.rate,
        voiceName: prefs.getString(_kVoiceName),
        voiceLocale: prefs.getString(_kVoiceLocale),
      );
    } catch (e) {
      appLogger.w('TTS prefs load failed: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLang, state.language);
      await prefs.setDouble(_kRate, state.rate);
      if (state.voiceName != null) {
        await prefs.setString(_kVoiceName, state.voiceName!);
      } else {
        await prefs.remove(_kVoiceName);
      }
      if (state.voiceLocale != null) {
        await prefs.setString(_kVoiceLocale, state.voiceLocale!);
      } else {
        await prefs.remove(_kVoiceLocale);
      }
    } catch (e) {
      appLogger.w('TTS prefs save failed: $e');
    }
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final ctrl = _ref.read(ttsControllerProvider);
    await ctrl.speak(
      text,
      language: state.language,
      rate: state.rate,
      voice: state.voiceName != null && state.voiceLocale != null
          ? TtsVoice(name: state.voiceName!, locale: state.voiceLocale!)
          : null,
    );
  }

  Future<void> stop() => _ref.read(ttsControllerProvider).stop();

  Future<void> setLanguage(String code) async {
    state = state.copyWith(language: code);
    // Changing language clears voice — voices are tied to a specific locale,
    // so a previously chosen voice for, say, en-US is meaningless once we
    // switch to ur-PK. The user picks a fresh voice next.
    state = state.copyWith(clearVoice: true);
    await _save();
  }

  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    await _save();
  }

  Future<void> setVoice(TtsVoice voice) async {
    state = state.copyWith(
      voiceName: voice.name,
      voiceLocale: voice.locale,
      // Keep state.language in sync with the voice's locale so subsequent
      // `speak()` calls hit the right pronunciation.
      language: voice.locale,
    );
    await _save();
  }
}

/// Wraps flutter_tts. Note: Urdu (ur-PK) requires a TTS voice pack on the
/// device — Google's TTS engine ships it on most Android phones but not all.
class TtsController {
  TtsController() {
    _tts.setStartHandler(() => onStart?.call());
    _tts.setCompletionHandler(() => onComplete?.call());
    _tts.setCancelHandler(() => onCancel?.call());
    _tts.setErrorHandler((msg) => onError?.call(msg.toString()));
  }

  final FlutterTts _tts = FlutterTts();

  void Function()? onStart;
  void Function()? onComplete;
  void Function()? onCancel;
  void Function(String message)? onError;

  Future<List<String>> availableLanguages() async {
    final langs = await _tts.getLanguages;
    return (langs as List<dynamic>).cast<String>();
  }

  /// Voices available on the device, optionally filtered to a locale.
  /// flutter_tts returns a list of maps with `name` and `locale` keys.
  Future<List<TtsVoice>> availableVoices({String? localeFilter}) async {
    try {
      final raw = await _tts.getVoices;
      final list = (raw as List<dynamic>).cast<Map<dynamic, dynamic>>();
      final voices = list
          .map((m) => TtsVoice(
                name: (m['name'] ?? '').toString(),
                locale: (m['locale'] ?? '').toString(),
              ),)
          .where((v) => v.name.isNotEmpty && v.locale.isNotEmpty)
          .toList();
      if (localeFilter == null) return voices;
      // Match by primary subtag too — `en` should match `en-US`, `en-GB`.
      final primary = localeFilter.split('-').first.toLowerCase();
      return voices.where((v) {
        final vp = v.locale.split('-').first.toLowerCase();
        return v.locale == localeFilter || vp == primary;
      }).toList();
    } catch (e) {
      appLogger.w('availableVoices failed: $e');
      return const [];
    }
  }

  Future<void> speak(
    String text, {
    required String language,
    required double rate,
    TtsVoice? voice,
  }) async {
    await _tts.setLanguage(language);
    await _tts.setSpeechRate(rate);
    await _tts.setVolume(1.0);
    if (voice != null) {
      try {
        await _tts.setVoice(voice.toMap());
      } catch (e) {
        // Voice may not be available (e.g. user upgraded OS, voice pack
        // gone) — fall back to language default rather than failing.
        appLogger.w('setVoice failed: $e — falling back to language default');
      }
    }
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
  Future<void> pause() => _tts.pause();

  Future<void> dispose() => _tts.stop();
}
