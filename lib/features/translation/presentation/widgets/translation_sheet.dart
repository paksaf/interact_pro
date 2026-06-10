import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/translation_repository.dart';
import '../../domain/translation_entities.dart';

/// Bottom sheet that translates a passed-in piece of text. Wire it up by
/// passing the user's PDF selection (or per-page extracted text) as
/// [originalText].
///
/// Show with:
/// ```dart
/// showModalBottomSheet(
///   context: context,
///   isScrollControlled: true,
///   builder: (_) => TranslationSheet(originalText: text),
/// );
/// ```
class TranslationSheet extends ConsumerStatefulWidget {
  const TranslationSheet({required this.originalText, super.key});
  final String originalText;

  @override
  ConsumerState<TranslationSheet> createState() => _TranslationSheetState();
}

class _TranslationSheetState extends ConsumerState<TranslationSheet> {
  String _target = 'ur';
  bool _running = false;
  String? _result;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    final repo = ref.read(translationRepositoryProvider);
    final res = await repo.translatePageText(
      widget.originalText,
      targetLanguage: _target,
    );
    if (!mounted) return;
    res.fold(
      (r) => setState(() {
        _running = false;
        _result = r.translatedText;
      }),
      (f) => setState(() {
        _running = false;
        _error = f.message;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRtl = SupportedLanguages.isRtl(_target);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('Translate to '),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _target,
                      items: SupportedLanguages.all.entries
                          .map((e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),)
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _target = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _running ? null : _run,
                    child: _running
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),)
                        : const Text('Translate'),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    _Section(title: 'Original', child: SelectableText(widget.originalText)),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_error!),
                        ),
                      ),
                    if (_result != null)
                      _Section(
                        title: SupportedLanguages.all[_target] ?? _target,
                        child: Directionality(
                          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                          child: SelectableText(
                            _result!,
                            style: const TextStyle(fontSize: 16, height: 1.6),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}
