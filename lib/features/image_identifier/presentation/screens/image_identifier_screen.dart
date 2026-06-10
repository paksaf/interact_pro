import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/permissions/app_permissions.dart';
import '../../../../core/permissions/permission_dialog.dart';
import '../../data/image_identifier_service.dart';
import '../../domain/identifier_result.dart';

/// "What is this?" screen. Pick an image from the camera or gallery,
/// run ML Kit's image labeler + text recognizer, render labels grouped
/// by domain (People, Food, Vehicles, ...) with a user-tunable
/// confidence threshold, and show any text the model picked up.
///
/// User actions on the result:
///   • Copy labels to clipboard
///   • Share labels as .txt
///   • Drag the confidence slider to widen / narrow the label set
///     without re-running the model — the service keeps the raw labels.
///
/// Sibling utilities live below the picker buttons (Batch OCR for
/// multiple images, Indoor measuring tool).
class ImageIdentifierScreen extends ConsumerStatefulWidget {
  const ImageIdentifierScreen({super.key});

  @override
  ConsumerState<ImageIdentifierScreen> createState() => _ImageIdentifierScreenState();
}

class _ImageIdentifierScreenState extends ConsumerState<ImageIdentifierScreen> {
  final _picker = ImagePicker();
  ImageIdentifyResult? _result;
  bool _busy = false;

  /// User-controlled minimum-confidence filter. Default 0.7 matches the
  /// "decent quality" threshold most ML Kit examples settle on. Slider
  /// range is the full 0.0–1.0 so users can investigate edge labels.
  double _confidence = 0.7;

