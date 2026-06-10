import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Returned by [SplitDialog]. Carries the user's parsed page selection
/// plus an output filename hint. Page indexes are 1-based for human
/// display; the caller converts to 0-based before calling
/// `PdfRepository.extractPages`.
class SplitRequest {
  const SplitRequest({required this.pages1Based, required this.outputName});
  final List<int> pages1Based;
  final String outputName;
}

/// Returned by [WatermarkSheet].
class WatermarkRequest {
  const WatermarkRequest({
    this.text,
    this.imagePath,
    required this.opacity,
    required this.rotationDegrees,
    required this.fontSize,
  });
  final String? text;
  final String? imagePath;
  final double opacity;
  final double rotationDegrees;
  final int fontSize;
}

/// Returned by [MergePicker]. Carries the picked PDFs (already verified
/// to exist on disk) plus an output filename for the merged result.
class MergeRequest {
  const MergeRequest({required this.files, required this.outputName});
  final List<File> files;
  final String outputName;
}

// ─────────────────────────────────────────────────────────────────────
// Split
// ─────────────────────────────────────────────────────────────────────

/// Modal dialog that asks for a page-range expression (`1-5, 8, 10-12`)
/// and validates against [pageCount]. Returns null on cancel.
class SplitDialog extends StatefulWidget {
  const SplitDialog({
    required this.pageCount,
    required this.defaultOutputName,
    super.key,
  });

  /// Total page count of the source — clamps the expression so users
  /// can't ask for page 99 of a 5-page doc.
  final int pageCount;
  final String defaultOutputName;

  @override
  State<SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<SplitDialog> {
  late final TextEditingController _rangeCtrl;
  late final TextEditingController _nameCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rangeCtrl = TextEditingController(text: '1-${widget.pageCount}');
    _nameCtrl = TextEditingController(text: widget.defaultOutputName);
  }

  @override
  void dispose() {
    _rangeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final pages = _parseRange(_rangeCtrl.text, max: widget.pageCount);
    if (pages == null) {
      setState(() => _error =
          'Invalid range. Try formats like "1-5, 8, 10-12".',);
      return;
    }
    if (pages.isEmpty) {
      setState(() => _error = 'No pages selected.');
      return;
    }
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Output filename required.');
      return;
    }
    Navigator.of(context).pop(
      SplitRequest(
        pages1Based: pages,
        outputName: name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Split PDF'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Source has ${widget.pageCount} page'
            '${widget.pageCount == 1 ? '' : 's'}. '
            'Pick which pages to keep.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rangeCtrl,
            autofocus: true,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9,\- ]')),
            ],
            decoration: InputDecoration(
              labelText: 'Pages',
              hintText: 'e.g. 1-5, 8, 10-12',
              helperText: '1-based, comma-separated. Ranges with hyphen.',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Output filename',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Split')),
      ],
    );
  }
}

/// Parses page-range expressions like `1-5, 8, 10-12` into a sorted,
/// de-duplicated list of 1-based page numbers, clamped to [max].
/// Returns null on syntax error, empty list if nothing matched.
List<int>? _parseRange(String input, {required int max}) {
  if (input.trim().isEmpty) return null;
  final result = <int>{};
  for (final part in input.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    if (p.contains('-')) {
      final bounds = p.split('-').map((s) => s.trim()).toList();
      if (bounds.length != 2) return null;
      final lo = int.tryParse(bounds[0]);
      final hi = int.tryParse(bounds[1]);
      if (lo == null || hi == null) return null;
      final from = lo < hi ? lo : hi;
      final to = lo < hi ? hi : lo;
      for (var i = from; i <= to; i++) {
        if (i >= 1 && i <= max) result.add(i);
      }
    } else {
      final n = int.tryParse(p);
      if (n == null) return null;
      if (n >= 1 && n <= max) result.add(n);
    }
  }
  return result.toList()..sort();
}

// ─────────────────────────────────────────────────────────────────────
// Watermark
// ─────────────────────────────────────────────────────────────────────

class WatermarkSheet extends StatefulWidget {
  const WatermarkSheet({super.key});

  @override
  State<WatermarkSheet> createState() => _WatermarkSheetState();
}

