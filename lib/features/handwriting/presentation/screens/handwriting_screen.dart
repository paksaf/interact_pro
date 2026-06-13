import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../core/sharing/pro_share.dart';
import '../../domain/handwriting_result.dart';
import '../../domain/supported_languages.dart';
import '../providers/handwriting_controller.dart';
import '../widgets/ink_canvas.dart';
import '../widgets/language_picker_sheet.dart';

/// "Write on screen and transcribe" — the user's main entry point into
/// digital-ink recognition.
///
/// Flow:
///   1. Pick language (chip in the AppBar). On first use the model
///      isn't downloaded — a banner prompts the user to fetch it.
///   2. Draw on the canvas. Multi-stroke supported; the recogniser
///      uses inter-stroke geometry to disambiguate, so writing the
///      whole word in one capture is much better than per-letter.
///   3. Either tap "Recognise" → ML Kit returns ranked candidates, or
///      flip on "Auto" — the screen runs recognition automatically
///      ~1s after the most recent stroke (debounced; cancels if you
///      keep writing).
///   4. Tap "Append" / "Replace" to commit the chosen candidate to the
///      buffered text. The buffer accumulates across recognitions —
///      so the user can write a full paragraph one word at a time.
///   5. Tap copy / share / save-as-PDF to dispatch the finished text.
class HandwritingScreen extends ConsumerStatefulWidget {
  const HandwritingScreen({super.key});

  @override
  ConsumerState<HandwritingScreen> createState() => _HandwritingScreenState();
}

class _HandwritingScreenState extends ConsumerState<HandwritingScreen> {
  final _canvas = InkCanvasController();
  Timer? _continuousTimer;
  int _lastObservedStrokeCount = 0;

  /// How long to wait after the most recent stroke commit before firing
  /// recognition in continuous mode. 1s is the sweet spot — long enough
  /// that the user can finish a multi-stroke letter (think "F" with a
  /// crossbar) without us interrupting, short enough that the result
  /// updates feel live as they write.
  static const Duration _continuousDebounce = Duration(milliseconds: 1000);

  @override
  void initState() {
    super.initState();
    _canvas.addListener(_onCanvasChanged);
  }

  @override
  void dispose() {
    _continuousTimer?.cancel();
    _canvas.removeListener(_onCanvasChanged);
    _canvas.dispose();
    super.dispose();
  }

  /// Triggered every time the canvas commits a stroke or clears. We
  /// only act on stroke increases — a clear emits a notification too
  /// (strokeCount drops to 0) and we shouldn't schedule recognition
  /// after that.
  void _onCanvasChanged() {
    final newCount = _canvas.strokeCount;
    final increased = newCount > _lastObservedStrokeCount;
    _lastObservedStrokeCount = newCount;

    final state = ref.read(handwritingControllerProvider);
    if (!state.continuousMode) return;
    if (!increased) return;
    if (!state.modelDownloaded) return;

    _continuousTimer?.cancel();
    _continuousTimer = Timer(_continuousDebounce, _runContinuousRecognition);
  }

  Future<void> _runContinuousRecognition() async {
    final state = ref.read(handwritingControllerProvider);
    if (!state.continuousMode) return;
    if (state.recognising) return;
    final capture = _canvas.currentCapture();
    if (capture.isEmpty) return;
    await ref.read(handwritingControllerProvider.notifier).recognise(capture);
  }

  Future<void> _recognise() async {
    _continuousTimer?.cancel();
    final capture = _canvas.currentCapture();
    final controller = ref.read(handwritingControllerProvider.notifier);
    await controller.recognise(capture);
  }

