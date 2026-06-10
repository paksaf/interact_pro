import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

final sttControllerProvider = Provider<SttController>((ref) {
  final c = SttController();
  ref.onDispose(c.dispose);
  return c;
});

class SttState {
  const SttState({
    this.isListening = false,
    this.partial = '',
    this.finalText = '',
    this.error,
  });
  final bool isListening;
  final String partial;
  final String finalText;
  final String? error;

  SttState copyWith({bool? isListening, String? partial, String? finalText, String? error}) =>
      SttState(
        isListening: isListening ?? this.isListening,
        partial: partial ?? this.partial,
        finalText: finalText ?? this.finalText,
        error: error,
      );
}

final sttStateProvider =
    StateNotifierProvider<SttStateNotifier, SttState>((ref) {
  return SttStateNotifier(ref.read(sttControllerProvider));
});

class SttStateNotifier extends StateNotifier<SttState> {
  SttStateNotifier(this._ctrl) : super(const SttState());
  final SttController _ctrl;

  Future<void> start({String localeId = 'en_US'}) async {
    if (state.isListening) return;
    final ok = await _ctrl.initialize();
    if (!ok) {
      state = state.copyWith(error: 'Speech recognition unavailable');
      return;
    }
    state = const SttState(isListening: true);
    await _ctrl.listen(
      localeId: localeId,
      onPartial: (text) => state = state.copyWith(partial: text),
      onFinal: (text) => state = state.copyWith(
        isListening: false,
        partial: '',
        finalText: text,
      ),
    );
  }

  Future<void> stop() async {
    await _ctrl.stop();
    state = state.copyWith(isListening: false);
  }
}

class SttController {
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _initialized = false;

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize(
      onError: (_) {},
      onStatus: (_) {},
    );
    return _initialized;
  }

  Future<void> listen({
    required String localeId,
    required void Function(String partial) onPartial,
    required void Function(String finalText) onFinal,
  }) async {
    await _stt.listen(
      localeId: localeId,
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
      onResult: (SpeechRecognitionResult r) {
        if (r.finalResult) {
          onFinal(r.recognizedWords);
        } else {
          onPartial(r.recognizedWords);
        }
      },
    );
  }

  Future<void> stop() => _stt.stop();
  Future<void> dispose() async => _stt.cancel();
}
