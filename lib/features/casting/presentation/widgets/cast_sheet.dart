import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../lan/domain/entities.dart';
import '../../../sharing/presentation/send_to_device_sheet.dart';
import '../../domain/cast_entities.dart';
import '../providers/cast_provider.dart';

/// Bottom sheet that lets the user pick what to cast (current page vs full
/// document) and which receiver to send it to. Fires once — discovery,
/// connection, and the actual mirror happen inside [CastService.startMirror].
class CastSheet extends ConsumerStatefulWidget {
  const CastSheet({
    required this.pdfPath,
    required this.documentTitle,
    required this.currentPage,
    required this.totalPages,
    super.key,
  });

  final String pdfPath;
  final String documentTitle;
  final int currentPage;
  final int totalPages;

  @override
  ConsumerState<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends ConsumerState<CastSheet> {
  CastContent _content = CastContent.currentPage;
  bool _busy = false;
  String? _error;

  Future<void> _send(CastDevice device) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final svc = ref.read(castServiceProvider);
    final result = await svc.startMirror(
      device: device,
      content: _content,
      pdfPath: widget.pdfPath,
      documentTitle: widget.documentTitle,
      currentPage: widget.currentPage,
      totalPages: widget.totalPages,
    );
    if (!mounted) return;
    result.fold(
      (_) => Navigator.of(context).pop(),
      (failure) => setState(() {
        _busy = false;
        _error = failure.message;
      }),
    );
  }

  Future<void> _stop() async {
    final svc = ref.read(castServiceProvider);
    await svc.stopMirror();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(castSessionProvider).asData?.value ??
        CastSession.idle;
    final devicesAsync = ref.watch(castDevicesProvider);
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scroll) {
          return SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.cast, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Cast to TV',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  widget.documentTitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (session.isActive) ...[
                  const SizedBox(height: 12),
                  _ActiveSessionBanner(
                    session: session,
                    onStop: _stop,
                  ),
                ],
                const SizedBox(height: 16),
                const _SectionTitle('What to cast'),
                SegmentedButton<CastContent>(
                  segments: [
                    ButtonSegment(
                      value: CastContent.currentPage,
                      label: Text('Page ${widget.currentPage}'),
                      icon: const Icon(Icons.crop_portrait),
                    ),
                    const ButtonSegment(
                      value: CastContent.fullDocument,
                      label: Text('Whole PDF'),
                      icon: Icon(Icons.picture_as_pdf),
                    ),
                  ],
                  selected: {_content},
                  onSelectionChanged: (s) => setState(() => _content = s.first),
                ),
                const SizedBox(height: 16),
                const _SectionTitle('Where to cast'),
                devicesAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'Discovery failed: $e',
                      style: TextStyle(color: cs.error),
                    ),
                  ),
                  data: (devices) {
                    if (devices.isEmpty) {
                      return const _EmptyDevices();
                    }
                    return Column(
                      children: devices
                          .map((d) => _DeviceTile(
                                device: d,
                                onTap: _busy ? null : () => _send(d),
                              ),)
                          .toList(),
                    );
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: cs.onErrorContainer),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const _HintCard(
                  icon: Icons.info_outline,
                  text: 'Tip: Interact Pro on another phone or TV on the '
                      'same Wi-Fi shows up here automatically. AirPlay / '
                      'Chromecast targets surface through your OS share '
                      'sheet — pick "Share / Cast…" for those.',
                ),
                const SizedBox(height: 12),
                // Footer link — pivots from "cast page images to a dumb
                // receiver" (this sheet) to "push the whole PDF file to
                // another Interact Pro device" (SendToDeviceSheet). Two
                // entry points, both bottom sheets, so transitioning
                // between them no longer tangles the navigator stack
                // the way the old push-to-screen Devices button did.
                // First close this sheet, then open the other in a
                // post-frame callback so the first sheet's pop
                // animation finishes cleanly.
                TextButton.icon(
                  onPressed: () {
                    // Capture the root navigator BEFORE we pop this
                    // sheet — once popped, this State's context is
                    // disposed and Navigator.of(context) would throw.
                    // The root NavigatorState outlives every modal
                    // child, so we can safely use it after the frame.
                    final root = Navigator.of(context, rootNavigator: true);
                    final pdfPath = widget.pdfPath;
                    Navigator.of(context).pop();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!root.mounted) return;
                      SendToDeviceSheet.show(
                        root.context,
                        file: File(pdfPath),
                        kind: ShareKind.pdf,
                        suggestedName: p.basename(pdfPath),
                      );
                    });
                  },
                  icon: const Icon(Icons.devices, size: 18),
                  label: const Text(
                    'Or send to another Interact Pro device →',
                    style: TextStyle(fontSize: 12),
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

class _ActiveSessionBanner extends StatelessWidget {
  const _ActiveSessionBanner({required this.session, required this.onStop});
  final CastSession session;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = session.device?.name ?? 'Receiver';
    final page = session.currentPage;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.cast_connected, color: cs.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mirroring to $label',
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (page != null)
                  Text(
                    'Page $page',
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: onStop,
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onTap});
  final CastDevice device;
  final VoidCallback? onTap;

  IconData get _icon {
    switch (device.protocol) {
      case CastProtocol.airplay:
        return Icons.airplay;
      case CastProtocol.chromecast:
        return Icons.cast;
      case CastProtocol.dlna:
        return Icons.tv;
      case CastProtocol.systemShare:
        return Icons.ios_share;
      case CastProtocol.interactPro:
        // tv_outlined makes Pro receivers (especially the Sony Bravia
        // running Pro) visually distinct from the generic share icon.
        return Icons.tv_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(_icon),
      title: Text(device.name),
      subtitle: device.model != null ? Text(device.model!) : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'No receivers detected. Try opening Control Center (iOS) or '
        'tapping Cast in Chrome (Android) to manually pick a screen.',
        style: TextStyle(
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
