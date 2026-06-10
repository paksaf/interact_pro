import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/permissions/app_permissions.dart';
import '../../../../core/permissions/permission_dialog.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/measurement.dart';

/// Photo-based measuring tool.
///
/// Workflow (single screen):
///   1. Pick a photo (camera or gallery). The reference and the thing
///      to measure must be in the same plane and roughly the same
///      distance from the camera, otherwise perspective distorts the
///      scale.
///   2. Pick a reference object from the chip row (credit card by
///      default, ISO/global standards), or enter a custom mm length.
///   3. Tap the two endpoints of the reference in the photo. The app
///      computes mm-per-widget-pixel from those two taps + the known
///      length.
///   4. Tap pairs of points to measure anything else in the same plane.
///      Each measurement renders as a green line with its length label.
///   5. Switch units (mm/cm/in/m) at any time, or tap "Save" to share
///      an annotated PNG.
///
/// Coordinate system: all taps are stored in widget-local coordinates
/// (relative to the [_ImageCanvas] that renders the photo at
/// `BoxFit.contain` inside its bounds). This sidesteps having to
/// translate to image-pixel space — both the reference and any
/// measurement live in the same coordinate system, and the calibration
/// (mm per widget-pixel) is consistent between them.
///
/// Caveats:
///   • Doesn't compensate for perspective. Reference + target must lie
///     in roughly the same plane.
///   • Doesn't use AR / depth sensors. Pure 2D photo measurement.
///   • Rotating the device while in the screen would invalidate the
///     coords — we don't lock orientation, but document on the help
///     panel.
class MeasuringToolScreen extends StatefulWidget {
  const MeasuringToolScreen({super.key});

  @override
  State<MeasuringToolScreen> createState() => _MeasuringToolScreenState();
}

class _MeasuringToolScreenState extends State<MeasuringToolScreen> {
  final _picker = ImagePicker();

  /// RepaintBoundary key — used by [_saveAsPng] to capture the canvas
  /// (photo + reference + measurements) as a single PNG.
  final _canvasKey = GlobalKey();

  String? _imagePath;

  /// Which reference object the user has chosen. The picker initialises
  /// with the first preset (credit card).
  ReferenceObject _reference = ReferenceObject.presets.first;

  /// Two endpoints of the reference object, in widget-local coords.
  /// Both null = waiting for first tap; one set = waiting for second.
  Offset? _refA;
  Offset? _refB;

  /// Completed measurements (each is a pair of endpoints).
  final List<Measurement> _measurements = [];

  /// First endpoint of an in-progress measurement. Cleared when the
  /// second endpoint is tapped (which finalises a [Measurement]).
  Offset? _pendingPoint;

  MeasurementUnit _unit = MeasurementUnit.millimeter;

  /// Computed once per build from the current reference state.
  double get _mmPerPixel => mmPerPixelFromReference(
        a: _refA,
        b: _refB,
        knownLengthMm: _reference.lengthMm,
      );

  bool get _isCalibrated => _mmPerPixel > 0;

