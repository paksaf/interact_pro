import 'dart:async';

import 'package:media_cast_dlna/media_cast_dlna.dart';

import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../../core/error/failures.dart';
import '../domain/entities.dart';

/// DLNA / UPnP discovery as a fallback for routers / Android builds where
/// mDNS multicast is blocked. Runs in parallel with the Bonsoir-based
/// `LanDiscoveryService` — both publish into the same `peers()` stream
/// at the repository level so the UI doesn't have to know which
/// protocol found a device.
///
/// DLNA devices discovered here are usually smart TVs / set-top boxes
/// that aren't running Interact Pro. They appear as **cast targets**
/// (broadcast-only — we can push files to them but they can't push
/// back). The Pro-to-Pro pair flow still uses Bonsoir + the LAN HTTPS
/// server; DLNA targets get a separate "Cast image" path that renders
/// each PDF page to a JPEG and streams it via the DLNA plugin.
///
/// Why we don't replace Bonsoir wholesale: peers running Interact Pro
/// need the full bidirectional API (send + receive + pair-pinned TLS).
/// DLNA is single-direction, no TLS, no pairing — perfect for one-shot
/// document casts to a TV but useless for the rest of the workflow.
///
/// 2026-06-10: rewritten against the REAL media_cast_dlna 0.3.x surface
/// (Pigeon-generated): `MediaCastDlnaApi` for lifecycle/discovery and
/// `MediaCastDlnaDiscoveryEvents` for the found/lost streams. The
/// previous draft guessed a `MediaCastDlna` class that never existed.
class DlnaDiscoveryService {
  DlnaDiscoveryService();

  final MediaCastDlnaApi _api = MediaCastDlnaApi();
  MediaCastDlnaDiscoveryEvents? _events;
  final Map<String, NearbyDevice> _seen = {};
  final StreamController<List<NearbyDevice>> _peers =
      StreamController<List<NearbyDevice>>.broadcast();
  StreamSubscription<DlnaDevice>? _foundSub;
  StreamSubscription<DeviceUdn>? _lostSub;
  bool _started = false;

  /// Stream of currently-visible DLNA targets. The UI typically merges
  /// this with the Bonsoir `peers()` stream and renders both.
  Stream<List<NearbyDevice>> peers() => _peers.stream;

  /// Begin SSDP discovery. Idempotent — safe to call multiple times.
  Future<Result<void>> start() async {
    if (_started) return const Result<void>.ok(null);
    try {
      if (!await _api.isUpnpServiceInitialized()) {
        await _api.initializeUpnpService();
      }
      _events = MediaCastDlnaDiscoveryEvents();
      _foundSub = _events!.onDeviceFound.listen(
        _onDeviceFound,
        onError: (Object e, StackTrace st) {
          appLogger.e('DLNA discovery error', error: e, stackTrace: st);
        },
      );
      _lostSub = _events!.onDeviceLost.listen(_onDeviceLost);
      await _api.startDiscovery(
        DiscoveryOptions(
          timeout: DiscoveryTimeout(seconds: 10),
          searchTarget: SearchTarget(target: 'upnp:rootdevice'),
        ),
      );
      _started = true;
      appLogger.i('DLNA: SSDP discovery started');
      return const Result<void>.ok(null);
    } catch (e, st) {
      appLogger.e('DLNA start failed', error: e, stackTrace: st);
      return Result<void>.err(
        LanFailure('Could not start DLNA discovery', cause: e),
      );
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    try {
      await _foundSub?.cancel();
      _foundSub = null;
      await _lostSub?.cancel();
      _lostSub = null;
      await _events?.dispose();
      _events = null;
      await _api.stopDiscovery();
    } catch (e) {
      appLogger.w('DLNA stop failed: $e');
    }
    _seen.clear();
    _started = false;
    if (!_peers.isClosed) _peers.add(const []);
  }

  void _onDeviceFound(DlnaDevice device) {
    // Only renderers can receive casts; servers (NAS etc.) are noise here.
    if (!device.deviceType.contains('MediaRenderer')) return;

    final udn = device.udn.value;
    final friendlyName = device.friendlyName;
    final host = device.ipAddress.value;
    if (udn.isEmpty || host.isEmpty) {
      appLogger.w('DLNA: dropped malformed device $friendlyName');
      return;
    }

    final peer = NearbyDevice(
      deviceId: 'dlna:$udn',
      name: '$friendlyName (TV / DLNA)',
      host: host,
      port: 0, // DLNA control goes via the plugin, not Pro's LAN port
      platform: 'dlna',
      appVersion: 'dlna',
    );
    _seen[peer.deviceId] = peer;
    _peers.add(_seen.values.toList(growable: false));
    appLogger.i('DLNA: discovered ${peer.name} @ ${peer.host}');
  }

  void _onDeviceLost(DeviceUdn udn) {
    if (_seen.remove('dlna:${udn.value}') != null) {
      _peers.add(_seen.values.toList(growable: false));
    }
  }

  Future<void> dispose() async {
    await stop();
    await _peers.close();
  }
}
