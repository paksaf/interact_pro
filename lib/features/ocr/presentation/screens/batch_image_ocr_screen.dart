import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../../core/permissions/app_permissions.dart';
import '../../../../core/permissions/permission_dialog.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/logger.dart';

/// Pick N images at once → run ML Kit text recognition on each
/// sequentially → render combined text → user can copy / save as .txt /
/// share.
///
/// Receipts, signs, page photos, etc. — whenever the user has multiple
/// images they'd otherwise process one-by-one through the single-image
/// Image Identifier screen.
class BatchImageOcrScreen extends ConsumerStatefulWidget {
  const BatchImageOcrScreen({super.key});

  @override
  ConsumerState<BatchImageOcrScreen> createState() => _BatchImageOcrScreenState();
}

class _BatchImageOcrScreenState extends ConsumerState<BatchImageOcrScreen> {
  final _picker = ImagePicker();
  final List<_ImageJob> _jobs = [];
  bool _running = false;
  int _completed = 0;
  TextRecognitionScript _script = TextRecognitionScript.latin;

  Future<void> _pickAndRun({bool fromCamera = false}) async {
    if (fromCamera) {
      final ok = await ensurePermission(
        context: context,
        request: AppPermissions.requestCamera,
        featureLabel: 'Camera',
        reason: 'Batch OCR needs the camera to capture each photo.',
      );
      if (!ok || !mounted) return;
    }

    List<XFile> picked;
    if (fromCamera) {
      // Single photo per shutter — user can come back and hit Camera
      // again to add more before running.
      final shot = await _picker.pickImage(source: ImageSource.camera);
      if (shot == null) return;
      picked = [shot];
    } else {
      picked = await _picker.pickMultiImage(
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
      );
    }
    if (picked.isEmpty || !mounted) return;

    setState(() {
      _jobs.addAll(picked.map((f) => _ImageJob(path: f.path)));
    });
  }

  Future<void> _run() async {
    if (_jobs.isEmpty || _running) return;
    setState(() {
      _running = true;
      _completed = 0;
    });

    final recogniser = TextRecognizer(script: _script);
    try {
      for (var i = 0; i < _jobs.length; i++) {
        if (!mounted) return;
        final job = _jobs[i];
        if (job.text != null) {
          // Already processed — skip on re-run.
          setState(() => _completed = i + 1);
          continue;
        }
        try {
          final input = InputImage.fromFilePath(job.path);
          final r = await recogniser.processImage(input);
          job.text = r.text.trim();
        } catch (e, st) {
          appLogger.w('batch ocr image failed', error: e, stackTrace: st);
          job.text = '';
          job.error = '$e';
        }
        if (!mounted) return;
        setState(() => _completed = i + 1);
      }
    } finally {
      await recogniser.close();
      if (!mounted) return;
      setState(() => _running = false);
    }
  }

  String _combinedText() {
    final lines = <String>[];
    for (var i = 0; i < _jobs.length; i++) {
      final j = _jobs[i];
      lines.add('── Image ${i + 1} · ${p.basename(j.path)} ──');
      if (j.error != null) {
        lines.add('(error: ${j.error})');
      } else if ((j.text ?? '').isEmpty) {
        lines.add('(no text recognised)');
      } else {
        lines.add(j.text!);
      }
      lines.add('');
    }
    return lines.join('\n');
  }

  Future<void> _copyAll() async {
    final combined = _combinedText();
    if (combined.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: combined));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Combined text copied to clipboard')),
    );
  }

  Future<void> _saveAndShare() async {
    final combined = _combinedText();
    if (combined.trim().isEmpty) return;
    final paths = await ref.read(appPathsProvider.future);
    final outName = 'BatchOCR_${DateTime.now().millisecondsSinceEpoch}.txt';
    final outPath = p.join(paths.pdfDir.path, outName);
    await File(outPath).writeAsString(combined, flush: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved $outName')),
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(outPath)],
        subject: 'Batch OCR · ${_jobs.length} images',
      ),
    );
  }

  void _removeAt(int i) {
    setState(() => _jobs.removeAt(i));
  }

  @override
  Widget build(BuildContext context) {
    final hasResults = _jobs.any((j) => j.text != null);
    final progress = _jobs.isEmpty ? 0.0 : _completed / _jobs.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Batch OCR')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_jobs.isEmpty) const _EmptyHelp(),
          if (_jobs.isNotEmpty) ...[
            // Script picker — same set as the OCR screen for PDFs.
            DropdownButtonFormField<TextRecognitionScript>(
              initialValue: _script,
              decoration: const InputDecoration(
                labelText: 'Language / script',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: TextRecognitionScript.latin, child: Text('Latin (English, EU)')),
                DropdownMenuItem(value: TextRecognitionScript.chinese, child: Text('Chinese')),
                DropdownMenuItem(value: TextRecognitionScript.japanese, child: Text('Japanese')),
                DropdownMenuItem(value: TextRecognitionScript.korean, child: Text('Korean')),
                DropdownMenuItem(value: TextRecognitionScript.devanagiri, child: Text('Devanagari')),
              ],
              onChanged: _running ? null : (v) => setState(() => _script = v ?? _script),
            ),
            const SizedBox(height: 16),
            ..._jobs.asMap().entries.map((e) => _JobTile(
                  index: e.key,
                  job: e.value,
                  onRemove: _running ? null : () => _removeAt(e.key),
                ),),
            if (_running) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 4),
              Text(
                'Processing $_completed / ${_jobs.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _running ? null : () => _pickAndRun(fromCamera: false),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Pick images'),
              ),
              OutlinedButton.icon(
                onPressed: _running ? null : () => _pickAndRun(fromCamera: true),
                icon: const Icon(Icons.camera_alt),
                label: const Text('Take photo'),
              ),
              if (_jobs.any((j) => j.text == null))
                FilledButton.tonalIcon(
                  onPressed: _running ? null : _run,
                  icon: _running
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(_running ? 'Running…' : 'Run OCR'),
                ),
            ],
          ),
          if (hasResults) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Combined text',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy all',
                  onPressed: _copyAll,
                ),
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Save .txt and share',
                  onPressed: _saveAndShare,
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _combinedText(),
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImageJob {
  _ImageJob({required this.path});
  final String path;
  String? text;
  String? error;
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.index, required this.job, required this.onRemove});
  final int index;
  final _ImageJob job;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(File(job.path), width: 56, height: 56, fit: BoxFit.cover),
        ),
        title: Text(
          p.basename(job.path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          job.error != null
              ? 'Error: ${job.error}'
              : (job.text == null
                  ? 'Pending'
                  : (job.text!.isEmpty
                      ? 'No text recognised'
                      : '${job.text!.length} chars · ${job.text!.split('\n').length} lines')),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: onRemove == null
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: onRemove,
              ),
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
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.image_search, size: 96, color: cs.outline),
          const SizedBox(height: 16),
          Text('Batch OCR multiple images',
              style: Theme.of(context).textTheme.titleMedium,),
          const SizedBox(height: 8),
          Text(
            'Pick photos of receipts, signs, document pages, whiteboards — '
            'or take new ones with the camera. Each image is OCR\'d on '
            'device. The combined text can be copied or saved as .txt.',
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