  Future<void> _pick(ImageSource source) async {
    if (source == ImageSource.camera) {
      final ok = await ensurePermission(
        context: context,
        request: AppPermissions.requestCamera,
        featureLabel: 'Camera',
        reason: 'Measuring needs the camera to capture a photo of the '
            'reference object alongside what you want to measure.',
      );
      if (!ok || !mounted) return;
    }
    final picked = await _picker.pickImage(
      source: source,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 95,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _imagePath = picked.path;
      // New image — reset all overlays.
      _refA = null;
      _refB = null;
      _measurements.clear();
      _pendingPoint = null;
    });
  }

  /// Handle a tap on the photo. Routes the tap into the right slot
  /// based on current state: reference → reference → pending → finalise.
  void _onCanvasTap(Offset localPos) {
    setState(() {
      if (_refA == null) {
        _refA = localPos;
      } else if (_refB == null) {
        _refB = localPos;
      } else if (_pendingPoint == null) {
        _pendingPoint = localPos;
      } else {
        _measurements.add(Measurement(a: _pendingPoint!, b: localPos));
        _pendingPoint = null;
      }
    });
  }

  void _resetReference() {
    setState(() {
      _refA = null;
      _refB = null;
      // Don't wipe completed measurements — but they'll re-render with
      // the new (or absent) calibration. If the user wants a clean
      // slate they should hit the global Reset button.
    });
  }

  void _resetAll() {
    setState(() {
      _refA = null;
      _refB = null;
      _measurements.clear();
      _pendingPoint = null;
    });
  }

  void _undoLastMeasurement() {
    setState(() {
      if (_pendingPoint != null) {
        _pendingPoint = null;
      } else if (_measurements.isNotEmpty) {
        _measurements.removeLast();
      }
    });
  }

  /// Open a tiny dialog to enter a custom reference length in mm.
  /// Returns the new ReferenceObject if the user committed, or null
  /// on cancel / invalid input.
  Future<void> _editCustomReference() async {
    final controller = TextEditingController(
      text: _reference.label == 'Custom'
          ? _reference.lengthMm.toString()
          : '',
    );
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom reference length'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the known length of your reference, in millimetres.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              decoration: const InputDecoration(
                suffixText: 'mm',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Use'),
          ),
        ],
      ),
    );
    if (result != null && result > 0) {
      setState(() {
        _reference = ReferenceObject(label: 'Custom', lengthMm: result);
        _resetReference();
      });
    }
  }

  /// Capture the canvas (photo + overlays) as a PNG and hand it to the
  /// system share sheet so the user can save / send it. Pure
  /// RepaintBoundary capture — no extra deps beyond what's already in
  /// the project.
  Future<void> _saveAsPng() async {
    final boundary = _canvasKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    try {
      // pixelRatio: 3.0 → render at high-DPI so labels stay crisp when
      // someone opens the saved PNG on a desktop monitor.
      final image = await boundary.toImage(pixelRatio: 3.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;

      final tmp = await getTemporaryDirectory();
      final f = File(
        '${tmp.path}/measurement-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await f.writeAsBytes(bytes.buffer.asUint8List());

      await SharePlus.instance.share(
        ShareParams(files: [XFile(f.path)], text: 'Measurement annotation'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Measuring tool'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Container(
            width: double.infinity,
            color: Colors.amber.shade700,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: const Row(
              children: [
                Icon(Icons.science_outlined, size: 14, color: Colors.white),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Experimental — accuracy depends on a clear reference object in the same plane. '
                    'For real-world dimensions (doors, walls), use a tape measure.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (_imagePath != null)
            PopupMenuButton<MeasurementUnit>(
              tooltip: 'Units',
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_unit.symbol),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
              onSelected: (u) => setState(() => _unit = u),
              itemBuilder: (_) => [
                for (final u in MeasurementUnit.values)
                  PopupMenuItem(
                    value: u,
                    child: Text('${u.symbol}  (${u.name})'),
                  ),
              ],
            ),
          if (_imagePath != null)
            IconButton(
              tooltip: 'Undo last',
              icon: const Icon(Icons.undo),
              onPressed: _undoLastMeasurement,
            ),
          if (_imagePath != null)
            IconButton(
              tooltip: 'Save as PNG',
              icon: const Icon(Icons.save_alt),
              onPressed: _saveAsPng,
            ),
          if (_imagePath != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                switch (v) {
                  case 'reset-ref':
                    _resetReference();
                    break;
                  case 'reset-all':
                    _resetAll();
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reset-ref', child: Text('Re-tap reference')),
                PopupMenuItem(value: 'reset-all', child: Text('Reset everything')),
              ],
            ),
        ],
      ),
      body: _imagePath == null
          ? _EmptyHelp(onCamera: () => _pick(ImageSource.camera), onGallery: () => _pick(ImageSource.gallery))
          : Column(
              children: [
                _StageBanner(
                  refA: _refA,
                  refB: _refB,
                  pending: _pendingPoint,
                  isCalibrated: _isCalibrated,
                ),
                Expanded(
                  child: RepaintBoundary(
                    key: _canvasKey,
                    child: _ImageCanvas(
                      imagePath: _imagePath!,
                      refA: _refA,
                      refB: _refB,
                      measurements: _measurements,
                      pending: _pendingPoint,
                      mmPerPixel: _mmPerPixel,
                      unit: _unit,
                      referenceLabel: _reference.label,
                      referenceLengthMm: _reference.lengthMm,
                      onTap: _onCanvasTap,
                    ),
                  ),
                ),
                _ReferencePicker(
                  selected: _reference,
                  onChanged: (r) {
                    setState(() {
                      _reference = r;
                      _resetReference();
                    });
                  },
                  onEditCustom: _editCustomReference,
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────

class _EmptyHelp extends StatelessWidget {
  const _EmptyHelp({required this.onCamera, required this.onGallery});

  final VoidCallback onCamera;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 32),
        Icon(Icons.straighten, size: 96, color: cs.outline),
        const SizedBox(height: 16),
        Text(
          'Measure anything in a photo',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Place a reference object of known size — credit card, A4 paper, '
          'a coin — next to what you want to measure, take a photo, then '
          'tap two endpoints of the reference followed by two endpoints of '
          'the target.',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onCamera,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Take photo'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('From gallery'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.tertiaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: cs.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Text(
                    'Tips for accurate measurements',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: cs.onTertiaryContainer,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '• Reference and target must lie in the same plane\n'
                '• Camera roughly perpendicular to that plane\n'
                '• Reference fully visible — pick its longest visible edge\n'
                '• No perspective compensation — flat surfaces work best',
                style: TextStyle(color: cs.onTertiaryContainer, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StageBanner extends StatelessWidget {
  const _StageBanner({
    required this.refA,
    required this.refB,
    required this.pending,
    required this.isCalibrated,
  });

  final Offset? refA;
  final Offset? refB;
  final Offset? pending;
  final bool isCalibrated;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String text;
    IconData icon;
    Color bg;
    if (refA == null) {
      text = 'Tap the FIRST endpoint of the reference object.';
      icon = Icons.looks_one;
      bg = AppTheme.brandGold;
    } else if (refB == null) {
      text = 'Tap the SECOND endpoint of the reference object.';
      icon = Icons.looks_two;
      bg = AppTheme.brandGold;
    } else if (!isCalibrated) {
      text = 'Reference points too close. Re-tap them further apart.';
      icon = Icons.warning_amber;
      bg = Colors.orange;
    } else if (pending == null) {
      text = 'Calibrated. Tap the FIRST endpoint of what you want to measure.';
      icon = Icons.straighten;
      bg = AppTheme.brandGreen;
    } else {
      text = 'Tap the SECOND endpoint to complete the measurement.';
      icon = Icons.straighten;
      bg = AppTheme.brandGreen;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: bg,
      child: Row(
        children: [
          Icon(icon, color: cs.surface, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: cs.surface,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReferencePicker extends StatelessWidget {
  const _ReferencePicker({
    required this.selected,
    required this.onChanged,
    required this.onEditCustom,
  });

  final ReferenceObject selected;
  final ValueChanged<ReferenceObject> onChanged;
  final VoidCallback onEditCustom;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.straighten, size: 14, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                'Reference: ${selected.label} · ${selected.lengthMm} mm',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              if (selected.note != null) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '· ${selected.note}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final r in ReferenceObject.presets)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('${r.label} (${r.lengthMm} mm)'),
                      selected: selected.label == r.label &&
                          selected.lengthMm == r.lengthMm,
                      onSelected: (_) => onChanged(r),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    avatar: const Icon(Icons.edit, size: 14),
                    label: Text(
                      selected.label == 'Custom'
                          ? 'Custom (${selected.lengthMm} mm)'
                          : 'Custom...',
                    ),
                    onPressed: onEditCustom,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageCanvas extends StatelessWidget {
  const _ImageCanvas({
    required this.imagePath,
    required this.refA,
    required this.refB,
    required this.measurements,
    required this.pending,
    required this.mmPerPixel,
    required this.unit,
    required this.referenceLabel,
    required this.referenceLengthMm,
    required this.onTap,
  });

  final String imagePath;
  final Offset? refA;
  final Offset? refB;
  final List<Measurement> measurements;
  final Offset? pending;
  final double mmPerPixel;
  final MeasurementUnit unit;
  final String referenceLabel;
  final double referenceLengthMm;
  final void Function(Offset localPos) onTap;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => onTap(d.localPosition),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.contain,
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _OverlayPainter(
                      refA: refA,
                      refB: refB,
                      measurements: measurements,
                      pending: pending,
                      mmPerPixel: mmPerPixel,
                      unit: unit,
                      referenceLabel: referenceLabel,
                      referenceLengthMm: referenceLengthMm,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.refA,
    required this.refB,
    required this.measurements,
    required this.pending,
    required this.mmPerPixel,
    required this.unit,
    required this.referenceLabel,
    required this.referenceLengthMm,
  });

  final Offset? refA;
  final Offset? refB;
  final List<Measurement> measurements;
  final Offset? pending;
  final double mmPerPixel;
  final MeasurementUnit unit;
  final String referenceLabel;
  final double referenceLengthMm;

  static final _refLine = Paint()
    ..color = AppTheme.brandGold
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round;
  static final _refDot = Paint()..color = AppTheme.brandGold;
  static final _measureLine = Paint()
    ..color = AppTheme.brandGreen
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round;
  static final _measureDot = Paint()..color = AppTheme.brandGreen;
  static final _pendingDot = Paint()
    ..color = AppTheme.brandGreen
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  @override
  void paint(Canvas canvas, Size size) {
    // Reference line + endpoints.
    if (refA != null) {
      _drawDot(canvas, refA!, _refDot);
    }
    if (refB != null) {
      _drawDot(canvas, refB!, _refDot);
    }
    if (refA != null && refB != null) {
      canvas.drawLine(refA!, refB!, _refLine);
      _drawLabel(
        canvas,
        Offset((refA!.dx + refB!.dx) / 2, (refA!.dy + refB!.dy) / 2),
        '$referenceLabel · ${referenceLengthMm.toStringAsFixed(1)} mm',
        bg: AppTheme.brandGold,
      );
    }

    // Completed measurements.
    for (final m in measurements) {
      _drawDot(canvas, m.a, _measureDot);
      _drawDot(canvas, m.b, _measureDot);
      canvas.drawLine(m.a, m.b, _measureLine);
      if (mmPerPixel > 0) {
        _drawLabel(
          canvas,
          m.midpoint,
          unit.format(m.mmFromCalibration(mmPerPixel)),
          bg: AppTheme.brandGreen,
        );
      }
    }

    // Pending half-measurement (first point tapped, waiting for second).
    if (pending != null) {
      canvas.drawCircle(pending!, 8, _pendingDot);
      _drawDot(canvas, pending!, _measureDot);
    }
  }

  void _drawDot(Canvas canvas, Offset p, Paint paint) {
    canvas.drawCircle(p, 6, paint);
    // White ring around the dot for legibility on busy backgrounds.
    canvas.drawCircle(
      p,
      6,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _drawLabel(Canvas canvas, Offset position, String text, {required Color bg}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padX = 8.0;
    const padY = 4.0;
    final rect = Rect.fromCenter(
      center: position,
      width: tp.width + padX * 2,
      height: tp.height + padY * 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));

    canvas.drawRRect(rrect, Paint()..color = bg);
    tp.paint(
      canvas,
      Offset(rect.left + padX, rect.top + padY),
    );
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.refA != refA ||
      old.refB != refB ||
      old.pending != pending ||
      old.measurements != measurements ||
      old.mmPerPixel != mmPerPixel ||
      old.unit != unit ||
      old.referenceLabel != referenceLabel ||
      old.referenceLengthMm != referenceLengthMm;
}
