// SPDX-License-Identifier: AGPL-3.0
//
// LanCastService — sender side of Pro-to-Pro cast over the LAN.
//
// Discovers other Interact Pro instances via the same Bonsoir mDNS
// browser the LAN repo uses for pair / send. When the user picks one,
// we:
//   1. Register the active PDF on our OWN LAN server's /cast/info +
//      /cast/page/{n}.png endpoints by calling setActiveCastPdf().
//   2. POST /cast/start to the peer with our IP + port. The peer's app
//      listens on `incomingCastsProvider` and auto-opens a
//      CastReceiverScreen which polls our /cast/info.
//   3. On viewer page change → POST /cast/page-changed to the peer
//      AND update our local cast state so the receiver's image fetch
//      gets the new page.
//   4. On stopMirror → POST /cast/stop + clearActiveCast() locally.
//
// Why a separate service (not merged into SystemCastService): the
// CompositeCastService routes by CastProtocol, so adding a new
// CastProtocol.interactPro for these devices keeps the existing
// AirPlay / share-sheet paths intact.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import '../../../core/error/failures.dart';
import '../../../core/storage/app_database.dart' as db;
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../lan/data/lan_repository.dart';
import '../../lan/data/lan_tls.dart' show buildPinnedClient;
import '../../lan/domain/entities.dart' show NearbyDevice;
import '../domain/cast_entities.dart';
import '../domain/cast_service.dart';
import 'local_ip.dart';

/// Pick the right scheme+client for talking to a peer.
///
/// Same root cause as #147: Pro 2.1+ servers run HTTPS-only with a
/// self-signed cert pinned to the fingerprint exchanged at pair time.
/// Plain-HTTP calls to those servers get RST'd silently. Look up the
/// paired peer's stored TLS fingerprint; if present, use a pinned
/// HTTPS client. Otherwise fall back to plain HTTP for legacy 2.0.x
/// peers.
Future<({String scheme, http.Client client})> _resolveCastClient(
  Ref ref,
  String peerDeviceId,
) async {
  try {
    final database = ref.read(db.appDatabaseProvider);
    final paired = await database.pairedDevice(peerDeviceId);
    final fp = paired?.tlsFingerprintSha256;
    if (fp != null && fp.isNotEmpty) {
      return (scheme: 'https', client: http_io.IOClient(buildPinnedClient(fp)));
    }
  } catch (e, st) {
    appLogger.w('cast: paired lookup failed for $peerDeviceId',
        error: e, stackTrace: st,);
  }
  return (scheme: 'http', client: http.Client());
}

final lanCastServiceProvider = Provider<CastService>((ref) {
  return LanCastService(ref: ref);
});

class LanCastService implements CastService {
  LanCastService({required Ref ref}) : _ref = ref;

  final Ref _ref;

  final StreamController<CastSession> _sessionCtrl =
      StreamController<CastSession>.broadcast();
  CastSession _current = CastSession.idle;

  /// Most recent peer we're casting to — needed by setActivePage / stop
  /// so the page POST hits the right host. Cleared on stopMirror.
  NearbyDevice? _activePeer;

  /// Sender device id we send to the receiver in /cast/start so the
  /// receiver can later match incoming /cast/page-changed events to
  /// this session. Mirrors LanRepository.deviceId.
  String? _ownDeviceId;

  void _emit(CastSession next) {
    _current = next;
    _sessionCtrl.add(next);
  }

  /// Yields a list of every discovered Pro peer as a CastDevice. Maps
  /// the LAN's NearbyDevice → CastDevice so the CastSheet can render
  /// them next to AirPlay / Share entries without knowing about LAN.
  ///
  /// Implementation: pull the LanRepository's peers() stream directly
  /// (rather than going through the StreamProvider via ref.listen — the
  /// listener pattern inside an async generator has lifecycle gotchas
  /// when the consumer cancels mid-emit). Each emit is converted to a
  /// list of CastDevices and re-yielded.
  @override
  Stream<List<CastDevice>> discover() async* {
    final repo = await _ref.read(lanRepositoryProvider.future);
    yield* repo.peers().map((peers) {
      return peers
          .map((p) => CastDevice(
                id: 'lan.${p.deviceId}',
                name: p.name,
                protocol: CastProtocol.interactPro,
                model: _modelLabel(p),
                address: '${p.host}:${p.port}',
              ),)
          .toList();
    });
  }