class _WatermarkSheetState extends State<WatermarkSheet> {
  final _textCtrl = TextEditingController(text: 'CONFIDENTIAL');
  String? _imagePath;
  double _opacity = 0.18;
  double _rotation = -45;
  int _fontSize = 64;
  int _mode = 0; // 0 = text, 1 = image

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (picked == null) return;
    setState(() => _imagePath = picked.files.single.path);
  }

  void _submit() {
    if (_mode == 0 && _textCtrl.text.trim().isEmpty) return;
    if (_mode == 1 && (_imagePath ?? '').isEmpty) return;
    Navigator.of(context).pop(
      WatermarkRequest(
        text: _mode == 0 ? _textCtrl.text.trim() : null,
        imagePath: _mode == 1 ? _imagePath : null,
        opacity: _opacity,
        rotationDegrees: _rotation,
        fontSize: _fontSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.water_drop_outlined),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Add watermark to every page',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, icon: Icon(Icons.text_fields), label: Text('Text')),
                  ButtonSegment(value: 1, icon: Icon(Icons.image_outlined), label: Text('Image')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 16),
              if (_mode == 0) ...[
                TextField(
                  controller: _textCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Watermark text',
                    hintText: 'CONFIDENTIAL, DRAFT, your name…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Font size: $_fontSize pt'),
                Slider(
                  value: _fontSize.toDouble(),
                  min: 24,
                  max: 144,
                  divisions: 12,
                  label: '$_fontSize',
                  onChanged: (v) => setState(() => _fontSize = v.round()),
                ),
                Text('Rotation: ${_rotation.round()}°'),
                Slider(
                  value: _rotation,
                  min: -90,
                  max: 90,
                  divisions: 18,
                  label: '${_rotation.round()}°',
                  onChanged: (v) => setState(() => _rotation = v),
                ),
              ] else ...[
                FilledButton.tonalIcon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(_imagePath == null ? 'Choose image' : 'Change image'),
                ),
                if (_imagePath != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _imagePath!.split('/').last,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
              const SizedBox(height: 8),
              Text('Opacity: ${(_opacity * 100).round()}%'),
              Slider(
                value: _opacity,
                min: 0.05,
                max: 1.0,
                divisions: 19,
                label: '${(_opacity * 100).round()}%',
                onChanged: (v) => setState(() => _opacity = v),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Apply to every page'),
                onPressed: _submit,
              ),
              const SizedBox(height: 8),
              Text(
                'Watermark is permanent — saves over the current PDF. '
                'Use Undo from the AppBar (within the viewer) to revert.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Merge
// ─────────────────────────────────────────────────────────────────────

/// Lets the user pick N additional PDFs to merge with the currently-open
/// one. Returns a [MergeRequest] with the full ordered list (current PDF
/// first, picked PDFs in selection order). Returns null on cancel.
class MergePicker extends StatefulWidget {
  const MergePicker({required this.currentPdf, super.key});
  final File currentPdf;

  @override
  State<MergePicker> createState() => _MergePickerState();
}

class _MergePickerState extends State<MergePicker> {
  late final List<File> _files;
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _files = [widget.currentPdf];
    _nameCtrl = TextEditingController(
      text: 'Merged_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPdf() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: true,
    );
    if (picked == null) return;
    setState(() {
      for (final p in picked.files) {
        if (p.path != null) _files.add(File(p.path!));
      }
    });
  }

  void _removeAt(int i) {
    if (i == 0) return; // Don't allow removing the source PDF.
    setState(() => _files.removeAt(i));
  }

  void _submit() {
    if (_files.length < 2) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      MergeRequest(
        files: _files,
        outputName: name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 540,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  const Icon(Icons.merge_outlined),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Merge PDFs',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Pages combine top-to-bottom in this order. The first '
                  'entry is the open PDF and stays in place.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: _files.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final f = _files[i];
                  return ListTile(
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text(
                      f.path.split('/').last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: i == 0 ? const Text('Currently open PDF') : null,
                    trailing: i == 0
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => _removeAt(i),
                          ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add another PDF'),
                    onPressed: _addPdf,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Output filename',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.merge_outlined),
                    label: Text(
                      _files.length < 2
                          ? 'Add at least one more PDF'
                          : 'Merge ${_files.length} PDFs',
                    ),
                    onPressed: _files.length >= 2 ? _submit : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
