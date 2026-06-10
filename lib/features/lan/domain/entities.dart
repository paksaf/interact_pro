/// A device discovered over mDNS — *not* trusted yet. Only after a successful
/// pair handshake does it become a [PairedDevice] in Drift.
class NearbyDevice {
  const NearbyDevice({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    required this.platform,
    required this.appVersion,
    this.app = 'unknown',
    this.isPaired = false,
  });

  /// Stable per-install identifier announced in the mDNS TXT record.
  /// Different from the analytics visitor id — that's tracking; this is identity.
  final String deviceId;

  /// Human-readable label shown in lists ("Waseem's iPhone").
  final String name;

  /// Numeric IPv4 / IPv6 the peer is reachable at right now. May change
  /// when the user switches Wi-Fi networks.
  final String host;

  final int port;

  /// `ios` / `android` / `macos` / `unknown` — for icon selection in UI.
  final String platform;

  /// App version on the peer. Useful for "this peer is too old to receive
  /// hotspots, fall back to flat PDF" upgrade gates later.
  final String appVersion;

  /// INTERACT app slug broadcast in the TXT record:
  /// `interactpro` | `sahulat` | `fleetops` | `movento` | `grower` | `unknown`.
  /// Lets the UI distinguish "Waseem's iPhone (Interact Pro)" from
  /// "Slaughterhouse Tablet (Sahulat)" — and lets receivers filter to
  /// only same-app peers if a feature requires it.
  final String app;

  /// True if a row exists in Drift's PairedDevices keyed by [deviceId].
  /// The discovery layer fills this in by joining against the trust store.
  final bool isPaired;

  /// Used by [LanRepository.pair] to refresh synthetic NearbyDevices
  /// (those built from manual-IP entry) with the values the receiver
  /// self-reports on `/info`. Without this the paired row shows
  /// "Device at 192.168.100.4 / unknown" instead of the receiver's real
  /// name + platform.
  NearbyDevice copyWith({
    String? deviceId,
    String? name,
    String? host,
    int? port,
    String? platform,
    String? appVersion,
    String? app,
    bool? isPaired,
  }) {
    return NearbyDevice(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      appVersion: appVersion ?? this.appVersion,
      app: app ?? this.app,
      isPaired: isPaired ?? this.isPaired,
    );
  }
}

/// A device we have an active trust relationship with. Persisted in Drift.
class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.secret,
    required this.pairedAt,
    this.lastSeenAt,
  });

  final String deviceId;
  final String name;
  final String platform;

  /// 32-byte HMAC-SHA256 key shared between both peers, established during
  /// the pair handshake. Used to sign every transfer.
  final List<int> secret;

  final DateTime pairedAt;
  final DateTime? lastSeenAt;
}

/// In-flight transfer — one of these per active send / receive. UI binds
/// to the stream of these to render progress bars and final status.
class Transfer {
  const Transfer({
    required this.id,
    required this.peerDeviceId,
    required this.documentTitle,
    required this.direction,
    required this.totalBytes,
    required this.transferredBytes,
    required this.status,
    this.errorMessage,
  });

  final String id;
  final String peerDeviceId;
  final String documentTitle;
  final TransferDirection direction;
  final int totalBytes;
  final int transferredBytes;
  final TransferStatus status;
  final String? errorMessage;

  double get progress =>
      totalBytes == 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);
}

enum TransferDirection { sending, receiving }

enum TransferStatus { queued, inProgress, completed, failed, cancelled }

/// Kind of payload a peer-to-peer share carries. Drives:
///   - which folder the receiver writes the file to
///   - which viewer auto-opens after receive
///   - which mimeTypes the phone-side share-sheet shows Interact Pro for
///
/// Keep this list in sync with the AndroidManifest.xml SEND intent-filter
/// mimeTypes — the manifest is what makes Interact Pro appear in the OS
/// share sheet, this enum is what we do once a file lands.
enum ShareKind {
  pdf,
  image,
  video,
  text,
  /// Office / iWork document — .docx, .doc, .rtf, .xlsx, .xls, .pptx,
  /// .ppt, .pages, .numbers, .key. Pro doesn't render these natively
  /// (no Flutter native renderer is shippable + maintained as of
  /// 2026-05) so the receiver UI hands them off to the system "open
  /// with" picker (open_filex) — WPS Office / MS Office / iWork apps
  /// installed on the device handle the actual preview. We still own
  /// the file: it's saved to `incoming/`, surfaced in a dedicated
  /// "Documents" lane (future), and reachable for re-send / save-copy /
  /// upload-to-Drive without re-importing.
  document,
  other;

  /// Canonical lowercase name used in URL `?kind=` and JSON. Always exactly
  /// one of: `pdf | image | video | text | document | other`.
  String get wireName => name;

  /// Default file extension used when the sender didn't supply a filename.
  /// Matches the most common subtype Samsung / Pixel share sheets emit.
  String get defaultExtension => switch (this) {
        ShareKind.pdf => '.pdf',
        ShareKind.image => '.jpg',
        ShareKind.video => '.mp4',
        ShareKind.text => '.txt',
        ShareKind.document => '.docx',
        ShareKind.other => '.bin',
      };

