// SPDX-License-Identifier: AGPL-3.0
//
// CastReceiverScreen — full-screen page-image display for the receiver
// side of Pro-to-Pro LAN cast. When a sender pushes /cast/start to us,
// IncomingCastBootstrap navigates here. We then:
//
//   1. Display the current page PNG by pulling
//      `http://$senderHost:$senderPort/cast/page/$page.png`.
//   2. Listen on `castPageUpdatesProvider` for /cast/page-changed and
//      /cast/stop signals — page flips → refetch, stop → pop the route.
//   3. Show a small "Casting from <sender>" overlay so the user always
//      knows what's on screen, with a Stop button that ends the local
//      receiver session (the sender keeps casting unless they also stop).
//
// Designed for TV viewing: edge-to-edge black background, no AppBar, no
// system chrome unless the user wakes them with a remote button. D-pad
// BACK / "back" key pops the screen.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/io_client.dart' as http_io;

import '../../../../core/storage/app_database.dart' as db;
import '../../../../core/utils/logger.dart';
import '../../../lan/data/lan_repository.dart';
import '../../../lan/data/lan_tls.dart' show buildPinnedClient;
import '../../../lan/domain/entities.dart' show IncomingCast;

class CastReceiverScreen extends ConsumerStatefulWidget {
  const CastReceiverScreen({required this.initial, super.key});

  /// The /cast/start event that triggered this screen. We don't re-read
  /// it from anywhere — once mounted the screen owns its own state.
  final IncomingCast initial;

  @override
  ConsumerState<CastReceiverScreen> createState() => _CastReceiverScreenState();
}

class _CastReceiverScreenState extends ConsumerState<CastReceiverScreen> {
  late int _page = widget.initial.currentPage;
  late int _totalPages = widget.initial.totalPages;

  /// Cache-busting counter — when the sender flips pages back to the
  /// same number (rare, but happens with bookmarks / pagination) Image.
  /// network would short-circuit on its URL key. Bumping this forces a
  /// re-fetch.
  int _refreshTick = 0;

  @override
  void initState() {
    super.initState();
    // Hide system chrome for TV — receiver should feel like full-screen
    // playback, not a chrome-bordered scrollable page. Restored in
    // dispose() so the app shell isn't permanently affected.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  void _handleUpdate(CastPageUpdate u) {
    // Only react to updates from THIS sender — multi-sender concurrent
    // cast would otherwise let one sender pop another's receiver.
    if (u.senderDeviceId != widget.initial.senderDeviceId) return;
    if (u.currentPage == null) {
      // Sender stopped.
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    setState(() {
      _page = u.currentPage!;
      _refreshTick++;
    });
  }

  /// Fetch the current page PNG using the right scheme + client for
  /// the sender. Since Pro 2.1+ runs HTTPS-only with a pinned self-
  /// signed cert, plain Image.network can't reach the sender — its
  /// default HttpClient rejects the unknown cert and we'd see "Could
  /// not fetch page". This builds a pinned client per fetch.
  Future<Uint8List> _fetchPage(int page, int tick) async {
    final senderDeviceId = widget.initial.senderDeviceId;
    String scheme = 'http';
    HttpClient? httpClient;
    try {
      final database = ref.read(db.appDatabaseProvider);
      final paired = await database.pairedDevice(senderDeviceId);
      final fp = paired?.tlsFingerprintSha256;
      if (fp != null && fp.isNotEmpty) {
        scheme = 'https';
        httpClient = buildPinnedClient(fp);
      }
    } catch (e, st) {
      appLogger.w('cast receiver: pinned-client lookup failed',
          error: e, stackTrace: st,);
    }
    final client = httpClient != null
        ? http_io.IOClient(httpClient)
        : http_io.IOClient();
    try {
      final url = Uri.parse(
          '$scheme://${widget.initial.senderHost}:${widget.initial.senderPort}'
          '/cast/page/$page.png?t=$tick',);
      final resp = await client.get(url).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        throw HttpException('Status ${resp.statusCode} for $url');
      }
      return resp.bodyBytes;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pipe sender's page updates into _handleUpdate. ref.listen is the
    // right tool here (not ref.watch) — we want side-effects on each
    // new event, not a rebuild bound to AsyncValue state transitions.
    ref.listen<AsyncValue<CastPageUpdate>>(
      castPageUpdatesProvider,
      (prev, next) => next.whenData(_handleUpdate),
    );

    final senderLabel = widget.initial.senderName;
    final docTitle = widget.initial.documentTitle;

    return Scaffold(
      backgroundColor: Colors.black,
      // SafeArea OFF — we want pixel-1 to pixel-N of the TV used.
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The actual page image. `gaplessPlayback` keeps the previous
          // frame on screen while the next one loads, so page flips
          // don't flash black.
          Center(
            child: FutureBuilder<Uint8List>(
              // Re-key the FutureBuilder on (page, refreshTick) so it
              // refetches when the sender flips pages. Without the key
              // change FutureBuilder would hold the same future.
              key: ValueKey('cast-page-$_page-$_refreshTick'),
              future: _fetchPage(_page, _refreshTick),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const CircularProgressIndicator(
                    color: Colors.white,
                  );
                }
                if (snap.hasError || snap.data == null) {
                  appLogger.w('Cast receiver image fetch failed: '
                      '${snap.error}',);
                  return _ErrorPlaceholder(
                    senderLabel: senderLabel,
                    message:
                        'Could not fetch page $_page from $senderLabel.\n'
                        'Make sure $senderLabel is still on the same Wi-Fi.',
                  );
                }
                return Image.memory(
                  snap.data!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                );
              },
            ),
          ),
          // Bottom-center overlay strip — "Casting <doc> from <name>"
          // + Stop button. Auto-hides 4 s after each interaction in a
          // future iteration; for now it's always-on so TV users always
          // see the affordance.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ReceiverOverlay(
              senderLabel: senderLabel,
              documentTitle: docTitle,
              page: _page,
              totalPages: _totalPages,
              onStop: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiverOverlay extends StatelessWidget {
  const _ReceiverOverlay({
    required this.senderLabel,
    required this.documentTitle,
    required this.page,
    required this.totalPages,
    required this.onStop,
  });

  final String senderLabel;
  final String documentTitle;
  final int page;
  final int totalPages;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.cast_connected, color: Colors.white, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  documentTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  totalPages > 0
                      ? 'From $senderLabel · Page $page of $totalPages'
                      : 'From $senderLabel · Page $page',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
            // Keep the focus halo visible on TV — same shape as the
            // brand theme's focus styling so D-pad nav is obvious.
            autofocus: true,
          ),
        ],
      ),
    );
  }
}

class _ErrorPlaceholder extends StatelessWidget {
  const _ErrorPlaceholder({
    required this.senderLabel,
    required this.message,
  });

  final String senderLabel;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
