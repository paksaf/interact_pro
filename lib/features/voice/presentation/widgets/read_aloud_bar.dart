import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tts_controller.dart';

/// Bottom bar shown while the user is in "Read aloud" mode.
///
/// **Text source priority:**
///   1. [selectedText] (non-null = user has selected a region in the PDF)
///   2. [textForCurrentPage] (fallback: read the whole visible page)
///
/// The bar adapts its label so the user knows which one is being read.
///
/// Settings persist across app launches (see [TtsStateNotifier._loadPrefs]).
class ReadAloudBar extends ConsumerWidget {
  const ReadAloudBar({
    required this.textForCurrentPage,
    this.selectedText,
    super.key,
  });

  final String textForCurrentPage;
  final String? selectedText;

  String _resolveText() =>
      (selectedText != null && selectedText!.trim().isNotEmpty)
          ? selectedText!
          : textForCurrentPage;

  String _resolveLabel(TtsState state) {
    if (state.isSpeaking) return 'Speaking…';
    if (selectedText != null && selectedText!.trim().isNotEmpty) {
      return 'Read selection (${_truncate(selectedText!, 30)})';
    }
    return 'Read this page';
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max).trimRight()}…';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ttsStateProvider);
    final notifier = ref.read(ttsStateProvider.notifier);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: Icon(state.isSpeaking ? Icons.stop : Icons.play_arrow),
                    onPressed: () {
                      if (state.isSpeaking) {
                        notifier.stop();
                      } else {
                        final text = _resolveText();
                        if (text.trim().isEmpty) return;
                        notifier.speak(text);
                      }
                    },
                  ),
                  Expanded(
                    child: Text(
                      _resolveLabel(state),
                      style: Theme.of(context).textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune),
                    tooltip: 'Voice & settings',
                    onPressed: () => _showSettingsSheet(context, ref),
                  ),
                ],
              ),
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.speed, size: 18),
                  ),
                  Expanded(
                    child: Slider(
                      min: 0.2,
                      max: 1.0,
                      value: state.rate.clamp(0.2, 1.0),
                      label: state.rate.toStringAsFixed(2),
                      onChanged: (v) => notifier.setRate(v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Modal bottom sheet with language + voice pickers. Both lists are
  /// queried lazily from the device — Apple devices typically expose
  /// 30+ system voices, Android depends on which TTS engine is installed.
  void _showSettingsSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => const _TtsSettingsSheet(),
    );
  }
}

class _TtsSettingsSheet extends ConsumerStatefulWidget {
  const _TtsSettingsSheet();

  @override
  ConsumerState<_TtsSettingsSheet> createState() => _TtsSettingsSheetState();
}

class _TtsSettingsSheetState extends ConsumerState<_TtsSettingsSheet> {
  Future<List<String>>? _languages;
  Future<List<TtsVoice>>? _voices;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = ref.read(ttsStateProvider);
      final ctrl = ref.read(ttsControllerProvider);
      setState(() {
        _languages = ctrl.availableLanguages();
        _voices = ctrl.availableVoices(localeFilter: state.language);
      });
    });
  }

  void _refreshVoices(String locale) {
    final ctrl = ref.read(ttsControllerProvider);
    setState(() {
      _voices = ctrl.availableVoices(localeFilter: locale);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ttsStateProvider);
    final notifier = ref.read(ttsStateProvider.notifier);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionTitle('Language'),
            FutureBuilder<List<String>>(
              future: _languages,
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final langs = [...snap.data!]..sort();
                return DropdownButtonFormField<String>(
                  initialValue: langs.contains(state.language) ? state.language : null,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  isExpanded: true,
                  items: langs
                      .map((l) => DropdownMenuItem(
                            value: l,
                            child: Text(l),
                          ),)
                      .toList(),
                  onChanged: (l) async {
                    if (l == null) return;
                    await notifier.setLanguage(l);
                    _refreshVoices(l);
                  },
                );
              },
            ),
            const SizedBox(height: 16),
            const _SectionTitle('Voice'),
            FutureBuilder<List<TtsVoice>>(
              future: _voices,
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final voices = snap.data!;
                if (voices.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'No voices available for "${state.language}" on this device. '
                      'Install a voice pack in system Settings → Accessibility → '
                      'Spoken Content → Voices.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  );
                }
                final selected = voices.firstWhere(
                  (v) => v.name == state.voiceName &&
                      v.locale == state.voiceLocale,
                  orElse: () => voices.first,
                );
                return Column(
                  children: voices.map((v) {
                    return RadioListTile<TtsVoice>(
                      title: Text(v.name),
                      subtitle: Text(v.locale),
                      value: v,
                      groupValue: selected,
                      onChanged: (picked) {
                        if (picked != null) notifier.setVoice(picked);
                      },
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
