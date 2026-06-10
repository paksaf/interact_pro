// SPDX-License-Identifier: AGPL-3.0
//
// TtsSettingsScreen — Settings → Read aloud.
//
// Lets the user pick:
//   • Engine: System (flutter_tts, uses installed OS engines) or Piper
//     (cloud, runs on the Hetzner backend). Both are free; system is
//     offline + zero-config; Piper has better quality and curated
//     multi-lingual voices.
//   • Voice: filtered by engine. For System, the device's installed
//     voices. For Piper, the catalog from GET /api/tts/voices.
//   • Speech rate: 0.2 – 0.8 slider with a "Preview" button.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/app_constants.dart';
import '../../data/tts_service.dart';

class TtsSettingsScreen extends ConsumerStatefulWidget {
  const TtsSettingsScreen({super.key});

  @override
  ConsumerState<TtsSettingsScreen> createState() => _TtsSettingsScreenState();
}

class _TtsSettingsScreenState extends ConsumerState<TtsSettingsScreen> {
  TtsSettings? _draft;
  List<TtsVoiceOption> _voices = const [];
  bool _loadingVoices = false;

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  Future<void> _hydrate() async {
    final s = await ref.read(ttsSettingsProvider.future);
    if (!mounted) return;
    setState(() => _draft = s);
    await _refreshVoices(s.engine);
  }

  Future<void> _refreshVoices(TtsEngine engine) async {
    setState(() => _loadingVoices = true);
    final svc = _serviceFor(engine);
    final voices = await svc.listVoices();
    if (!mounted) return;
    setState(() {
      _voices = voices;
      _loadingVoices = false;
    });
  }

  /// Common engine-switch handler. Clears the picked voice (each
  /// engine has its own voice id namespace) and refreshes the voice
  /// list for the newly selected engine.
  Future<void> _onEngine(TtsEngine? v, TtsSettings d) async {
    if (v == null) return;
    setState(() => _draft = d.copyWith(engine: v, voiceId: null));
    await _refreshVoices(v);
  }

  TtsService _serviceFor(TtsEngine engine) {
    switch (engine) {
      case TtsEngine.system:
        return ref.read(systemTtsProvider);
      case TtsEngine.piper:
        return ref.read(piperTtsProvider);
      case TtsEngine.kokoro:
        return ref.read(kokoroTtsProvider);
      case TtsEngine.espeak:
        return ref.read(espeakTtsProvider);
    }
  }