  Future<void> _pick(ImageSource source) async {
    if (source == ImageSource.camera) {
      final ok = await ensurePermission(
        context: context,
        request: AppPermissions.requestCamera,
        featureLabel: 'Camera',
        reason: 'Identifying objects needs the camera to take a photo.',
      );
      if (!ok || !mounted) return;
    }
    final picked = await _picker.pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 92,
    );
    if (picked == null || !mounted) return;
    await _identify(picked.path);
  }

  Future<void> _identify(String path) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final svc = ref.read(imageIdentifierServiceProvider);
    final r = await svc.identify(path);
    if (!mounted) return;
    setState(() => _busy = false);
    r.fold(
      (res) => setState(() => _result = res),
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      ),
    );
  }

  Future<void> _copyText() async {
    final text = _result?.extractedText ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Text copied to clipboard')),
    );
  }

  /// Build a plain-text dump of the currently-visible labels (grouped
  /// by category, with confidence percentages) plus any extracted text.
  /// Used by both the Copy and Share actions.
  String _labelsAsText() {
    final r = _result;
    if (r == null) return '';
    final buf = StringBuffer();
    buf.writeln('Image identification — ${DateTime.now().toIso8601String()}');
    buf.writeln('Confidence threshold: ${(_confidence * 100).round()}%');
    buf.writeln('');
    final grouped = r.labelsByCategory(minConfidence: _confidence);
    if (grouped.isEmpty) {
      buf.writeln('(no labels above threshold)');
    } else {
      for (final cat in LabelCategory.values) {
        final items = grouped[cat];
        if (items == null || items.isEmpty) continue;
        buf.writeln('${cat.displayName}:');
        for (final l in items) {
          buf.writeln('  • ${l.text}  (${l.percent}%)');
        }
        buf.writeln('');
      }
    }
    if (r.extractedText.isNotEmpty) {
      buf.writeln('Text in image:');
      buf.writeln(r.extractedText);
    }
    return buf.toString();
  }

  Future<void> _copyLabels() async {
    final text = _labelsAsText();
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Labels copied to clipboard')),
    );
  }

  Future<void> _shareLabels() async {
    final text = _labelsAsText();
    if (text.trim().isEmpty) return;
    // Write to a sharable .txt in the temp dir — Android's share sheet
    // can attach a real file rather than just inline text, which lets
    // users save it to Drive/Files/email cleanly.
    final tmp = await getTemporaryDirectory();
    final f = File(
      '${tmp.path}/image-identification-${DateTime.now().millisecondsSinceEpoch}.txt',
    );
    await f.writeAsString(text);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(f.path)], text: 'Image identification results'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image identifier'),
        actions: [
          if (_result != null) ...[
            IconButton(
              tooltip: 'Copy labels',
              icon: const Icon(Icons.copy_outlined),
              onPressed: _copyLabels,
            ),
            IconButton(
              tooltip: 'Share as .txt',
              icon: const Icon(Icons.share_outlined),
              onPressed: _shareLabels,
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_result == null && !_busy)
            const _EmptyHelp()
          else if (_busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              ),
            )
          else
            _ResultCard(
              result: _result!,
              minConfidence: _confidence,
              onCopyText: _copyText,
            ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            _ConfidenceSlider(
              value: _confidence,
              onChanged: (v) => setState(() => _confidence = v),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take photo'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('From gallery'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Sibling utilities — same image-pipeline domain. Batch OCR is
          // the multi-image companion to the single-image OCR shown above
          // (which extracts text alongside identification labels).
          Card(
            child: ListTile(
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('Batch OCR multiple images'),
              subtitle: const Text(
                'Pick or photograph N images, OCR them all, get combined text.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed('/batch-ocr'),
            ),
          ),
          const SizedBox(height: 8),
          // Now active — measuring tool (#18). Pure photo-based: pick
          // a reference object of known size, tap two points, then tap
          // two more points to measure anything else in the same plane.
          Card(
            child: ListTile(
              leading: const Icon(Icons.straighten),
              title: const Text('Measuring tool'),
              subtitle: const Text(
                'Photo + reference object → measure anything in the same plane '
                'in mm/cm/inches.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed('/measure'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHelp extends StatelessWidget {
  const _EmptyHelp();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.image_search, size: 96, color: cs.outline),
          const SizedBox(height: 16),
          Text(
            'What is this?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Take or pick a photo and we\'ll identify what\'s in it — '
            'objects, scenes, and any visible text — using on-device AI. '
            'Works offline, never uploads your photo.',
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ConfidenceSlider extends StatelessWidget {
  const _ConfidenceSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, size: 16, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Confidence threshold',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Text(
                '${(value * 100).round()}%',
                style: TextStyle(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: 0.0,
            max: 1.0,
            divisions: 20,
            label: '${(value * 100).round()}%',
            onChanged: onChanged,
          ),
          Text(
            'Hide labels below this confidence. The model still ran on '
            'all of them — drag down to widen, drag up to narrow.',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.minConfidence,
    required this.onCopyText,
  });

  final ImageIdentifyResult result;
  final double minConfidence;
  final VoidCallback onCopyText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final grouped = result.labelsByCategory(minConfidence: minConfidence);
    final hasAnyLabels = grouped.values.any((l) => l.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(result.imagePath),
            height: 240,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(Icons.bolt, size: 14, color: cs.primary),
            const SizedBox(width: 4),
            Text(
              'Processed in ${result.processingMs} ms · on-device',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            const Spacer(),
            Text(
              '${result.labels.length} raw labels',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (!hasAnyLabels)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              result.labels.isEmpty
                  ? 'No objects identified. Try a clearer photo or one '
                      'with the subject filling more of the frame.'
                  : 'No labels above ${(minConfidence * 100).round()}% confidence. '
                      'Drag the slider down to see lower-confidence guesses.',
            ),
          )
        else ...[
          Text(
            'Identified objects',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          // Render in enum order so categories stay in a stable position
          // across slider movements (otherwise the layout would jitter).
          for (final cat in LabelCategory.values)
            if ((grouped[cat] ?? const []).isNotEmpty)
              _CategorySection(category: cat, labels: grouped[cat]!),
        ],
        if (result.extractedText.isNotEmpty) ...[
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Text in image',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy',
                onPressed: onCopyText,
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              result.extractedText,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({required this.category, required this.labels});

  final LabelCategory category;
  final List<IdentifierLabel> labels;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  category.displayName,
                  style: TextStyle(
                    color: cs.onSecondaryContainer,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '· ${labels.length}',
                  style: TextStyle(
                    color: cs.onSecondaryContainer.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ...labels.map((l) => _LabelTile(label: l)),
        ],
      ),
    );
  }
}

class _LabelTile extends StatelessWidget {
  const _LabelTile({required this.label});
  final IdentifierLabel label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label.text,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: label.confidence.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(cs.primary),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Text(
              '${label.percent}%',
              textAlign: TextAlign.end,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
