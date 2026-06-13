import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../../core/sharing/pro_share.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../domain/entities/ocr_result.dart';
import '../providers/ocr_controller.dart';

/// PRD OCR-01..06 surface. End-to-end:
///   1. User arrives via the Recents OCR tab (no PDF) or the viewer's
///      "Run OCR on this PDF" overflow (with a path).
///   2. We hash the file. Cache hit → results in <1s. Miss → ML Kit runs
///      page-by-page; LinearProgressIndicator follows along.
///   3. Done — user sees the full extracted text + can save .txt or
///      Share. The result is persisted in the OcrCache drift table so
///      next time is instant.
class OcrScreen extends ConsumerStatefulWidget {
  const OcrScreen({this.initialPdfPath, super.key});

  /// When set, OCR auto-runs against this file on first build. The
  /// viewer's overflow menu uses this to chain "view this PDF" →
  /// "extract its text" without an extra file picker step.
  final String? initialPdfPath;

  @override
  ConsumerState<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends ConsumerState<OcrScreen> {
  PdfDocument? _doc;
  OcrAccuracyMode _accuracy = OcrAccuracyMode.fast;
  OcrLanguage _language = OcrLanguage.latin;

  @override
  void initState() {
    super.initState();
    if (widget.initialPdfPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runForPath(widget.initialPdfPath!);
      });
    }
  }

  Future<void> _pickAndRun() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    await _runForPath(path);
  }

  Future<void> _runForPath(String path) async {
    final repo = await ref.read(pdfRepositoryProvider.future);
    final r = await repo.open(path);
    r.fold(
      (PdfDocument doc) async {
        setState(() => _doc = doc);
        ref.read(ocrControllerProvider.notifier).reset();
        await ref.read(ocrControllerProvider.notifier).run(
              doc,
              mode: _accuracy,
              language: _language,
            );
      },
      (failure) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(failure.message)),
        );
      },
    );
  }

  /// Save the extracted text as `.txt` next to the source PDF, then
  /// invoke the system share sheet so the user can email / Files / etc.
  Future<void> _saveAsTxt() async {
    final job = ref.read(ocrControllerProvider);
    if (job.fullText.trim().isEmpty) return;
    final paths = await ref.read(appPathsProvider.future);
    final base = _doc != null
        ? p.basenameWithoutExtension(_doc!.path)
        : 'ocr-${DateTime.now().millisecondsSinceEpoch}';
    final outPath = p.join(paths.pdfDir.path, '$base.txt');
    await File(outPath).writeAsString(job.fullText, flush: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved ${p.basename(outPath)}')),
    );
    await ProShare.files(
      [XFile(outPath)],
      subject: 'OCR text: ${p.basename(outPath)}',
    );
  }

  Future<void> _copyToClipboard() async {
    final job = ref.read(ocrControllerProvider);
    if (job.fullText.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: job.fullText));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied extracted text to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final OcrJobState job = ref.watch(ocrControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR'),
        actions: [
          IconButton(
            tooltip: 'Re-run (skip cache)',
            icon: const Icon(Icons.refresh),
            onPressed: _doc == null || job.isRunning
                ? null
                : () => ref.read(ocrControllerProvider.notifier).run(
                      _doc!,
                      mode: _accuracy,
                      language: _language,
                      useCache: false,
                    ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_doc == null)
            const Text(
              'Pick a PDF or scanned image. We\'ll extract selectable text '
              'using on-device recognition — works without internet.',
            )
          else
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: Text(_doc!.title),
                subtitle: Text(
                  '${_doc!.pageCount} page${_doc!.pageCount == 1 ? '' : 's'} · '
                  '${(_doc!.sizeBytes / 1024).toStringAsFixed(0)} KB',
                ),
              ),
            ),
          const SizedBox(height: 16),

          // ── Accuracy + language pickers. Only useful before run starts;
          // ── once a run is in flight or a result is shown we keep them
          // ── visible (so the user can re-run with different settings) but
          // ── disabled if a job is mid-flight.
          DropdownButtonFormField<OcrAccuracyMode>(
            initialValue: _accuracy,
            decoration: const InputDecoration(
              labelText: 'Accuracy',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: OcrAccuracyMode.fast,
                child: Text('Fast — 1.5× DPI'),
              ),
              DropdownMenuItem(
                value: OcrAccuracyMode.accurate,
                child: Text('Accurate — 3× DPI (slower)'),
              ),
            ],
            onChanged: job.isRunning
                ? null
                : (v) => setState(() => _accuracy = v ?? OcrAccuracyMode.fast),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<OcrLanguage>(
            initialValue: _language,
            decoration: const InputDecoration(
              labelText: 'Language / script',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: OcrLanguage.latin, child: Text('Latin (English, EU)')),
              DropdownMenuItem(value: OcrLanguage.chinese, child: Text('Chinese')),
              DropdownMenuItem(value: OcrLanguage.japanese, child: Text('Japanese')),
              DropdownMenuItem(value: OcrLanguage.korean, child: Text('Korean')),
              DropdownMenuItem(value: OcrLanguage.devanagari, child: Text('Devanagari')),
            ],
            onChanged: job.isRunning
                ? null
                : (v) => setState(() => _language = v ?? OcrLanguage.latin),
          ),
          const SizedBox(height: 16),

          if (_doc == null)
            FilledButton.icon(
              onPressed: _pickAndRun,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose PDF'),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: job.isRunning ? null : _pickAndRun,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Pick another PDF'),
                ),
                FilledButton.tonalIcon(
                  onPressed: job.isRunning
                      ? null
                      : () => ref.read(ocrControllerProvider.notifier).run(
                            _doc!,
                            mode: _accuracy,
                            language: _language,
                          ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run OCR'),
                ),
              ],
            ),

          if (job.isRunning) ...<Widget>[
            const SizedBox(height: 24),
            LinearProgressIndicator(
              value: job.totalPages == 0 ? null : job.progress,
            ),
            const SizedBox(height: 8),
            Text(
              'Recognising… ${job.completedPages.length} / ${job.totalPages} pages',
            ),
          ],

          if (job.error != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              job.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],

          if (!job.isRunning &&
              (job.completedPages.isNotEmpty || job.cachedFullText != null)) ...<Widget>[
            const SizedBox(height: 24),
            Row(
              children: [
                Icon(
                  job.fromCache ? Icons.flash_on : Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    job.fromCache
                        ? 'Loaded from cache (instant — same file already OCR\'d).'
                        : 'OCR complete · ${job.completedPages.length} pages.',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saveAsTxt,
                    icon: const Icon(Icons.text_snippet_outlined),
                    label: const Text('Save .txt'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyToClipboard,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy text'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Result preview — limit height so the user can still scroll
            // the rest of the screen on small phones.
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  job.fullText,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