  Future<void> _saveAsPdf() async {
    final controller = ref.read(handwritingControllerProvider.notifier);
    final title = await _askPdfTitle();
    if (title == null) return; // user cancelled
    final path = await controller.saveBufferAsPdf(title: title);
    if (path == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: const Text('Saved as PDF'),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () => context.pushNamed(
          AppRoutes.viewer,
          extra: path,
        ),
      ),
    ),);
  }

  /// Tiny dialog for the file title. Pre-fills with today's date so
  /// users who don't care about names get something sensible.
  Future<String?> _askPdfTitle() async {
    final now = DateTime.now();
    final defaultTitle = 'Handwriting '
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final controller = TextEditingController(text: defaultTitle);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save as PDF'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'File name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(handwritingControllerProvider);
    final controller = ref.read(handwritingControllerProvider.notifier);
    final language = HandwritingLanguage.byTag(state.languageTag);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Handwriting'),
        actions: [
          // Tap = pick language. Long-press = re-download current model
          // (recovery path when ML Kit's model gets corrupted and recognise
          // hangs / fails — surfaced in the timeout error message).
          GestureDetector(
            onLongPress: () async {
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(
                SnackBar(content: Text(
                    'Re-downloading ${language.label} model…',),),
              );
              await controller.deleteModel(state.languageTag);
              await controller.refreshModelState();
              // _ensureModelReady will fire on next Recognise tap.
            },
            child: ActionChip(
              avatar: const Icon(Icons.language, size: 18),
              label: Text(language.label),
              onPressed: () {
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const LanguagePickerSheet(),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!state.modelDownloaded && !state.checking)
                _ModelDownloadBanner(
                  language: language,
                  downloading: state.downloading,
                  onDownload: controller.downloadModel,
                ),
              if (state.checking) const _Checking(),
              const SizedBox(height: 12),
              Directionality(
                textDirection:
                    language.rtl ? TextDirection.rtl : TextDirection.ltr,
                child: InkCanvas(controller: _canvas),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _canvas.undo(),
                    icon: const Icon(Icons.undo),
                    label: const Text('Undo'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      _continuousTimer?.cancel();
                      _canvas.clear();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Clear'),
                  ),
                  const Spacer(),
                  // "Auto" toggle drives continuous recognition. Hidden
                  // when the model isn't downloaded — it would just be
                  // a confusing no-op.
                  if (state.modelDownloaded) ...[
                    const Text('Auto', style: TextStyle(fontSize: 12)),
                    Switch(
                      value: state.continuousMode,
                      onChanged: controller.setContinuousMode,
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.icon(
                    onPressed: (state.recognising || state.downloading)
                        ? null
                        : _recognise,
                    icon: (state.recognising || state.downloading)
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high),
                    label: Text(
                      state.downloading
                          ? 'Downloading model…'
                          : state.recognising
                              ? 'Reading…'
                              : 'Recognise',
                    ),
                  ),
                ],
              ),
              if (state.error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: cs.onErrorContainer,),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              state.error!,
                              style: TextStyle(color: cs.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                      // Retry button for model-download failures.
                      // Bound to controller.downloadModel() which
                      // clears state.error + flips downloading=true,
                      // so the red box swaps for an in-progress
                      // indicator instead of looking stale.
                      // Heuristic: only show retry when the error
                      // message hints at a model/download/timeout
                      // — other errors (e.g. permission) need a
                      // different fix and a Retry button would lie
                      // about what tapping it does.
                      if (state.error!.toLowerCase().contains('model') ||
                          state.error!.toLowerCase().contains('timed out') ||
                          state.error!.toLowerCase().contains('download'))
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: state.downloading
                                ? null
                                : () => controller.downloadModel(),
                            icon: Icon(
                              state.downloading
                                  ? Icons.hourglass_top
                                  : Icons.refresh,
                              size: 16,
                              color: cs.onErrorContainer,
                            ),
                            label: Text(
                              state.downloading ? 'Retrying…' : 'Retry',
                              style:
                                  TextStyle(color: cs.onErrorContainer),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (state.result != null) ...[
                const SizedBox(height: 16),
                _ResultCard(
                  rtl: language.rtl,
                  result: state.result!,
                  onAppend: (text) {
                    controller.appendToBuffer(text);
                    _canvas.clear();
                  },
                  onReplace: (text) {
                    controller.replaceBuffer(text);
                    _canvas.clear();
                  },
                  onDismiss: controller.clearResult,
                ),
              ],
              const SizedBox(height: 24),
              _BufferCard(
                rtl: language.rtl,
                text: state.bufferedText,
                savingPdf: state.savingPdf,
                onClear: controller.clearBuffer,
                onSaveAsPdf: _saveAsPdf,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelDownloadBanner extends StatelessWidget {
  const _ModelDownloadBanner({
    required this.language,
    required this.downloading,
    required this.onDownload,
  });

  final HandwritingLanguage language;
  final bool downloading;
  final Future<void> Function() onDownload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_download_outlined, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${language.label} model not downloaded',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'About 10–20MB. After this it runs offline.',
                  style: TextStyle(fontSize: 12, color: cs.outline),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: downloading ? null : onDownload,
            child: downloading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),)
                : const Text('Download'),
          ),
        ],
      ),
    );
  }
}

