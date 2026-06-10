import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/routing/app_routes.dart';
import '../../../handwriting/domain/supported_languages.dart';
import '../../../handwriting/presentation/widgets/language_picker_sheet.dart';
import '../../domain/transcribe_engine.dart';
import '../providers/handwriting_doc_controller.dart';

/// "Photograph a handwritten note → transcribed text" — distinct from
/// the digital-ink screen (which captures live strokes) and from the
/// PDF OCR screen (which works on whole PDFs).
///
/// Flow:
///   1. Pick an image (camera, photo library, or document scanner).
///   2. Choose a language hint (best-effort; auto in cloud mode).
///   3. Pick the engine — on-device (free, fast, OK on print) or AI
///      (cloud, accurate on cursive / mixed-script).
///   4. Tap "Transcribe" → editable text appears below the image.
///   5. Tidy up the transcript inline, then copy / share / save as PDF.
class HandwritingDocScreen extends ConsumerStatefulWidget {
  const HandwritingDocScreen({super.key});

  @override
  ConsumerState<HandwritingDocScreen> createState() =>
      _HandwritingDocScreenState();
}

class _HandwritingDocScreenState extends ConsumerState<HandwritingDocScreen> {
  final _picker = ImagePicker();
  final _editController = TextEditingController();

  /// Track the controller's last-applied transcript so we don't keep
  /// resetting the cursor while the user is typing.
  String _lastAppliedTranscript = '';

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  Future<void> _pickFromCamera() async {
    // The native ImagePicker camera leaves exposure / white balance on
    // device default — fine for selfies, terrible for a book page (the
    // user reported overexposure on bright pages and underexposure on
    // text-heavy ones). For document capture we want the cunning_document_scanner
    // path, which applies edge detection + perspective correction + a
    // contrast-boosted post-process tuned for scanned documents.
    //
    // We still keep the raw camera as a tertiary "Quick photo" option for
    // users who explicitly want it (cursive on a sticky note, e.g.) — but
    // it's no longer the default.
    final f = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 90,
      // Cap the long-edge so a 12MP phone sensor doesn't produce a 4-5MB
      // jpeg that the on-device transcribe pipeline then has to resize
      // anyway. 2000px on the long edge is plenty for ML Kit text recog.
      maxWidth: 2000,
      maxHeight: 2000,
    );
    if (f == null) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Tip: for clearer book / page photos, use Scan instead — it auto-corrects exposure and perspective.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
    ref.read(handwritingDocControllerProvider.notifier).setImagePath(f.path);
  }

  Future<void> _pickFromGallery() async {
    final f = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (f == null) return;
    ref.read(handwritingDocControllerProvider.notifier).setImagePath(f.path);
  }

  /// Use the existing document scanner (auto-crops + perspective-corrects
  /// the page boundary). Best for photographing a notebook page rather
  /// than a flat-laid letter. The scanner can return multiple pages —
  /// we only consume the first since transcription is one image at a
  /// time. Matches the call signature already used by the scanner
  /// repository elsewhere in the app for safety across plugin versions.
  Future<void> _scan() async {
    try {
      final paths = await CunningDocumentScanner.getPictures() ?? <String>[];
      if (paths.isEmpty) return;
      ref
          .read(handwritingDocControllerProvider.notifier)
          .setImagePath(paths.first);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scanner cancelled or unavailable: $e')),
      );
    }
  }

  Future<void> _saveAsPdf() async {
    final controller = ref.read(handwritingDocControllerProvider.notifier);
    final title = await _askPdfTitle();
    if (title == null) return;
    final path = await controller.saveAsPdf(title: title);
    if (path == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: const Text('Saved as PDF'),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () =>
            context.pushNamed(AppRoutes.viewer, extra: path),
      ),
    ),);
  }

  Future<String?> _askPdfTitle() async {
    final now = DateTime.now();
    final defaultTitle = 'Transcription '
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
    final state = ref.watch(handwritingDocControllerProvider);
    final controller = ref.read(handwritingDocControllerProvider.notifier);
    final language = HandwritingLanguage.byTag(state.languageTag);
    final cs = Theme.of(context).colorScheme;

    // Sync the edit controller without nuking the user's cursor.
    if (state.transcript != _lastAppliedTranscript) {
      _editController.text = state.transcript;
      _lastAppliedTranscript = state.transcript;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transcribe handwriting'),
        actions: [
          // Wrap in Focus(autofocus: true) — ActionChip doesn't expose an
          // autofocus parameter directly, but the parent Focus widget
          // gives the chip the same first-on-screen behaviour for TV
          // remote D-pad. Allocated cleanly (no leaked FocusNode).
          Focus(
            autofocus: true,
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
              _ImagePane(
                imagePath: state.imagePath,
                onCamera: _pickFromCamera,
                onGallery: _pickFromGallery,
                onScan: _scan,
                onClear: controller.clearImage,
              ),
              const SizedBox(height: 16),
              _EnginePicker(
                engine: state.engine,
                cloudAvailable: state.cloudAvailable,
                onChanged: controller.setEngine,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: state.transcribing || state.imagePath == null
                    ? null
                    : controller.transcribe,
                icon: state.transcribing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.text_format),
                label: Text(state.transcribing
                    ? 'Reading…'
                    : state.engine == TranscribeEngine.cloud
                        ? 'Transcribe with AI'
                        : 'Transcribe on-device',),
              ),
              if (state.error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: cs.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          state.error!,
                          style: TextStyle(color: cs.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              _TranscriptCard(
                rtl: language.rtl,
                editController: _editController,
                onChanged: controller.editTranscript,
                onCopy: () async {
                  await Clipboard.setData(
                      ClipboardData(text: state.transcript),);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  }
                },
                onShare: () async {
                  if (state.transcript.trim().isEmpty) return;
                  await SharePlus.instance.share(
                    ShareParams(
                      text: state.transcript,
                      subject: 'Handwriting transcription',
                    ),
                  );
                },
                onSavePdf: _saveAsPdf,
                savingPdf: state.savingPdf,
                stats: _StatsLabel(
                  elapsedMs: state.elapsedMs,
                  tokensUsed: state.tokensUsed,
                  detectedLanguage: state.detectedLanguage,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePane extends StatelessWidget {
  const _ImagePane({
    required this.imagePath,
    required this.onCamera,
    required this.onGallery,
    required this.onScan,
    required this.onClear,
  });

  final String? imagePath;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onScan;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.image, color: cs.primary),
              const SizedBox(width: 8),
              Text('Source image',
                  style: Theme.of(context).textTheme.labelLarge,),
              const Spacer(),
              if (imagePath != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove',
                  onPressed: onClear,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (imagePath == null)
            _SourcePicker(
              onCamera: onCamera,
              onGallery: onGallery,
              onScan: onScan,
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(imagePath!),
                fit: BoxFit.contain,
                width: double.infinity,
                // Cap height so a portrait photo doesn't push everything
                // else off the bottom of the screen.
                height: 320,
              ),
            ),
        ],
      ),
    );
  }
}

class _SourcePicker extends StatelessWidget {
  const _SourcePicker({
    required this.onCamera,
    required this.onGallery,
    required this.onScan,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    // Scan is the recommended default for document transcription —
    // auto-crops, perspective-corrects, and contrast-boosts the page.
    // Camera and Photos remain as alternatives for ad-hoc captures
    // (sticky notes, screenshots) where document framing isn't needed.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onScan,
          icon: const Icon(Icons.document_scanner_outlined),
          label: const Text('Scan a page (recommended)'),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.tonalIcon(
              onPressed: onCamera,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Quick photo'),
            ),
            FilledButton.tonalIcon(
              onPressed: onGallery,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('From Photos'),
            ),
          ],
        ),
      ],
    );
  }
}

