import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/saved_codes_repository.dart';
import '../../domain/scan_result.dart';

/// Reusable QR / barcode scanner widget. Embeds a live camera preview
/// over which a viewfinder reticle is drawn. Detected codes pop up via
/// [_ResultSheet] with kind-aware quick actions (open URL, dial, copy,
/// connect to Wi-Fi, ...).
///
/// Embed it inside any Scaffold-bearing screen — it doesn't render its
/// own AppBar so the host can compose with other tools (the document
/// scanner toggles between this and the page-capture mode).
class CodeScannerView extends ConsumerStatefulWidget {
  const CodeScannerView({
    this.continuous = false,
    this.onScanned,
    this.persist = true,
    super.key,
  });

  /// When true, the view re-arms itself after each detection so the user
  /// can scan many codes in a row (inventory / list mode). Default
  /// pauses on the first hit and surfaces the result sheet.
  final bool continuous;

  /// Optional callback fired alongside the result sheet. Hosts can use
  /// this to log to a database or send back to a parent route.
  final ValueChanged<ScannedCode>? onScanned;

  /// When true (default) the scanned code is upserted into the
  /// [SavedCodes] history table. Disable for one-off pickers that
  /// shouldn't pollute history.
  final bool persist;

  @override
  ConsumerState<CodeScannerView> createState() => _CodeScannerViewState();
}

class _CodeScannerViewState extends ConsumerState<CodeScannerView> {
  late final MobileScannerController _ctrl;
  bool _handlingResult = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      // Decode every common 1D + 2D format. ML Kit ignores types we don't
      // ask for, so this is free until the camera actually finds one.
      formats: const [
        BarcodeFormat.qrCode,
        BarcodeFormat.aztec,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.pdf417,
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.code39,
        BarcodeFormat.code93,
        BarcodeFormat.code128,
        BarcodeFormat.codabar,
        BarcodeFormat.itf,
      ],
    );
    // mobile_scanner 7.x requires explicit start — v5 auto-started but
    // v6+ leaves it to the host so widgets that mount the scanner
    // off-screen don't open the camera unnecessarily.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _ctrl.start();
      } catch (_) {
        // start() throws when called twice (e.g. on hot-reload); the
        // ValueListenableBuilder still surfaces the running state via
        // ctrl.value, so a swallowed retry is safe.
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handlingResult) return;
    final barcode = capture.barcodes.firstWhere(
      (b) => (b.rawValue ?? '').isNotEmpty,
      orElse: () => capture.barcodes.first,
    );
    final raw = barcode.rawValue ?? '';
    if (raw.isEmpty) return;

    setState(() => _handlingResult = true);
    final scanned = ScannedCode(
      rawValue: raw,
      format: _formatLabel(barcode.format),
      kind: classifyCode(raw),
      scannedAt: DateTime.now(),
    );
    widget.onScanned?.call(scanned);

    // Persist to history so the user can come back to it later. We
    // fire-and-forget — caching is an enhancement, not a correctness
    // requirement.
    if (widget.persist) {
      try {
        await ref.read(savedCodesRepositoryProvider).add(
              origin: SavedCodesRepository.originScanned,
              format: scanned.format,
              rawValue: scanned.rawValue,
            );
      } catch (_) {/* ignore — history write isn't critical */}
    }

    // Haptic cue — the user usually isn't looking at the screen at the
    // exact moment of detection.
    await HapticFeedback.lightImpact();

    if (!widget.continuous) {
      await _ctrl.stop();
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ResultSheet(scanned: scanned),
    );

    if (!mounted) return;
    setState(() => _handlingResult = false);
    if (!widget.continuous) {
      // After the sheet dismisses, restart so the user can scan again.
      await _ctrl.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _ctrl,
          onDetect: _onDetect,
          errorBuilder: (context, error) => _ErrorState(error: error),
        ),
        // Dim outside the reticle, leave a square cutout in the centre.
        const _ScannerOverlay(),
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            children: [
              _ControlButton(
                icon: ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _ctrl,
                  builder: (_, state, __) {
                    return Icon(
                      state.torchState == TorchState.on
                          ? Icons.flash_on
                          : Icons.flash_off,
                    );
                  },
                ),
                tooltip: 'Toggle flash',
                onTap: () => _ctrl.toggleTorch(),
              ),
              const SizedBox(height: 12),
              _ControlButton(
                icon: const Icon(Icons.cameraswitch),
                tooltip: 'Switch camera',
                onTap: () => _ctrl.switchCamera(),
              ),
            ],
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                widget.continuous
                    ? 'Continuous mode — scan as many as you want'
                    : 'Point at a code',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Human-readable label for a [BarcodeFormat]. Falls back to the enum
/// name for the long-tail formats so we never show "Unknown" to users.
String _formatLabel(BarcodeFormat f) => switch (f) {
      BarcodeFormat.qrCode => 'QR',
      BarcodeFormat.aztec => 'Aztec',
      BarcodeFormat.dataMatrix => 'Data Matrix',
      BarcodeFormat.pdf417 => 'PDF417',
      BarcodeFormat.ean13 => 'EAN-13',
      BarcodeFormat.ean8 => 'EAN-8',
      BarcodeFormat.upcA => 'UPC-A',
      BarcodeFormat.upcE => 'UPC-E',
      BarcodeFormat.code39 => 'Code 39',
      BarcodeFormat.code93 => 'Code 93',
      BarcodeFormat.code128 => 'Code 128',
      BarcodeFormat.codabar => 'Codabar',
      BarcodeFormat.itf => 'ITF',
      _ => f.name,
    };

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: IconButton(
        icon: IconTheme(data: const IconThemeData(color: Colors.white), child: icon),
        tooltip: tooltip,
        onPressed: onTap,
      ),
    );
  }
}