class _Checking extends StatelessWidget {
  const _Checking();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(8.0),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Checking model availability…',
              style: TextStyle(fontSize: 12),),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.rtl,
    required this.result,
    required this.onAppend,
    required this.onReplace,
    required this.onDismiss,
  });

  final bool rtl;
  final HandwritingResult result;
  final void Function(String text) onAppend;
  final void Function(String text) onReplace;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final candidates = result.candidates;
    if (candidates.isEmpty) {
      return _EmptyResult(onDismiss: onDismiss);
    }
    final HandwritingCandidate best = candidates.first;
    final alternatives = candidates.skip(1).take(3).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.text_fields, color: cs.primary),
              const SizedBox(width: 8),
              Text('Recognised',
                  style: Theme.of(context).textTheme.labelLarge,),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: SelectableText(
              best.text,
              style: const TextStyle(fontSize: 22, height: 1.4),
            ),
          ),
          if (alternatives.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Other matches', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: alternatives
                  .map<Widget>((c) => ActionChip(
                        label: Directionality(
                          textDirection:
                              rtl ? TextDirection.rtl : TextDirection.ltr,
                          child: Text(c.text),
                        ),
                        onPressed: () => onAppend(c.text),
                      ),)
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => onAppend(best.text),
                icon: const Icon(Icons.add),
                label: const Text('Append'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => onReplace(best.text),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Replace'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult({required this.onDismiss});
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.help_outline),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
                'No candidates returned. Try writing more clearly or '
                'switching language.'),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _BufferCard extends StatelessWidget {
  const _BufferCard({
    required this.rtl,
    required this.text,
    required this.savingPdf,
    required this.onClear,
    required this.onSaveAsPdf,
  });

  final bool rtl;
  final String text;
  final bool savingPdf;
  final VoidCallback onClear;
  final Future<void> Function() onSaveAsPdf;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    }
  }

  Future<void> _share() async {
    await ProShare.text(text, subject: 'Handwriting transcript');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEmpty = text.trim().isEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.notes, color: cs.primary),
              const SizedBox(width: 8),
              Text('Transcript',
                  style: Theme.of(context).textTheme.labelLarge,),
              const Spacer(),
              if (!isEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Clear',
                  onPressed: onClear,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (isEmpty)
            Text(
              'Recognised text appears here. Tap "Append" on a result to '
              'build it up word by word.',
              style: TextStyle(color: cs.outline, fontSize: 12),
            )
          else
            Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 16, height: 1.6),
              ),
            ),
          if (!isEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
                OutlinedButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
                FilledButton.icon(
                  onPressed: savingPdf ? null : onSaveAsPdf,
                  icon: savingPdf
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(savingPdf ? 'Saving…' : 'Save as PDF'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
