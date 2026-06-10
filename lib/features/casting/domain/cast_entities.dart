/// A receiver device the app can cast to. The exact set of fields populated
/// depends on the discovery protocol — the OS-share path doesn't enumerate
/// devices at all, while a future Chromecast/DLNA implementation will fill in
/// [address] / [model] / [protocol] from SSDP or mDNS.
class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.protocol,
    this.model,
    this.address,
  });

  /// Stable per-device identifier the underlying SDK gives us. For the
  /// system-share path we synthesise one from the protocol because the OS
  /// dialog doesn't expose receiver IDs.
  final String id;

  /// Display label ("Living Room TV", "Bedroom Apple TV"). For the
  /// system-share path this is just the protocol name.
  final String name;

  /// Which transport this device speaks. The cast service implementation
  /// picks the right code path based on this.
  final CastProtocol protocol;

  /// Optional manufacturer model string ("Chromecast Ultra", "Samsung QN85B").
  /// Populated only when the discovery layer can read it.
  final String? model;

  /// Reachable host:port the receiver is at right now. Null for OS-mediated
  /// transports (AirPlay via Control Center) where the OS hides this from us.
  final String? address;
}

enum CastProtocol {
  /// iOS / macOS native — wraps `AVRoutePickerView` or surfaces AirPlay via
  /// the OS share sheet. Mirroring is system-level; we don't see the bytes.
  airplay,

  /// Google Cast — requires the Cast SDK and a registered receiver app id.
  /// First-cut implementation falls back to opening the system share sheet
  /// and letting the user pick a Cast-capable target app (Chrome, Google
  /// Home) until the native SDK is wired up.
  chromecast,

  /// DLNA / UPnP — most Samsung / LG / Sony native TVs. SSDP discovery,
  /// AVTransport service. Not implemented in this cut; here so a future
  /// `DlnaCastService` can slot into the same architecture.
  dlna,

  /// OS-mediated — the device picker is the platform's share sheet, no
  /// in-app discovery happens. Always available; works on every OS.
  systemShare,

  /// Another Interact Pro instance discovered on the same Wi-Fi via
  /// Bonsoir mDNS. Sender pushes /cast/start to the peer, peer's app
  /// listens for the IncomingCast event and pops a CastReceiverScreen
  /// which polls /cast/info + /cast/page/{n}.png on the sender. Use
  /// when the receiver is a phone or TV running Pro itself (not a
  /// generic Chromecast / AirPlay receiver). See LanCastService.
  interactPro,
}

/// What the cast service is currently doing. Drives the UI badge on the
/// toolbar button (idle: outline icon, mirroring: filled + accent colour).
enum CastSessionStatus {
  idle,
  discovering,
  connecting,
  mirroring,
  failed,
  disconnected,
}

/// What the user is asking us to mirror. Determines whether we render a
/// single PNG (page) or expose the whole PDF over the LAN server (document).
enum CastContent {
  /// Just the page currently visible in the viewer. Cheaper, instant.
  currentPage,

  /// The whole document. Receiver pulls page-by-page from the LAN server's
  /// `/cast/page/{n}.png` endpoint as the user advances pages.
  fullDocument,
}

class CastSession {
  const CastSession({
    required this.status,
    this.device,
    this.content,
    this.documentTitle,
    this.currentPage,
    this.totalPages,
    this.errorMessage,
  });

  final CastSessionStatus status;
  final CastDevice? device;
  final CastContent? content;
  final String? documentTitle;
  final int? currentPage;
  final int? totalPages;
  final String? errorMessage;

  bool get isActive =>
      status == CastSessionStatus.connecting ||
      status == CastSessionStatus.mirroring;

  CastSession copyWith({
    CastSessionStatus? status,
    CastDevice? device,
    CastContent? content,
    String? documentTitle,
    int? currentPage,
    int? totalPages,
    String? errorMessage,
    bool clearError = false,
  }) {
    return CastSession(
      status: status ?? this.status,
      device: device ?? this.device,
      content: content ?? this.content,
      documentTitle: documentTitle ?? this.documentTitle,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  static const idle = CastSession(status: CastSessionStatus.idle);
}
