import 'dart:async';
import 'dart:io' show Platform;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../domain/entities.dart';

/// Service type registered with mDNS / Bonjour. Renamed 2026-05-08 from
/// `_interactpro._tcp` → `_interact._tcp` so the same service type covers
/// every INTERACT app (Interact Pro, Sahulat, FleetOps, Movento, Grower OS,
/// LeathX, ExecOS). Apps differentiate themselves via the `app` TXT field
/// below — receivers can filter by app slug if they only want to surface
/// peers from the same app (default behaviour) or accept cross-app sends.
///
/// The leading underscore is part of the protocol — don't change without
/// updating Info.plist's NSBonjourServices array AND a 6-month deprecation
/// window for older clients still broadcasting the old type.
const String kLanServiceType = '_interact._tcp';

/// Legacy service type, kept around for one release so an Interact Pro
/// instance running 2.0.x can still find a 2.1.x peer (and vice versa).
/// Drop this constant + the dual-broadcast in `startBroadcasting` after
/// 2026-08, by which point every install is on 2.1+.
const String kLegacyLanServiceType = '_interactpro._tcp';

/// TXT record keys broadcast in the mDNS announcement so peers can render
/// rich list entries without a follow-up HTTP round-trip.
class _Txt {
  static const deviceId = 'id';
  static const deviceName = 'name';
  static const platform = 'platform';
  static const appVersion = 'version';

  /// App slug identifying which INTERACT app is broadcasting:
  /// `interactpro` | `sahulat` | `fleetops` | `movento` | `grower` | etc.
  /// Receivers MAY filter on this to only surface same-app peers, or accept
  /// any INTERACT app (the cross-app cast use case).
  static const app = 'app';
}

/// Per-app slug used in the TXT record's `app` field. Override at build time
/// by passing `--dart-define=INTERACT_APP_SLUG=sahulat` if you fork this
/// feature into another INTERACT app. Default is the Interact Pro slug.
const String kInteractAppSlug =
    String.fromEnvironment('INTERACT_APP_SLUG', defaultValue: 'interactpro');

/// Wraps `bonsoir` for both broadcasting *our* presence and discovering
/// *peers*. Not concerned with auth or transfer — just "what's on the LAN".
abstract class LanDiscoveryService {
  /// Stream of currently-visible peers. Emits a fresh list each time the
  /// underlying mDNS resolver adds or removes one. Call [startBrowsing]
  /// before subscribing.
  Stream<List<NearbyDevice>> peers();

  /// Start advertising us so other peers see us in their browse results.
  /// [name] should be a human-readable label like "Waseem's iPhone".
  Future<Result<void>> startBroadcasting({
    required String deviceId,
    required String name,
    required int port,
    String appVersion = '2.0.0',
  });

  Future<void> stopBroadcasting();

  /// Begin listening for peers. Idempotent — safe to call multiple times.
  Future<Result<void>> startBrowsing();

  Future<void> stopBrowsing();
}

class _BonsoirLanDiscoveryService implements LanDiscoveryService {
  BonsoirBroadcast? _broadcast;
  BonsoirBroadcast? _legacyBroadcast;
  BonsoirDiscovery? _discovery;
  BonsoirDiscovery? _legacyDiscovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;
  StreamSubscription<BonsoirDiscoveryEvent>? _legacyDiscoverySub;

  /// Periodic kicker — every ~15 s we tear down + restart the browsers
  /// to force a fresh PTR query. Bonsoir's underlying NSD on Android
  /// (and to a lesser extent CoreBonjour on iOS) does NOT re-query the
  /// network periodically; it relies on the peer to keep announcing.
  /// On consumer Wi-Fi routers with weak IGMP snooping + Android's
  /// aggressive Wi-Fi power save those announcements get dropped, so
  /// peers either appear minutes late or never. Forcing a periodic
  /// re-browse gives every device a chance to be seen within ~30 s of
  /// the screen coming up. Symptoms before this kicker:
  /// "devices only show up right before the app is closed" (Sony
  /// Bravia VH21 + Samsung phone, 2026-05-13 user report).
  Timer? _kickTimer;

  /// Map keyed by deviceId — survives flapping resolution events.
  final Map<String, NearbyDevice> _seen = {};
  final StreamController<List<NearbyDevice>> _peers =
      StreamController<List<NearbyDevice>>.broadcast();

  @override
  Stream<List<NearbyDevice>> peers() => _peers.stream;

