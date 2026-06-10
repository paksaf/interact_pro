import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/storage/app_paths.dart';
import '../../data/saved_codes_repository.dart';

/// All formats the generator supports. The first entry (QR) uses the
/// `qr_flutter` engine; the rest go through `barcode_widget`. Maps to a
/// human label and a constructor closure for the actual widget.
enum GenFormat { qr, code128, ean13, upcA, code39, itf }

extension on GenFormat {
  String get label => switch (this) {
        GenFormat.qr => 'QR',
        GenFormat.code128 => 'Code 128',
        GenFormat.ean13 => 'EAN-13',
        GenFormat.upcA => 'UPC-A',
        GenFormat.code39 => 'Code 39',
        GenFormat.itf => 'ITF',
      };

  String get hint => switch (this) {
        GenFormat.qr => 'Any text — URL, Wi-Fi config, vCard, ...',
        GenFormat.code128 => 'Any printable ASCII — alphanumeric ok',
        GenFormat.ean13 => '12 or 13 digits',
        GenFormat.upcA => '11 or 12 digits',
        GenFormat.code39 => r'Uppercase letters + digits + - . space $ / + %',
        GenFormat.itf => 'Even number of digits',
      };
}

/// Returned to the host when the user taps "Save". Carries everything
/// needed to drop the generated PNG into a stamp / share sheet.
class GeneratedCodeResult {
  const GeneratedCodeResult({
    required this.id,
    required this.imagePath,
    required this.rawValue,
    required this.format,
  });
  final String id;
  final String imagePath;
  final String rawValue;
  final String format;
}

/// Composable generator. Renders the chosen code live as the user types,
/// captures it to PNG via RepaintBoundary on Save, persists it into
/// [SavedCodes], and surfaces the resulting path so callers can pipe the
/// image straight into a stamp.
class CodeGeneratorView extends ConsumerStatefulWidget {
  const CodeGeneratorView({this.onSaved, super.key});

  /// Optional callback fired after a successful save. The Scan tab uses
  /// it to offer a "Use as stamp" follow-up.
  final void Function(GeneratedCodeResult)? onSaved;

  @override
  ConsumerState<CodeGeneratorView> createState() => _CodeGeneratorViewState();
}

class _CodeGeneratorViewState extends ConsumerState<CodeGeneratorView> {
  final _textCtrl = TextEditingController(text: 'https://interactpak.com');
  final _labelCtrl = TextEditingController();
  GenFormat _format = GenFormat.qr;
  final GlobalKey _captureKey = GlobalKey();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _textCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  /// Render the offscreen RepaintBoundary to a PNG. Called by [_save]
  /// only once the user has a previewable, valid input.
  Future<Uint8List?> _capturePng() async {
    final boundary = _captureKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    // 3x device pixel ratio so scanners pick the printed copy up easily
    // and the PDF stamp version stays crisp at print resolution.
    final image = await boundary.toImage(pixelRatio: 3.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final png = await _capturePng();
      if (png == null) {
        setState(() {
          _saving = false;
          _error = 'Could not capture image — adjust input and retry.';
        });
        return;
      }

      // Drop the PNG inside the app's pdf-sibling "codes/" folder so
      // it survives reboots and the path is stable across builds.
      final paths = await ref.read(appPathsProvider.future);
      final dir = Directory(p.join(paths.pdfDir.parent.path, 'codes'));
      if (!dir.existsSync()) await dir.create(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = p.join(dir.path, '${_format.name}_$ts.png');
      await File(path).writeAsBytes(png, flush: true);

      final id = await ref.read(savedCodesRepositoryProvider).add(
            origin: SavedCodesRepository.originGenerated,
            format: _format.label,
            rawValue: _textCtrl.text,
            label: _labelCtrl.text.trim().isEmpty
                ? null
                : _labelCtrl.text.trim(),
            imagePath: path,
          );

      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to history')),
      );
      widget.onSaved?.call(GeneratedCodeResult(
        id: id,
        imagePath: path,
        rawValue: _textCtrl.text,
        format: _format.label,
      ),);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Format picker ─────────────────────────────────────────────
        const Text('Format', style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: GenFormat.values.map((f) {
            final selected = _format == f;
            return ChoiceChip(
              label: Text(f.label),
              selected: selected,
              onSelected: (_) => setState(() => _format = f),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        // ── Input ─────────────────────────────────────────────────────
        TextField(
          controller: _textCtrl,
          maxLines: _format == GenFormat.qr ? 4 : 1,
          decoration: InputDecoration(
            labelText: 'Content',
            hintText: _format.hint,
            helperText: _format.hint,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _labelCtrl,
          decoration: const InputDecoration(
            labelText: 'Label (optional)',
            hintText: 'e.g. Office Wi-Fi, Invoice #1234',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        // ── Live preview ──────────────────────────────────────────────
        Center(
          child: RepaintBoundary(
            key: _captureKey,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: _buildPreview(),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: cs.error)),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _saving || _textCtrl.text.isEmpty ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt),
          label: Text(_saving ? 'Saving…' : 'Save & add to history'),
        ),
        const SizedBox(height: 8),
        Text(
          'Saved codes appear in the History tab. From there you can copy '
          'them, re-open URLs, or stamp them onto a PDF.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// Branch on format. QR has its own widget; everything else routes
  /// through `barcode_widget`'s family. Catch the format-specific
  /// validation exceptions (e.g. wrong digit count for EAN-13) and
  /// render an inline error rather than crashing the preview.
  Widget _buildPreview() {
    final v = _textCtrl.text;
    if (v.isEmpty) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: Text(
            'Type content above to preview',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    try {
      if (_format == GenFormat.qr) {
        return SizedBox(
          width: 220,
          height: 220,
          child: QrImageView(
            data: v,
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            backgroundColor: Colors.white,
          ),
        );
      }
      final barcode = switch (_format) {
        GenFormat.code128 => Barcode.code128(),
        GenFormat.ean13 => Barcode.ean13(),
        GenFormat.upcA => Barcode.upcA(),
        GenFormat.code39 => Barcode.code39(),
        GenFormat.itf => Barcode.itf(),
        GenFormat.qr => throw StateError('handled above'),
      };
      return SizedBox(
        height: 120,
        width: 280,
        child: BarcodeWidget(
          data: v,
          barcode: barcode,
          drawText: true,
          width: 280,
          height: 120,
        ),
      );
    } catch (e) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            'Invalid for ${_format.label}: ${e is BarcodeException ? e.message : e}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
  }
}