  static String _modelLabel(NearbyDevice p) {
    final v = p.appVersion;
    final platform = p.platform;
    return 'Interact Pro · $platform${v.isEmpty ? '' : ' v$v'}';
  }

  @override
  Stream<CastSession> session() => _sessionCtrl.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Result<void>> startMirror({
    required CastDevice device,
    required CastContent content,
    required String pdfPath,
    required String documentTitle,
    required int currentPage,
    required int totalPages,
  }) async {
    if (device.protocol != CastProtocol.interactPro) {
      return const Result.err(CastFailure(
        'LanCastService received a non-Interact-Pro device — '
        'composite routing bug.',
      ),);
    }

    _emit(_current.copyWith(
      status: CastSessionStatus.connecting,
      device: device,
      content: content,
      documentTitle: documentTitle,
      currentPage: currentPage,
      totalPages: totalPages,
      clearError: true,
    ),);

    // Resolve the peer NearbyDevice from id (we stored it as `lan.<id>`).
    final peerId = device.id.startsWith('lan.')
        ? device.id.substring(4)
        : device.id;
    final discovered = _ref.read(discoveredDevicesProvider).asData?.value ?? const [];
    final peer = discovered.firstWhere(
      (p) => p.deviceId == peerId,
      orElse: () => NearbyDevice(
        deviceId: peerId,
        name: device.name,
        host: device.address?.split(':').first ?? '',
        port: int.tryParse(device.address?.split(':').last ?? '') ?? 0,
        platform: 'unknown',
        appVersion: 'unknown',
      ),
    );

    if (peer.host.isEmpty || peer.port == 0) {
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage: 'Peer is no longer reachable — refresh and retry.',
      ),);
      return const Result.err(CastFailure('Peer unreachable.'));
    }

    // Get our LAN repo + server. Cast pulls page PNGs from OUR server
    // so we must own the active-cast registration on our side too.
    final LanRepository repo;
    try {
      repo = await _ref.read(lanRepositoryProvider.future);
    } catch (e) {
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage: 'LAN server not ready: $e',
      ),);
      return Result.err(CastFailure('LAN server not ready', cause: e));
    }
    _ownDeviceId = repo.deviceId;

    final localIp = await LocalIpResolver.resolve();
    if (localIp == null) {
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage: 'Could not determine this device\'s Wi-Fi IP.',
      ),);
      return const Result.err(CastFailure(
        'Could not determine this device\'s Wi-Fi IP. Reconnect to Wi-Fi.',
      ),);
    }

    // Register on our own server. After this, the receiver's GET to
    // http://$localIp:$serverPort/cast/info returns the active doc.
    repo.server.setActiveCastPdf(
      pdfPath: pdfPath,
      documentTitle: documentTitle,
      totalPages: totalPages > 0 ? totalPages : null,
      currentPage: currentPage,
    );

    // Resolve the peer's host BEFORE the HTTP call — same `.local` /
    // IPv6 trap that broke LAN pair.
    final peerHost = await _resolveHost(peer.host);
    if (peerHost == null) {
      repo.server.clearActiveCast();
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage:
            'Could not reach ${peer.name} at ${peer.host}. Same Wi-Fi?',
      ),);
      return Result.err(CastFailure('Peer host not resolvable.'));
    }

    // Fire /cast/start to the peer.
    final body = jsonEncode({
      'senderDeviceId': repo.deviceId,
      'senderName': repo.deviceName,
      'senderHost': localIp,
      'senderPort': repo.server.port,
      'documentTitle': documentTitle,
      'currentPage': currentPage,
      'totalPages': totalPages,
    });
    final castClient = await _resolveCastClient(_ref, peer.deviceId);
    try {
      final resp = await castClient.client
          .post(
            Uri.parse(
                '${castClient.scheme}://$peerHost:${peer.port}/cast/start',),
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        repo.server.clearActiveCast();
        _emit(_current.copyWith(
          status: CastSessionStatus.failed,
          errorMessage:
              'Peer rejected cast start (${resp.statusCode}).',
        ),);
        return Result.err(CastFailure(
          'Peer rejected cast start (${resp.statusCode}).',
        ),);
      }
    } on TimeoutException {
      repo.server.clearActiveCast();
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage:
            '${peer.name} did not respond within 6 s. Open Pro on it and retry.',
      ),);
      return const Result.err(CastFailure('Peer timed out.'));
    } on SocketException catch (e) {
      repo.server.clearActiveCast();
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage:
            'Could not reach ${peer.name}: ${e.message}.',
      ),);
      return Result.err(CastFailure('Could not reach peer.', cause: e));
    } catch (e, st) {
      repo.server.clearActiveCast();
      appLogger.e('LAN cast start failed', error: e, stackTrace: st);
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage: 'Cast start failed: $e',
      ),);
      return Result.err(CastFailure('Cast start failed', cause: e));
    } finally {
      castClient.client.close();
    }

    _activePeer = peer;
    _emit(_current.copyWith(status: CastSessionStatus.mirroring));
    appLogger.i(
      'LAN cast: started → ${peer.name} ($peerHost:${peer.port}); '
      'serving from $localIp:${repo.server.port}',
    );
    return const Result.ok(null);
  }

  @override
  Future<void> setActivePage(int page) async {
    if (!_current.isActive) return;
    final peer = _activePeer;
    if (peer == null) return;

    // Update our own /cast/info first so when the receiver re-polls it
    // gets the new page. Then nudge the receiver explicitly so it
    // doesn't have to wait for its own poll cycle.
    try {
      final repo = await _ref.read(lanRepositoryProvider.future);
      repo.server.setActiveCastPage(page);

      final peerHost = await _resolveHost(peer.host);
      if (peerHost == null) {
        appLogger.w('LAN cast page: cant resolve ${peer.host} — skipping nudge');
      } else {
        // Fire and don't await beyond 2 s — viewer page-flip latency
        // shouldn't depend on the receiver responding. Scheme + client
        // come from the paired-peer TLS lookup (same as /cast/start).
        final c = await _resolveCastClient(_ref, peer.deviceId);
        try {
          await c.client
              .post(
                Uri.parse(
                    '${c.scheme}://$peerHost:${peer.port}/cast/page-changed',),
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'senderDeviceId': _ownDeviceId,
                  'currentPage': page,
                }),
              )
              .timeout(const Duration(seconds: 2));
        } finally {
          c.client.close();
        }
      }
    } catch (e) {
      // Non-fatal; receiver will catch up on its next /cast/info poll.
      appLogger.w('LAN cast page nudge failed: $e');
    }
    _emit(_current.copyWith(currentPage: page));
  }

  @override
  Future<void> stopMirror() async {
    final peer = _activePeer;
    try {
      final repo = await _ref.read(lanRepositoryProvider.future);
      repo.server.clearActiveCast();

      if (peer != null) {
        final peerHost = await _resolveHost(peer.host);
        if (peerHost != null) {
          final c = await _resolveCastClient(_ref, peer.deviceId);
          try {
            await c.client
                .post(
                  Uri.parse(
                      '${c.scheme}://$peerHost:${peer.port}/cast/stop',),
                  headers: const {'Content-Type': 'application/json'},
                  body: jsonEncode({'senderDeviceId': _ownDeviceId}),
                )
                .timeout(const Duration(seconds: 2));
          } finally {
            c.client.close();
          }
        }
      }
    } catch (e) {
      appLogger.w('LAN cast stop nudge failed: $e');
    } finally {
      _activePeer = null;
      _emit(_current.copyWith(
        status: CastSessionStatus.disconnected,
        clearError: true,
      ),);
    }
  }

  /// Same `.local` / IPv6-link-local resolver used in LanRepository —
  /// duplicated here as a tight static helper to avoid coupling. If
  /// this grows, promote to a shared LanHost utility.
  static Future<String?> _resolveHost(String host) async {
    final raw = host.trim();
    if (raw.isEmpty) return null;
    final stripped =
        raw.contains('%') ? raw.substring(0, raw.indexOf('%')) : raw;
    if (InternetAddress.tryParse(stripped) != null) return stripped;
    try {
      final results =
          await InternetAddress.lookup(raw).timeout(const Duration(seconds: 2));
      if (results.isEmpty) return null;
      final v4 = results.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => results.first,
      );
      if (v4.address.toLowerCase().startsWith('fe80:')) return null;
      return v4.address;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _sessionCtrl.close();
  }
}