  String get _platform {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  @override
  Future<Result<void>> startBroadcasting({
    required String deviceId,
    required String name,
    required int port,
    String appVersion = '2.0.0',
  }) async {
    try {
      await stopBroadcasting();
      final attrs = <String, String>{
        _Txt.deviceId: deviceId,
        _Txt.deviceName: name,
        _Txt.platform: _platform,
        _Txt.appVersion: appVersion,
        _Txt.app: kInteractAppSlug,
      };

      // New canonical broadcast (`_interact._tcp`) — what every 2.1+ peer browses.
      _broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: name,
          type: kLanServiceType,
          port: port,
          attributes: attrs,
        ),
      );
      await _broadcast!.ready;
      await _broadcast!.start();

      // Legacy broadcast (`_interactpro._tcp`) — kept for one release so
      // 2.0.x peers still discover us. Drop this block in 2.2.
      try {
        _legacyBroadcast = BonsoirBroadcast(
          service: BonsoirService(
            name: name,
            type: kLegacyLanServiceType,
            port: port,
            attributes: attrs,
          ),
        );
        await _legacyBroadcast!.ready;
        await _legacyBroadcast!.start();
      } catch (e) {
        appLogger.w('LAN: legacy broadcast skipped: $e');
      }

      appLogger.i('LAN: broadcasting "$name" on port $port (app=$kInteractAppSlug)');
      return const Result<void>.ok(null);
    } catch (e, st) {
      appLogger.e('LAN broadcast failed', error: e, stackTrace: st);
      return Result<void>.err(LanFailure('Could not start broadcasting', cause: e));
    }
  }

  @override
  Future<void> stopBroadcasting() async {
    try {
      await _broadcast?.stop();
    } catch (_) {/* best-effort */}
    try {
      await _legacyBroadcast?.stop();
    } catch (_) {/* best-effort */}
    _broadcast = null;
    _legacyBroadcast = null;
  }

  @override
  Future<Result<void>> startBrowsing() async {
    try {
      if (_discovery != null) return const Result<void>.ok(null);
      _discovery = BonsoirDiscovery(type: kLanServiceType);
      await _discovery!.ready;
      // Capture _discovery in the listener so the handler knows which
      // resolver to use. Pre-2026-05-13 this listener pointed at a bare
      // _handleEvent that always used _discovery.serviceResolver — even
      // when the event came from _legacyDiscovery — which silently failed
      // with PlatformException(discoveryError, "Trying to resolve an
      // undiscovered service"). See lan_discovery_service.dart history.
      _discoverySub = _discovery!.eventStream?.listen(
        (e) => _handleEvent(e, _discovery!),
      );
      await _discovery!.start();

      // Legacy browser too — finds 2.0.x peers still broadcasting the old type.
      // Drop in 2.2 alongside the legacy broadcast.
      try {
        _legacyDiscovery = BonsoirDiscovery(type: kLegacyLanServiceType);
        await _legacyDiscovery!.ready;
        _legacyDiscoverySub = _legacyDiscovery!.eventStream?.listen(
          (e) => _handleEvent(e, _legacyDiscovery!),
        );
        await _legacyDiscovery!.start();
      } catch (e) {
        appLogger.w('LAN: legacy browse skipped: $e');
      }

      appLogger.i('LAN: browsing for peers (canonical + legacy)');

      // Start the periodic re-browse kicker. First fire 15 s after start
      // so the natural announce loop has a chance to find peers cheaply
      // before we resort to the heavier stop+start dance.
      _kickTimer?.cancel();
      _kickTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        try {
          // Stop without clearing _seen so the UI doesn't blink. Re-start
          // immediately so the responder sends a fresh PTR query.
          await _discovery?.stop();
          await _discovery?.ready;
          await _discovery?.start();
          await _legacyDiscovery?.stop();
          await _legacyDiscovery?.ready;
          await _legacyDiscovery?.start();
        } catch (e) {
          appLogger.w('LAN re-browse kick failed (will retry): $e');
        }
      });
      return const Result<void>.ok(null);
    } catch (e, st) {
      // iOS surfaces the local-network permission denial here. We can't
      // open settings ourselves on iOS — settings deep-link only flips
      // mic / camera; "Local Network" lives elsewhere. UI should show
      // an info banner.
      appLogger.e('LAN browse failed', error: e, stackTrace: st);
      return Result<void>.err(LanFailure(
        'Could not start LAN discovery. On iOS, ensure "Local Network" is '
        'enabled for Interact Pro in Settings.',
        cause: e,
      ),);
    }
  }

  @override
  Future<void> stopBrowsing() async {
    _kickTimer?.cancel();
    _kickTimer = null;
    await _discoverySub?.cancel();
    await _legacyDiscoverySub?.cancel();
    _discoverySub = null;
    _legacyDiscoverySub = null;
    try {
      await _discovery?.stop();
    } catch (_) {/* best-effort */}
    try {
      await _legacyDiscovery?.stop();
    } catch (_) {/* best-effort */}
    _discovery = null;
    _legacyDiscovery = null;
  }

  void _handleEvent(BonsoirDiscoveryEvent e, BonsoirDiscovery discovery) {
    final svc = e.service;
    if (svc == null) return;

    switch (e.type) {
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        // Resolution provides the host/port — request it. Critically:
        // use the resolver belonging to the discovery instance that
        // surfaced this event. Passing _discovery.serviceResolver to a
        // _legacyDiscovery event throws PlatformException(discoveryError,
        // "Trying to resolve an undiscovered service") because the
        // canonical resolver doesn't know about services found via
        // the legacy stream.
        e.service?.resolve(discovery.serviceResolver);
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        final resolved = svc as ResolvedBonsoirService;
        final attrs = resolved.attributes;
        final deviceId = attrs[_Txt.deviceId];
        final host = resolved.host;
        if (deviceId == null || host == null) return;
        _seen[deviceId] = NearbyDevice(
          deviceId: deviceId,
          name: attrs[_Txt.deviceName] ?? svc.name,
          host: host,
          port: svc.port,
          platform: attrs[_Txt.platform] ?? 'unknown',
          appVersion: attrs[_Txt.appVersion] ?? 'unknown',
          // Legacy peers (broadcasting `_interactpro._tcp` without an `app`
          // TXT) are assumed Interact Pro since that was the only app then.
          app: attrs[_Txt.app] ?? 'interactpro',
        );
        _peers.add(_seen.values.toList());
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        // bonsoir doesn't always give us TXT on the lost event — match by
        // name as the fallback.
        _seen.removeWhere((_, d) => d.name == svc.name);
        _peers.add(_seen.values.toList());
      default:
      // Other event types (start, stop, resolveFailed) are no-ops here.
    }
  }
}

final lanDiscoveryServiceProvider = Provider<LanDiscoveryService>((ref) {
  final svc = _BonsoirLanDiscoveryService();
  ref.onDispose(() async {
    await svc.stopBroadcasting();
    await svc.stopBrowsing();
  });
  return svc;
});
