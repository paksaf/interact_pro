import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../../lan/data/lan_repository.dart';
import '../../lan/domain/entities.dart';

/// Bottom-sheet picker that lists nearby paired devices and lets the user
/// push a file to the chosen one. Used in two places:
///
///  1. From the OS share-sheet flow — when an external app shares a file
///     into Interact Pro, the receive screen offers "Send to TV…" which
///     opens this sheet. Picking a TV pushes the file there and the TV
///     auto-opens it via [incomingSharesProvider] in app.dart.
///
///  2. From the document viewer's "share" action — same UX, different
///     entry point (the file is already a registered document).
///
/// Unpaired devices in range are shown with a "Pair first" CTA — pairing
/// is its own flow on the Nearby Devices screen, so we don't try to inline
/// the PIN handshake here. Most TVs only need pairing once.
class SendToDeviceSheet extends ConsumerWidget {
  const SendToDeviceSheet({
    required this.file,
    required this.kind,
    required this.suggestedName,
    this.sendAsSignedDocument = false,
    super.key,
  });

  final File file;
  final ShareKind kind;
  final String suggestedName;

  /// Phase 3: when true, the picked peer receives both the file AND
  /// its adjacent `.sigchain.json` sidecar via
  /// [LanRepository.sendSignedDocument] — the receiver auto-imports
  /// the signature chain so they can verify + continue signing. When
  /// false (default), only the file is sent via [LanRepository.send].
  final bool sendAsSignedDocument;

  /// Convenience: open the sheet as a modal. Returns true if a send
  /// completed, false on cancel / error.
  static Future<bool> show(
    BuildContext context, {
    required File file,
    required ShareKind kind,
    required String suggestedName,
    bool sendAsSignedDocument = false,
  }) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SendToDeviceSheet(
        file: file,
        kind: kind,
        suggestedName: suggestedName,
        sendAsSignedDocument: sendAsSignedDocument,
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovered = ref.watch(discoveredDevicesProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(_iconForKind(kind), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Send "$suggestedName"',
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Pick a device on this Wi-Fi to receive it.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: discovered.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not list devices: $e'),
                ),
                data: (peers) {
                  if (peers.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No devices found on this Wi-Fi yet. '
                        'Make sure Interact Pro is open on the receiving '
                        'device and on the same network.',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  // Paired first, then unpaired-discoverable.
                  final paired = peers.where((p) => p.isPaired).toList();
                  final unpaired = peers.where((p) => !p.isPaired).toList();
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in paired)
                        _PeerTile(
                          peer: p,
                          file: file,
                          kind: kind,
                          suggestedName: suggestedName,
                          sendAsSignedDocument: sendAsSignedDocument,
                        ),
                      if (unpaired.isNotEmpty)
                        const Padding(
                          padding:
                              EdgeInsets.fromLTRB(20, 12, 20, 4),
                          child: Text(
                            'NEEDS PAIRING',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      for (final p in unpaired) _UnpairedTile(peer: p),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForKind(ShareKind k) => switch (k) {
        ShareKind.pdf => Icons.picture_as_pdf,
        ShareKind.image => Icons.image,
        ShareKind.video => Icons.play_circle,
        ShareKind.text => Icons.notes,
        ShareKind.document => Icons.description_outlined,
        ShareKind.other => Icons.insert_drive_file,
      };
}

class _PeerTile extends ConsumerStatefulWidget {
  const _PeerTile({
    required this.peer,
    required this.file,
    required this.kind,
    required this.suggestedName,
    required this.sendAsSignedDocument,
  });
  final NearbyDevice peer;
  final File file;
  final ShareKind kind;
  final String suggestedName;
  final bool sendAsSignedDocument;

  @override
  ConsumerState<_PeerTile> createState() => _PeerTileState();
}

class _PeerTileState extends ConsumerState<_PeerTile> {
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final repo = await ref.read(lanRepositoryProvider.future);
      // Two paths: signed-document handoff (Phase 3) sends PDF + the
      // adjacent .sigchain.json sidecar in sequence so the receiver
      // can verify and continue signing. Default path sends just the
      // file.
      final res = widget.sendAsSignedDocument
          ? await repo.sendSignedDocument(
              peer: widget.peer,
              pdfPath: widget.file.path,
              suggestedName: widget.suggestedName,
            )
          : await repo.send(
              peer: widget.peer,
              file: widget.file,
              kind: widget.kind,
              filename: widget.suggestedName,
            );
      if (!mounted) return;
      res.fold(
        (_) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sent to ${widget.peer.name}')),
          );
          Navigator.of(context).pop(true);
        },
        (failure) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(failure.message)),
          );
          appLogger.w('LAN send failed: ${failure.message}');
          setState(() => _sending = false);
        },
      );
    } catch (e, st) {
      appLogger.e('Send tile threw', error: e, stackTrace: st);
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _PlatformIcon(widget.peer.platform),
      title: Text(widget.peer.name),
      subtitle: Text(widget.peer.host, style: const TextStyle(fontSize: 11)),
      trailing: _sending
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.send),
      onTap: _sending ? null : _send,
    );
  }
}

class _UnpairedTile extends StatelessWidget {
  const _UnpairedTile({required this.peer});
  final NearbyDevice peer;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _PlatformIcon(peer.platform),
      title: Text(peer.name),
      subtitle: Text('${peer.host} — pair from Settings → Nearby Devices first',
          style: const TextStyle(fontSize: 11),),
      trailing: TextButton(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Open Settings → Nearby Devices to pair this TV first.',
              ),
            ),
          );
        },
        child: const Text('Pair'),
      ),
    );
  }
}

class _PlatformIcon extends StatelessWidget {
  const _PlatformIcon(this.platform);
  final String platform;

  @override
  Widget build(BuildContext context) {
    final icon = switch (platform) {
      'ios' => Icons.phone_iphone,
      'android' => Icons.phone_android,
      'macos' => Icons.laptop_mac,
      'windows' => Icons.laptop_windows,
      _ => Icons.tv, // unknown ≈ likely a TV in the cast use case
    };
    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Icon(icon,
          color: Theme.of(context).colorScheme.onPrimaryContainer,),
    );
  }
}
