import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/composite_cast_service.dart';
import '../../data/lan_cast_service.dart';
import '../../data/system_cast_service.dart';
import '../../domain/cast_entities.dart';
import '../../domain/cast_service.dart';

/// The active cast service. Composes [SystemCastService] (handles AirPlay
/// and the OS share sheet) with [LanCastService] (Pro-to-Pro cast over
/// the LAN — `CastProtocol.interactPro` devices discovered via Bonsoir
/// mDNS, served through our /cast/info + /cast/page/{n}.png endpoints).
/// The viewer doesn't see the split — it tells the composite "mirror to
/// this device" and the composite picks the right backend based on the
/// chosen device's [CastProtocol].
///
/// Chromecast SDK is still disabled (see chromecast_cast_service.dart
/// for the re-enable steps). The system service routes Chromecast
/// traffic through the OS share sheet on Android, so users still see
/// Cast targets via the OS picker — no in-app SDK required.
final castServiceProvider = Provider<CastService>((ref) {
  final system = ref.watch(systemCastServiceProvider);
  final lan = ref.watch(lanCastServiceProvider);
  return CompositeCastService(backends: {
    system: const {
      CastProtocol.airplay,
      CastProtocol.systemShare,
    },
    lan: const {
      CastProtocol.interactPro,
    },
  },);
});

/// Live device list — union of every backend's discovered devices.
final castDevicesProvider = StreamProvider<List<CastDevice>>((ref) {
  final service = ref.watch(castServiceProvider);
  return service.discover();
});

/// Live session status. The toolbar button reads this to switch between
/// the outline icon (idle) and the filled accent icon (mirroring), and
/// the cast sheet reads it for the active-session banner / error text.
final castSessionProvider = StreamProvider<CastSession>((ref) {
  final service = ref.watch(castServiceProvider);
  return service.session().asBroadcastStream();
});

/// True iff *any* receiver is currently being mirrored to.
final isCastingProvider = Provider<bool>((ref) {
  final session = ref.watch(castSessionProvider).asData?.value;
  return session?.isActive ?? false;
});