class _EnginePicker extends StatelessWidget {
  const _EnginePicker({
    required this.engine,
    required this.cloudAvailable,
    required this.onChanged,
  });

  final TranscribeEngine engine;
  final bool cloudAvailable;
  final ValueChanged<TranscribeEngine> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Engine',
            style: Theme.of(context).textTheme.labelLarge,),
        const SizedBox(height: 6),
        SegmentedButton<TranscribeEngine>(
          segments: [
            const ButtonSegment(
              value: TranscribeEngine.onDevice,
              label: Text('On-device'),
              icon: Icon(Icons.phone_android),
            ),
            ButtonSegment(
              value: TranscribeEngine.cloud,
              label: const Text('AI (cloud)'),
              icon: Icon(
                Icons.cloud_outlined,
                color: cloudAvailable ? null : cs.outlineVariant,
              ),
            ),
          ],
          selected: {engine},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 6),
        Text(
          engine == TranscribeEngine.cloud
              ? 'Sends the image to DeepSeek vision. Best on cursive and '
                  'mixed-script handwriting; needs network and an API key.'
              : 'Runs the bundled ML Kit model — fast, free, offline. '
                  'Strong on printed text and clear block letters; weak '
                  'on cursive.',
          style: TextStyle(fontSize: 12, color: cs.outline),
        ),
        if (!cloudAvailable && engine == TranscribeEngine.onDevice) ...[
          const SizedBox(height: 4),
          Text(
            'AI mode is locked: no DeepSeek key configured. '
            'Set DEEPSEEK_API_KEY (build define) or DEEPSEEK_PROXY_URL.',
            style: TextStyle(fontSize: 11, color: cs.outlineVariant),
          ),
        ],
      ],
    );
  }
}

class _TranscriptCard extends StatelessWidget {
  const _TranscriptCard({
    required this.rtl,
    required this.editController,
    required this.onChanged,
    required this.onCopy,
    required this.onShare,
    required this.onSavePdf,
    required this.savingPdf,
    required this.stats,
  });

  final bool rtl;
  final TextEditingController editController;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onCopy;
  final Future<void> Function() onShare;
  final Future<void> Function() onSavePdf;
  final bool savingPdf;
  final Widget stats;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEmpty = editController.text.trim().isEmpty;
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
              stats,
            ],
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: TextField(
              controller: editController,
              onChanged: onChanged,
              maxLines: null,
              minLines: 6,
              style: const TextStyle(fontSize: 16, height: 1.6),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Recognised text appears here.\n'
                    'Edit any mistakes inline before saving.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: isEmpty ? null : onCopy,
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
              OutlinedButton.icon(
                onPressed: isEmpty ? null : onShare,
                icon: const Icon(Icons.ios_share),
                label: const Text('Share'),
              ),
              FilledButton.icon(
                onPressed: isEmpty || savingPdf ? null : onSavePdf,
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
      ),
    );
  }
}

class _StatsLabel extends StatelessWidget {
  const _StatsLabel({
    required this.elapsedMs,
    required this.tokensUsed,
    required this.detectedLanguage,
  });

  final int? elapsedMs;
  final int? tokensUsed;
  final String? detectedLanguage;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (elapsedMs != null) parts.add('${elapsedMs}ms');
    if (tokensUsed != null) parts.add('$tokensUsed tokens');
    if (detectedLanguage != null) parts.add(detectedLanguage!);
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}