class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ReticlePainter(
        borderColor: Theme.of(context).colorScheme.primary,
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// Draws a square viewfinder cutout with corner brackets — the "where
/// the camera looks" affordance.
class _ReticlePainter extends CustomPainter {
  _ReticlePainter({required this.borderColor});
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final shorter = size.shortestSide * 0.7;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: shorter,
      height: shorter,
    );

    // Dim everything outside the rect.
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final outer = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final inner = Path()..addRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(16)),);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      dim,
    );

    // Draw corner brackets.
    final stroke = Paint()
      ..color = borderColor
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const armLen = 24.0;
    void corner(Offset p, Offset a, Offset b) {
      canvas.drawLine(p, p + a, stroke);
      canvas.drawLine(p, p + b, stroke);
    }

    corner(rect.topLeft, const Offset(armLen, 0), const Offset(0, armLen));
    corner(rect.topRight, const Offset(-armLen, 0), const Offset(0, armLen));
    corner(rect.bottomLeft, const Offset(armLen, 0), const Offset(0, -armLen));
    corner(rect.bottomRight, const Offset(-armLen, 0), const Offset(0, -armLen));
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter oldDelegate) =>
      oldDelegate.borderColor != borderColor;
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 64, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              error.errorDetails?.message ?? 'Camera unavailable',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet that surfaces a scanned code with kind-aware actions.
/// Stays generic — the only thing the user can't do here is *dismiss*
/// the sheet without picking an action; tapping the close icon counts.
class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.scanned});
  final ScannedCode scanned;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: scanned.rawValue));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  Future<void> _open(BuildContext context, String urlString) async {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $urlString')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_iconForKind(scanned.kind), color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _titleForKind(scanned.kind),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    scanned.format,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                scanned.rawValue,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ),
            const SizedBox(height: 16),
            ..._actionsFor(context, scanned),
          ],
        ),
      ),
    );
  }

  IconData _iconForKind(ScannedCodeKind k) => switch (k) {
        ScannedCodeKind.url => Icons.link,
        ScannedCodeKind.email => Icons.alternate_email,
        ScannedCodeKind.phone => Icons.call,
        ScannedCodeKind.wifi => Icons.wifi,
        ScannedCodeKind.geo => Icons.place_outlined,
        ScannedCodeKind.vcard => Icons.contact_page_outlined,
        ScannedCodeKind.text => Icons.text_snippet_outlined,
      };

  String _titleForKind(ScannedCodeKind k) => switch (k) {
        ScannedCodeKind.url => 'Link',
        ScannedCodeKind.email => 'Email',
        ScannedCodeKind.phone => 'Phone',
        ScannedCodeKind.wifi => 'Wi-Fi network',
        ScannedCodeKind.geo => 'Location',
        ScannedCodeKind.vcard => 'Contact card',
        ScannedCodeKind.text => 'Text',
      };

  List<Widget> _actionsFor(BuildContext context, ScannedCode s) {
    switch (s.kind) {
      case ScannedCodeKind.url:
        return [
          FilledButton.icon(
            onPressed: () => _open(context, s.rawValue),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open link'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ];
      case ScannedCodeKind.email:
        final addr = s.rawValue.startsWith('mailto:')
            ? s.rawValue
            : 'mailto:${s.rawValue}';
        return [
          FilledButton.icon(
            onPressed: () => _open(context, addr),
            icon: const Icon(Icons.mail_outline),
            label: const Text('Compose email'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ];
      case ScannedCodeKind.phone:
        final tel = s.rawValue.startsWith('tel:') ||
                s.rawValue.startsWith('sms:')
            ? s.rawValue
            : 'tel:${s.rawValue}';
        return [
          FilledButton.icon(
            onPressed: () => _open(context, tel),
            icon: const Icon(Icons.call),
            label: const Text('Call / message'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ];
      case ScannedCodeKind.wifi:
        final wifi = parseWifiPayload(s.rawValue);
        if (wifi == null) {
          return [
            OutlinedButton.icon(
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy),
              label: const Text('Copy raw'),
            ),
          ];
        }
        return [
          _kvRow('Network (SSID)', wifi['S'] ?? ''),
          _kvRow('Security', wifi['T'] ?? 'unknown'),
          _kvRow('Password', wifi['P'] ?? '(none)'),
          if ((wifi['H'] ?? '').toLowerCase() == 'true') _kvRow('Hidden', 'yes'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: wifi['P'] ?? ''));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Wi-Fi password copied')),
              );
            },
            icon: const Icon(Icons.password),
            label: const Text('Copy password'),
          ),
        ];
      case ScannedCodeKind.geo:
        // geo:LAT,LNG — open the OS default map.
        return [
          FilledButton.icon(
            onPressed: () => _open(context, s.rawValue),
            icon: const Icon(Icons.map_outlined),
            label: const Text('Open in Maps'),
          ),
        ];
      case ScannedCodeKind.vcard:
        // Full contact import requires the flutter_contacts package + a
        // permission flow we haven't wired yet. For v1 we just expose
        // the raw vCard so the user can paste into Contacts manually.
        return [
          OutlinedButton.icon(
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy),
            label: const Text('Copy vCard'),
          ),
        ];
      case ScannedCodeKind.text:
        return [
          FilledButton.icon(
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy),
            label: const Text('Copy text'),
          ),
        ];
    }
  }

  Widget _kvRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 130,
              child: Text(k, style: const TextStyle(color: Colors.grey)),
            ),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w500))),
          ],
        ),
      );
}
