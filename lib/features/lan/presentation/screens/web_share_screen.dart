// "Receive from any device" — the web-share portal's on-screen half.
//
// Product req 2026-06-10: a guest iPhone (no Interact Pro installed) must
// be able to push a document to this device (typically the TV). While this
// screen is open the LAN server exposes a PIN-gated upload page; we render
// the QR (URL embeds the PIN so scanning skips typing), the URL for manual
// entry, and the PIN. Closing the screen kills the portal.
//
// Received files flow through the same IncomingShare pipeline as paired
// transfers, so the app-level bootstrap auto-opens the right viewer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/utils/logger.dart';
import '../../../casting/data/local_ip.dart';
import '../../data/lan_repository.dart';
import '../../domain/entities.dart' show IncomingShare;

class WebShareScreen extends ConsumerStatefulWidget {
  const WebShareScreen({super.key});

  @override
  ConsumerState<WebShareScreen> createState() => _WebShareScreenState();
}

class _WebShareScreenState extends ConsumerState<WebShareScreen> {
  String? _url; // http(s)://<ip>:<port>/share
  String? _pin;
  String? _error;
  bool _tls = false;
  StreamSubscription<IncomingShare>? _sub;
  IncomingShare? _lastReceived;
  LanRepository? _repo;

  @override
  void initState() {
    super.initState();
    _activate();
  }

  Future<void> _activate() async {
    try {
      final repo = await ref.read(lanRepositoryProvider.future);
      _repo = repo;
      // Make sure the LAN server is bound (idempotent via port check —
      // calling start() twice would rebind onto a fallback port).
      if (repo.server.port == null) {
        final r = await repo.start();
        if (r.isErr && mounted) {
          setState(() => _error = 'Could not start the receiver.');
          return;
        }
      }
      final ip = await LocalIpResolver.resolve();
      if (ip == null) {
        if (mounted) {
          setState(() => _error =
              'No Wi-Fi address found. Join a Wi-Fi network and try again.',);
        }
        return;
      }
      final pin = repo.server.enableWebShare();
      _sub = repo.server.incomingShares.listen((share) {
        if (!mounted) return;
        setState(() => _lastReceived = share);
      });
      if (mounted) {
        setState(() {
          _pin = pin;
          _tls = repo.server.useTls;
          _url = '${repo.server.scheme}://$ip:${repo.server.port}/share';
        });
      }
    } catch (e, st) {
      appLogger.e('Web share activate failed', error: e, stackTrace: st);
      if (mounted) setState(() => _error = 'Could not start sharing: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _repo?.server.disableWebShare();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Receive from any device')),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : _url == null
                ? const CircularProgressIndicator()
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'On the other device (any phone or laptop on this '
                          'Wi-Fi), scan this code or open the address below.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: QrImageView(
                            // PIN rides in the QR so scanners skip typing.
                            data: '$_url?pin=$_pin',
                            size: 220,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SelectableText(
                          _url!,
                          style: theme.textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text('PIN', style: theme.textTheme.labelMedium),
                        Text(
                          _pin!,
                          style: theme.textTheme.displaySmall?.copyWith(
                            letterSpacing: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_tls) ...[
                          const SizedBox(height: 12),
                          Text(
                            'If the browser warns about the connection, choose '
                            '"Advanced → Continue" — the link is private to '
                            'this Wi-Fi.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                        if (_lastReceived != null) ...[
                          const SizedBox(height: 24),
                          Card(
                            child: ListTile(
                              leading: const Icon(Icons.check_circle,
                                  color: Colors.green,),
                              title: Text('Received from '
                                  '${_lastReceived!.fromName}',),
                              subtitle: Text(_lastReceived!.path
                                  .split('/')
                                  .last,),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
      ),
    );
  }
}
