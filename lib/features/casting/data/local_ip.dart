import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import '../../../core/utils/logger.dart';

/// Resolves the device's current Wi-Fi IPv4 address — needed when we hand
/// a Chromecast receiver a URL pointing at our own LAN server. The
/// receiver pulls images over that URL, so it must be reachable from the
/// same Wi-Fi the device is on.
///
/// Strategy:
///   1. Ask `network_info_plus` (handles iOS / Android quirks correctly,
///      including iOS 14+ local-network permission gating).
///   2. Fall back to enumerating `NetworkInterface`s and picking the first
///      non-loopback IPv4 on a private / link-local subnet — covers macOS,
///      Windows, Linux, plus the rare Android / iOS edge case where Wi-Fi
///      info is unavailable but a Wi-Fi interface still has an IP.
///
/// Returns null if no usable IP is found, in which case the caller should
/// fall through to the OS share path.
class LocalIpResolver {
  static Future<String?> resolve() async {
    try {
      final wifi = await NetworkInfo().getWifiIP();
      if (_looksUsable(wifi)) return wifi;
    } catch (e) {
      appLogger.w('NetworkInfo.getWifiIP failed: $e');
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (_looksUsable(addr.address)) return addr.address;
        }
      }
    } catch (e) {
      appLogger.w('NetworkInterface.list failed: $e');
    }
    return null;
  }

  /// Reject loopback (`127.x`), unspecified (`0.0.0.0`), and stray null
  /// strings. We don't reject public IPs — that's a future tightening if
  /// we ever support cellular casting (which Chromecast doesn't, anyway).
  static bool _looksUsable(String? addr) {
    if (addr == null || addr.isEmpty) return false;
    if (addr == '0.0.0.0') return false;
    if (addr.startsWith('127.')) return false;
    return true;
  }
}