  Future<void> _saveAndPop() async {
    if (_draft == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _draft!.save(prefs);
    ref.invalidate(ttsSettingsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _preview() async {
    if (_draft == null) return;
    final svc = _serviceFor(_draft!.engine);
    if (svc is SystemTtsService) svc.applySettings(_draft!);
    if (svc is RemoteTtsService) svc.applySettings(_draft!);
    try {
      await svc.speak(
        'This is a preview of the selected voice and speed.',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Preview failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft;
    if (d == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Read aloud'),
        actions: [
          TextButton.icon(
            onPressed: _saveAndPop,
            icon: const Icon(Icons.check),
            label: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Engine picker ────────────────────────────────────────
          const ListTile(
            title: Text('Engine'),
            subtitle: Text(
              'System uses voices already installed on this device. '
              'Piper streams premium voices from the Interact Pro AI '
              'backend (multi-lingual).',
            ),
          ),
          RadioListTile<TtsEngine>(
            title: const Text('System voice'),
            subtitle: const Text('Offline, works on any device.'),
            value: TtsEngine.system,
            groupValue: d.engine,
            onChanged: (v) => _onEngine(v, d),
          ),
          RadioListTile<TtsEngine>(
            title: const Text('Piper (cloud, multilingual)'),
            subtitle: Text(
              AppConstants.aiBackendConfigured
                  ? 'Natural voices — English, Russian, Turkish, Arabic.'
                  : 'Not configured in this build.',
              style: TextStyle(
                color: AppConstants.aiBackendConfigured
                    ? cs.onSurfaceVariant
                    : cs.error,
              ),
            ),
            value: TtsEngine.piper,
            groupValue: d.engine,
            onChanged: AppConstants.aiBackendConfigured
                ? (v) => _onEngine(v, d)
                : null,
          ),
          RadioListTile<TtsEngine>(
            title: const Text('Kokoro (cloud, premium English)'),
            subtitle: Text(
              AppConstants.aiBackendConfigured
                  ? 'Best-quality English voices — Amy, Adam, Bella, '
                      'Sarah, Michael, Emma, George.'
                  : 'Not configured in this build.',
              style: TextStyle(
                color: AppConstants.aiBackendConfigured
                    ? cs.onSurfaceVariant
                    : cs.error,
              ),
            ),
            value: TtsEngine.kokoro,
            groupValue: d.engine,
            onChanged: AppConstants.aiBackendConfigured
                ? (v) => _onEngine(v, d)
                : null,
          ),
          RadioListTile<TtsEngine>(
            title: const Text('eSpeak (cloud, all languages)'),
            subtitle: Text(
              AppConstants.aiBackendConfigured
                  ? 'Robotic but covers every language reliably.'
                  : 'Not configured in this build.',
              style: TextStyle(
                color: AppConstants.aiBackendConfigured
                    ? cs.onSurfaceVariant
                    : cs.error,
              ),
            ),
            value: TtsEngine.espeak,
            groupValue: d.engine,
            onChanged: AppConstants.aiBackendConfigured
                ? (v) => _onEngine(v, d)
                : null,
          ),
          const Divider(),

          // ── Voice picker ─────────────────────────────────────────
          const ListTile(title: Text('Voice')),
          if (_loadingVoices)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_voices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                d.engine == TtsEngine.system
                    ? 'No system voices found. Install Google TTS, RH Voice, '
                        'or eSpeak via the Play Store to add voices.'
                    : 'No Piper voices on the server yet. Run install.sh on '
                        'the VPS to download the voice catalog.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            )
          else
            ..._voices.map((v) {
              final selected = d.voiceId == v.id;
              return RadioListTile<String>(
                title: Text(v.label),
                subtitle: v.description != null
                    ? Text(v.description!)
                    : Text(v.locale),
                value: v.id,
                groupValue: d.voiceId,
                onChanged: v.available
                    ? (val) => setState(() => _draft = d.copyWith(voiceId: val))
                    : null,
                secondary: v.available
                    ? (selected ? const Icon(Icons.check_circle) : null)
                    : const Tooltip(
                        message: 'Not downloaded on server',
                        child: Icon(Icons.cloud_off, color: Colors.grey),
                      ),
              );
            }),
          const Divider(),

          // ── Auto-detect language ────────────────────────────────
          SwitchListTile(
            title: const Text('Auto-detect language from text'),
            subtitle: const Text(
              'When ON, Read aloud picks a voice matching the PDF\'s '
              'detected language (overrides your saved voice per page). '
              'When OFF, always uses the voice picked above.',
            ),
            value: d.autoDetectLanguage,
            onChanged: (v) => setState(
              () => _draft = d.copyWith(autoDetectLanguage: v),
            ),
          ),

          // ── Karaoke word highlighting ───────────────────────────
          SwitchListTile(
            title: const Text('Highlight spoken words'),
            subtitle: const Text(
              'Shows a footer chip with the current word highlighted '
              'as Read aloud plays. Helps with longer pages and is '
              'particularly useful for language learners.',
            ),
            value: d.highlightSpokenWords,
            onChanged: (v) => setState(
              () => _draft = d.copyWith(highlightSpokenWords: v),
            ),
          ),
          const Divider(),

          // ── Speed slider ─────────────────────────────────────────
          ListTile(
            title: const Text('Speed'),
            subtitle: Text('${(d.rate * 100).round()}% '
                '${d.rate < 0.4 ? "(slow)" : d.rate < 0.6 ? "(normal)" : "(fast)"}',),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider(
              min: 0.2,
              max: 0.8,
              divisions: 12,
              value: d.rate,
              onChanged: (v) => setState(() => _draft = d.copyWith(rate: v)),
            ),
          ),
          const SizedBox(height: 8),

          // ── Preview ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.tonalIcon(
              onPressed: _preview,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Preview voice'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