  /// Map an Android mimeType ("image/png", "video/mp4", ...) to a kind.
  /// Used by the phone-side sender so the receiver knows which folder to
  /// write to without us round-tripping the original mime.
  static ShareKind fromMimeType(String? mime) {
    if (mime == null || mime.isEmpty) return ShareKind.other;
    if (mime == 'application/pdf') return ShareKind.pdf;
    if (mime.startsWith('image/')) return ShareKind.image;
    if (mime.startsWith('video/')) return ShareKind.video;
    if (mime.startsWith('text/')) return ShareKind.text;
    // Office / iWork mime types — fall through to .document so the
    // receiver knows to offer the system "Open with" sheet rather than
    // silently park the file in incoming/.
    const documentMimes = <String>{
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/rtf',
      'text/rtf',
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/vnd.apple.pages',
      'application/vnd.apple.numbers',
      'application/vnd.apple.keynote',
      'application/x-iwork-pages-sffpages',
      'application/x-iwork-numbers-sffnumbers',
      'application/x-iwork-keynote-sffkey',
    };
    if (documentMimes.contains(mime)) return ShareKind.document;
    return ShareKind.other;
  }

  /// Inverse of [wireName]. Falls back to `other` for unknown values so the
  /// receiver never crashes on a future kind it doesn't understand.
  static ShareKind parse(String? raw) {
    return switch (raw?.toLowerCase()) {
      'pdf' => ShareKind.pdf,
      'image' => ShareKind.image,
      'video' => ShareKind.video,
      'text' => ShareKind.text,
      'document' => ShareKind.document,
      _ => ShareKind.other,
    };
  }
}

/// Event emitted by [LanServer] when a peer initiates a cast TO us — they
/// have set their local LAN server to serve a PDF page-by-page and want
/// us to display it. Receiver UI (an `IncomingCastBootstrap` mounted in
/// `app.dart`) consumes the stream and pushes a `CastReceiverScreen`
/// which polls `http://$senderHost:$senderPort/cast/info` and renders
/// the page PNGs as the user navigates on the sender.
///
/// Distinct from `IncomingShare` (file landing on disk): cast is
/// transient + page-level + display-only, share is durable + file-level.
class IncomingCast {
  const IncomingCast({
    required this.senderDeviceId,
    required this.senderName,
    required this.senderHost,
    required this.senderPort,
    required this.documentTitle,
    required this.currentPage,
    required this.totalPages,
    required this.startedAt,
  });

  /// `peer.deviceId` of the sender — receiver matches against paired
  /// devices to render "From Waseem's iPhone" rather than the bare host.
  final String senderDeviceId;
  final String senderName;

  /// Numeric IP + port the receiver should poll for /cast/info and
  /// /cast/page/{n}.png. We require the sender to send a numeric IP
  /// (not its `.local` hostname) because dart:io has no mDNS resolver
  /// — receiver-side InternetAddress.lookup of `.local` would fail the
  /// same way the LAN pair flow did before _resolveLanHost.
  final String senderHost;
  final int senderPort;

  final String documentTitle;
  final int currentPage;
  final int totalPages;
  final DateTime startedAt;
}

/// An incoming PIN challenge — fired by the LAN server when another
/// Pro instance hits `/pair/init` on us. The bootstrap widget mounted in
/// `app.dart` listens to the stream and pops up a dialog so the user
/// can read the PIN off the screen and type it into the SENDER device,
/// completing the pair handshake.
///
/// The 6-digit PIN is short-lived: 60 s before the server auto-evicts
/// the pending entry. The dialog dismisses on the same timeline so it
/// doesn't linger on screen after the challenge is dead.
class IncomingPinChallenge {
  const IncomingPinChallenge({
    required this.pin,
    required this.fromDeviceName,
    required this.fromPlatform,
    required this.expiresAt,
  });

  /// 6-digit PIN (zero-padded as a string so leading zeros survive).
  final String pin;

  /// Human-readable name of the requesting device, taken from the
  /// `/pair/init` body's `fromName` field. Falls back to "Unknown
  /// device" if the sender didn't include one.
  final String fromDeviceName;
  final String fromPlatform;
  final DateTime expiresAt;

  Duration get remaining {
    final d = expiresAt.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }
}

/// Sent on the same stream when the sender advances pages or stops the
/// cast. The receiver UI listens and updates without re-pushing the
/// screen. `currentPage == null` means "cast ended" — receiver should
/// pop back to where it came from.
class CastPageUpdate {
  const CastPageUpdate({
    required this.senderDeviceId,
    required this.currentPage,
  });

  final String senderDeviceId;

  /// 1-based page index or null when the sender posted /cast/stop.
  final int? currentPage;
}

/// Event emitted by [LanServer] when a paired peer pushes a file to us.
/// UI (the router-attached listener in app.dart) consumes this stream and
/// auto-opens the file in the right viewer.
class IncomingShare {
  const IncomingShare({
    required this.path,
    required this.kind,
    required this.fromPeerId,
    required this.fromName,
    required this.receivedAt,
    required this.bytes,
  });

  /// Absolute path on disk where the bytes have been written.
  final String path;

  /// What kind of payload — drives which viewer to push.
  final ShareKind kind;

  /// Peer device id of the sender (matches the row in PairedDevices).
  final String fromPeerId;

  /// Human-readable peer name ("Waseem's iPhone") for snackbar / banner copy.
  final String fromName;

  final DateTime receivedAt;

  /// Total bytes received — useful for "Received 3.2 MB from …" UI.
  final int bytes;
}
