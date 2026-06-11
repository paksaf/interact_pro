import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart' as db;
import '../../../core/storage/app_paths.dart';
import '../../../core/utils/logger.dart';
import '../domain/entities.dart'
    show
        CastPageUpdate,
        IncomingCast,
        IncomingPinChallenge,
        IncomingShare,
        ShareKind;
import 'lan_tls.dart' show LanTlsKeypair, buildServerSecurityContext;

/// HTTP server that listens on a random high port for incoming pair and
/// transfer requests from peers. Pairs use a short PIN; everything after
/// is HMAC-signed with the per-peer secret.
///
/// Endpoint contract (all responses JSON unless noted):
///
/// `GET /info`
///   Public. Returns `{ "deviceId": "...", "name": "...", "platform": "..." }`.
///   Used by senders to confirm they're hitting the right peer before pairing.
///
/// `POST /pair/init`           body: `{ "fromDeviceId", "fromName", "fromPlatform" }`
///   Public. Receiver shows a 6-digit PIN to its own user. Returns a
///   `challengeId` the sender includes in `/pair/complete`.
///
/// `POST /pair/complete`       body: `{ "challengeId", "pin" }`
///   Public. If the PIN matches what the receiver displayed, returns the
///   shared HMAC secret. Both sides persist it in their PairedDevices table.
///
/// `POST /receive?kind=pdf|image|video|text&name=<basename>`
///   headers: `X-Peer-Id`, `X-Sig` (HMAC-SHA256 of body)
///   body: raw bytes of the file (any size — buffered in memory; switch to
///         streaming if you ever ship big videos).
///   Authenticated. Saves to disk under the right folder for `kind`,
///   broadcasts an `IncomingShare` event so listeners can auto-open it
///   in the right viewer (PDF reader, image viewer, etc.), returns the
///   resolved local path.
class LanServer {
  LanServer({
    required this.deviceId,
    required this.deviceName,
    required this.appPaths,
    required this.database,
    this.tlsKeypair,
    this.currentUserIdGetter,
  });

  final String deviceId;
  final String deviceName;
  final AppPaths appPaths;
  final db.AppDatabase database;

  /// Optional getter for "which Interact Pro user is currently signed in
  /// on THIS device". When the same user is signed in on both peers
  /// (e.g. their phone and their TV), the pair handshake skips the PIN
  /// step and auto-trusts. Returns null when no user is signed in (then
  /// the regular PIN flow runs).
  final String? Function()? currentUserIdGetter;

  /// Optional self-signed cert + key. When non-null we bind via
  /// `serveSecure` (https://) — receivers expose `https://<ip>:<port>`
  /// URLs and senders pin the fingerprint per peer. When null we fall
  /// back to plain HTTP for backward compatibility (will be removed in
  /// 2.2 once every install has rolled past 2.1).
  final LanTlsKeypair? tlsKeypair;

  /// Convenience for callers building URLs (e.g. /cast/info templates).
  bool get useTls => tlsKeypair != null;
  String get scheme => useTls ? 'https' : 'http';

  HttpServer? _server;
  int? _port;
  int? get port => _port;

  /// Broadcast stream of incoming shares. UI on the receiver side subscribes
  /// to this and navigates to the appropriate viewer when an item lands.
  /// Survives lan-server restarts (controller is created here, not torn down
  /// between starts) so listeners don't have to re-subscribe.
  final StreamController<IncomingShare> _incoming =
      StreamController<IncomingShare>.broadcast();
  Stream<IncomingShare> get incomingShares => _incoming.stream;

  /// Broadcast stream of incoming cast START events — a peer has set
  /// itself up as a cast sender and wants this device to display the
  /// stream. App-level bootstrap navigates to a CastReceiverScreen on
  /// each event.
  final StreamController<IncomingCast> _incomingCasts =
      StreamController<IncomingCast>.broadcast();
  Stream<IncomingCast> get incomingCasts => _incomingCasts.stream;

  /// Broadcast stream of subsequent page updates from a previously
  /// /cast/start-ed peer. The CastReceiverScreen mounted in response
  /// to the IncomingCast subscribes to this and re-fetches the page
  /// image when the sender flips pages.
  final StreamController<CastPageUpdate> _castPageUpdates =
      StreamController<CastPageUpdate>.broadcast();
  Stream<CastPageUpdate> get castPageUpdates => _castPageUpdates.stream;

  /// Active pair handshakes — map by challengeId. PINs are 6 digits, valid
  /// for 60 seconds. After expiry the entry is removed.
  final Map<String, _PendingPair> _pendingPairs = {};

  // ── Cast state ───────────────────────────────────────────────────────
  // Set by the cast service when the user starts a "cast whole document"
  // session. The `/cast/info` and `/cast/page/{n}.png` endpoints serve
  // these to a pull-style receiver (Chromecast Default Media Receiver,
  // DLNA AVTransport, etc.) without re-uploading the PDF anywhere.
  //
  // No auth on these endpoints — they're served only while the LAN server
  // is running, only over the local Wi-Fi, only to receivers we hand the
  // URL to, and only ever expose RENDERED PAGE IMAGES (never raw PDF).
  // If the threat model later needs a token, it slots in cleanly via the
  // same headers the /receive endpoint already uses.
  String? _activeCastPdfPath;
  String? _activeCastTitle;
  int? _activeCastPage;
  int? _activeCastTotalPages;

  /// Hook the UI uses to display the current PIN to the user during a pair.
  /// Legacy — kept for tests + callers that want to react synchronously.
  /// Production UI listens on [incomingPinChallenges] instead.
  void Function(String pin, _PendingPair pending)? onPinChallenge;

  /// Broadcast stream of pair-PIN challenges originating on this device.
  /// Whenever a peer hits POST /pair/init and the server stashes a new
  /// 6-digit PIN in [_pendingPairs], a matching [IncomingPinChallenge]
  /// is emitted here. The UI layer (see `IncomingPinBootstrap` in
  /// `app.dart`) listens and pops a dialog so the user can read the PIN
  /// to the device on the other side.
  ///
  /// Broadcast (not single-subscriber) so test harnesses can observe
  /// without blocking the production listener.
  final StreamController<IncomingPinChallenge> _incomingPinChallenges =
      StreamController<IncomingPinChallenge>.broadcast();
  Stream<IncomingPinChallenge> get incomingPinChallenges =>
      _incomingPinChallenges.stream;

  Future<int> start() async {
    final router = Router()
      ..get('/info', _info)
      ..post('/pair/init', _pairInit)
      ..post('/pair/complete', _pairComplete)
      ..post('/receive', _receive)
      // Web-share portal — lets ANY device with a browser (iPhone without
      // the app, guest laptops…) push a file to this device. Active only
      // while the user has the "Receive from any device" screen open
      // (PIN-gated, see enableWebShare/disableWebShare).
      ..get('/share', _sharePage)
      ..post('/share/upload', _shareUpload)
      // Cast endpoints. Active only while the cast service has registered
      // a PDF — otherwise return 404 / "no active cast".
      ..get('/cast/info', _castInfo)
      ..get('/cast/page/<page|[0-9]+>.png', _castPage)
      // Receiver-side endpoints — a sender pushes /cast/start to tell
      // us "I'm casting; pull from me at $senderHost:$senderPort".
      // /cast/page-changed delivers subsequent page flips. /cast/stop
      // tears down the receiver screen.
      ..post('/cast/start', _castStart)
      ..post('/cast/page-changed', _castPageChanged)
      ..post('/cast/stop', _castStop);

    final pipeline = const Pipeline()
        .addMiddleware(_logRequests)
        .addHandler(router.call);

    // Bind to 0.0.0.0 so peers on the LAN can reach us.
    //
    // We TRY the well-known Pro port 39201 first so the "Connect by IP"
    // manual-entry form on the other device can pre-fill it and Just
    // Work. mDNS-discovered peers learn the actual bound port from the
    // Bonsoir TXT record regardless, so falling back to a random port
    // (0 = OS picks) on collision is safe — discovery still works,
    // only manual-IP-with-default-port stops working.
    //
    // Why 39201: arbitrary high port outside IANA registered ranges,
    // well clear of common dev ports (3000s, 4000s, 5000s, 8000s).
    // Matches `_defaultPort` in nearby_devices_screen.dart's
    // _ManualIpEntry — change in both places if ever moved.
    Future<HttpServer> tryBind(int port) {
      if (tlsKeypair != null) {
        return shelf_io.serve(
          pipeline,
          InternetAddress.anyIPv4,
          port,
          securityContext: buildServerSecurityContext(tlsKeypair!),
        );
      }
      return shelf_io.serve(pipeline, InternetAddress.anyIPv4, port);
    }

    const preferredPort = 39201;
    try {
      _server = await tryBind(preferredPort);
    } on SocketException catch (e) {
      // Port in use (another Pro instance? leftover from a crash?).
      // Fall back to OS-assigned. Log so we know the manual-IP path
      // is degraded for this session.
      appLogger.w(
          'LAN server could not bind preferred port $preferredPort '
          '(${e.osError?.message ?? e.message}); falling back to OS port.',);
      _server = await tryBind(0);
    }
    _port = _server!.port;
    appLogger.i('LAN server listening on $scheme://0.0.0.0:$_port');
    return _port!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }

  // ── Endpoints ────────────────────────────────────────────────────────

  Future<Response> _info(Request req) async {
    final myUserId = currentUserIdGetter?.call();
    return Response.ok(
      jsonEncode({
        'deviceId': deviceId,
        'name': deviceName,
        'platform': _platform(),
        'apiVersion': 3, // bumped — adds same-userId auto-trust
        'tls': useTls,
        if (useTls) 'fingerprintSha256': tlsKeypair!.fingerprintSha256,
        // Hashed userId — never send the raw user id over the LAN.
        // Both peers compute SHA-256(userId) and compare; identical
        // hashes mean same account. We omit when signed-out.
        if (myUserId != null) 'userIdHash': _userIdHash(myUserId),
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// SHA-256 hex of the Interact Pro user id. Used for the "same account"
  /// match in `/pair/init` — never the raw id, so observers on the LAN
  /// can't enumerate user IDs by sniffing /info responses.
  String _userIdHash(String userId) {
    return sha256.convert(utf8.encode('interact-pro:$userId')).toString();
  }

  Future<Response> _pairInit(Request req) async {
    final body = await req.readAsString();
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return Response(400, body: 'Invalid JSON');
    }

    // ── Same-account auto-trust ────────────────────────────────────
    // If the sender's hashed userId matches ours, both peers belong
    // to the same Interact Pro account. Skip the PIN step and pair
    // immediately — phone + TV signed in to one account is the whole
    // point of "share to my own TV without ceremony."
    final fromUserHash = json['fromUserIdHash'] as String?;
    final myUserId = currentUserIdGetter?.call();
    final myHash = myUserId != null ? _userIdHash(myUserId) : null;
    if (fromUserHash != null && myHash != null && fromUserHash == myHash) {
      // Mint the secret + persist immediately; sender treats the
      // returned `secret` field as proof the pair completed.
      final secret = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final secretHex =
          secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fromDeviceId = json['fromDeviceId'] as String? ?? '';
      final fromName = json['fromName'] as String? ?? 'Unknown';
      final fromPlatform = json['fromPlatform'] as String? ?? 'unknown';
      final fromTlsFingerprint = json['fromTlsFingerprint'] as String?;
      await database.upsertPairedDevice(db.PairedDevicesCompanion.insert(
        deviceId: fromDeviceId,
        name: fromName,
        platform: fromPlatform,
        secretHex: secretHex,
        pairedAt: DateTime.now(),
        tlsFingerprintSha256: fromTlsFingerprint == null
            ? const Value.absent()
            : Value(fromTlsFingerprint),
      ),);
      appLogger.i('LAN: auto-trusted pair with $fromName (same account)');
      return Response.ok(
        jsonEncode({
          'autoPaired': true,
          'secret': secretHex,
          if (useTls) 'tlsFingerprintSha256': tlsKeypair!.fingerprintSha256,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final pin = (Random.secure().nextInt(900000) + 100000).toString();
    final challengeId = const Uuid().v4();
    final pending = _PendingPair(
      challengeId: challengeId,
      pin: pin,
      fromDeviceId: json['fromDeviceId'] as String? ?? '',
      fromName: json['fromName'] as String? ?? 'Unknown',
      fromPlatform: json['fromPlatform'] as String? ?? 'unknown',
      // Sender's TLS fingerprint — pinned on the receiver side so future
      // INBOUND requests from the sender (currently none, but reserved)
      // can be auth'd by cert. May be absent on legacy 2.0.x senders.
      fromTlsFingerprint: json['fromTlsFingerprint'] as String?,
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
    );
    _pendingPairs[challengeId] = pending;

    // Surface to UI — legacy callback (tests) + production stream.
    onPinChallenge?.call(pin, pending);
    final challenge = IncomingPinChallenge(
      pin: pin,
      fromDeviceName:
          (json['fromName'] as String?)?.trim().isNotEmpty == true
              ? json['fromName'] as String
              : 'Unknown device',
      fromPlatform: (json['fromPlatform'] as String?) ?? 'unknown',
      expiresAt: pending.expiresAt,
    );
    _incomingPinChallenges.add(challenge);
    appLogger.i('LAN pair: emitted PIN challenge — '
        'PIN=$pin from="${challenge.fromDeviceName}" '
        '(${challenge.fromPlatform}), stream has '
        '${_incomingPinChallenges.hasListener ? "1+ listeners" : "NO LISTENERS"}.',);

    // Auto-cleanup expired entries.
    Timer(const Duration(seconds: 60), () => _pendingPairs.remove(challengeId));

    return Response.ok(
      jsonEncode({
        'challengeId': challengeId,
        // Receiver's own TLS fingerprint — sender pins this on every
        // outbound HTTPS connection. Absent when running plain-HTTP fallback.
        if (useTls) 'tlsFingerprintSha256': tlsKeypair!.fingerprintSha256,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _pairComplete(Request req) async {
    final body = await req.readAsString();
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return Response(400, body: 'Invalid JSON');
    }

    final challengeId = json['challengeId'] as String?;
    final pin = json['pin'] as String?;
    if (challengeId == null || pin == null) return Response(400);

    final pending = _pendingPairs.remove(challengeId);
    if (pending == null || pending.expiresAt.isBefore(DateTime.now())) {
      return Response(410, body: 'Challenge expired');
    }
    if (pending.pin != pin) {
      return Response(403, body: 'PIN mismatch');
    }

    // Generate the shared secret. Both sides persist this — the requester
    // gets it in the response body, we persist it locally.
    final secret = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final secretHex =
        secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    await database.upsertPairedDevice(db.PairedDevicesCompanion.insert(
      deviceId: pending.fromDeviceId,
      name: pending.fromName,
      platform: pending.fromPlatform,
      secretHex: secretHex,
      pairedAt: DateTime.now(),
      tlsFingerprintSha256: pending.fromTlsFingerprint == null
          ? const Value.absent()
          : Value(pending.fromTlsFingerprint!),
    ),);

    return Response.ok(
      jsonEncode({'secret': secretHex}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _receive(Request req) async {
    final peerId = req.headers['X-Peer-Id'];
    final sig = req.headers['X-Sig'];
    if (peerId == null || sig == null) return Response(401);

    final paired = await database.pairedDevice(peerId);
    if (paired == null) return Response(403, body: 'Not paired');

    // ── Resolve target folder + extension from the kind hint ────────────
    // Default to PDF for backward compat with senders that don't pass kind.
    final kindRaw = (req.url.queryParameters['kind'] ?? 'pdf').toLowerCase();
    final kind = ShareKind.parse(kindRaw);
    final suppliedName = req.url.queryParameters['name'];
    final ts = DateTime.now().millisecondsSinceEpoch;
    final safeBase = (suppliedName ?? 'lan_$ts')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final ext = p.extension(safeBase).isNotEmpty
        ? p.extension(safeBase)
        : kind.defaultExtension;
    final stem = p.basenameWithoutExtension(safeBase);
    final filename = '$stem$ext';

    // PDFs go in the PDF library so they appear in Recents; everything
    // else lands in the dedicated `incoming/` folder until per-kind
    // viewers / libraries (image, video, text) ship.
    //
    // Phase 3 carve-out: signature-chain sidecars (`*.sigchain.json`)
    // need to land NEXT TO their PDF so the existing
    // `SigchainSidecar.read(pdfPath)` API finds them via the
    // `<pdfPath>.sigchain.json` suffix. They arrive as `kind=other`
    // but with a filename ending in `.sigchain.json` — the filename
    // is the routing signal, not the kind. Sender pairs PDF+sidecar
    // names by convention: `Foo.pdf` ships, then `Foo.pdf.sigchain.json`.
    final isSigchainSidecar =
        kind == ShareKind.other && filename.endsWith('.sigchain.json');
    final destPath = (kind == ShareKind.pdf || isSigchainSidecar)
        ? appPaths.pdfPathFor(filename)
        : appPaths.incomingPathFor(filename);

    await Directory(p.dirname(destPath)).create(recursive: true);

    // ── Stream the body to disk while computing HMAC over the same bytes.
    //
    // Old code buffered the entire body in memory before writing — fine for
    // PDFs, OOMs the process on a 500MB video. Now: write to a `.partial`
    // file, update the HMAC in-place per chunk, then atomically rename to
    // the final name once both succeed. If the signature doesn't match,
    // delete the `.partial` and respond 403 — caller never sees the file.
    final partialPath = '$destPath.partial';
    final partial = File(partialPath);
    final sink = partial.openWrite();
    final digestCapture = _DigestCapture();
    final hmacSink = Hmac(sha256, _hexToBytes(paired.secretHex))
        .startChunkedConversion(digestCapture);
    int totalBytes = 0;

    try {
      await for (final chunk in req.read()) {
        sink.add(chunk);
        hmacSink.add(chunk);
        totalBytes += chunk.length;
      }
      await sink.flush();
      await sink.close();
      hmacSink.close();
    } catch (e, st) {
      appLogger.e('LAN /receive: stream write failed', error: e, stackTrace: st);
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return Response.internalServerError(body: 'Stream write failed');
    }

    final expected = digestCapture.captured?.toString() ?? '';
    if (expected != sig) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return Response(403, body: 'Bad signature');
    }

    // Atomic rename — file becomes visible to viewers only after the
    // signature passes, so half-written files never get auto-opened.
    await partial.rename(destPath);

    await database.markPairedDeviceSeen(peerId);

    // Notify any in-app listener (typically the router-attached watcher in
    // app.dart) so it opens the right viewer immediately.
    _incoming.add(IncomingShare(
      path: destPath,
      kind: kind,
      fromPeerId: peerId,
      fromName: paired.name,
      receivedAt: DateTime.now(),
      bytes: totalBytes,
    ),);

    return Response.ok(
      jsonEncode({
        'path': destPath,
        'received': totalBytes,
        'kind': kind.name,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // ── Web share (receive from ANY browser, no app needed) ─────────────
  //
  // Product req 2026-06-10: "if I have an iPhone (without Interact Pro)
  // and want to share a document on the TV, Interact Pro shall receive
  // it and show it." iPhones can't run our pair protocol and stock iOS
  // has no DLNA sender, so the lowest-friction universal channel is the
  // browser: the receiving device (TV) shows a QR + URL + 6-digit PIN;
  // the sender scans the QR, picks a file, and the upload lands in the
  // same IncomingShare pipeline as app-to-app transfers (auto-opens in
  // the right viewer).
  //
  // Security model: only active while the user is LOOKING at the
  // receive screen (enable/disable bracket the screen's lifecycle),
  // gated by a single-session random PIN, LAN-only, files land in the
  // same sandboxed folders as paired transfers. No HMAC — possession of
  // the on-screen PIN IS the proof of physical presence.

  String? _webSharePin;
  bool get webShareActive => _webSharePin != null;

  /// Activate the portal; returns the PIN to display. Idempotent-ish:
  /// re-enabling mints a fresh PIN (old links stop working).
  String enableWebShare() {
    final pin = (Random.secure().nextInt(900000) + 100000).toString();
    _webSharePin = pin;
    appLogger.i('LAN web-share: ENABLED');
    return pin;
  }

  void disableWebShare() {
    _webSharePin = null;
    appLogger.i('LAN web-share: disabled');
  }

  static const int _webShareMaxBytes = 512 * 1024 * 1024; // 512 MB

  static ShareKind _kindForExtension(String ext) {
    return switch (ext.toLowerCase()) {
      '.pdf' => ShareKind.pdf,
      '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' || '.heic' ||
      '.heif' || '.bmp' => ShareKind.image,
      '.mp4' || '.mov' || '.mkv' || '.webm' || '.3gp' => ShareKind.video,
      '.txt' || '.md' => ShareKind.text,
      '.doc' || '.docx' || '.rtf' || '.xls' || '.xlsx' || '.ppt' ||
      '.pptx' || '.pages' || '.numbers' || '.key' => ShareKind.document,
      _ => ShareKind.other,
    };
  }

  Future<Response> _sharePage(Request req) async {
    if (!webShareActive) {
      return Response.notFound(
        'Sharing is not active. Open "Receive from any device" '
        'on the Interact Pro screen first.',
      );
    }
    // PIN may ride in via the QR URL (?pin=) so scanners skip typing it.
    final prefill = req.url.queryParameters['pin'] ?? '';
    final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Send to $deviceName — Interact Pro</title>
<style>
  body { font-family: -apple-system, Roboto, sans-serif; background:#101418;
         color:#eee; margin:0; padding:24px; }
  .card { max-width:420px; margin:8vh auto; background:#1b2128; padding:24px;
          border-radius:16px; }
  h1 { font-size:1.25rem; margin:0 0 4px; }
  p  { color:#9ab; font-size:.9rem; }
  input[type=text] { width:100%; box-sizing:border-box; font-size:1.3rem;
          letter-spacing:.3em; text-align:center; padding:10px; margin:8px 0 16px;
          border-radius:10px; border:1px solid #345; background:#0d1116; color:#fff; }
  input[type=file] { width:100%; margin:8px 0 16px; color:#9ab; }
  button { width:100%; padding:14px; font-size:1rem; border:0; border-radius:12px;
          background:#2e7d32; color:#fff; font-weight:600; }
  button:disabled { background:#2a3138; color:#678; }
  #st { margin-top:14px; text-align:center; font-size:.95rem; min-height:1.2em; }
  progress { width:100%; }
</style>
</head>
<body>
<div class="card">
  <h1>Send a file to “$deviceName”</h1>
  <p>Enter the PIN shown on the receiving screen, pick a file, send.</p>
  <input id="pin" type="text" inputmode="numeric" maxlength="6"
         placeholder="••••••" value="$prefill">
  <input id="f" type="file">
  <button id="go" onclick="send()">Send</button>
  <div id="st"></div>
</div>
<script>
async function send() {
  const f = document.getElementById('f').files[0];
  const pin = document.getElementById('pin').value.trim();
  const st = document.getElementById('st');
  const go = document.getElementById('go');
  if (!f) { st.textContent = 'Pick a file first.'; return; }
  if (pin.length !== 6) { st.textContent = 'Enter the 6-digit PIN.'; return; }
  go.disabled = true; st.textContent = 'Sending…';
  try {
    const r = await fetch('/share/upload?pin=' + encodeURIComponent(pin) +
        '&name=' + encodeURIComponent(f.name), { method:'POST', body:f });
    if (r.ok) { st.textContent = '✓ Sent — check the screen.'; }
    else { st.textContent = 'Failed: ' + (await r.text()); go.disabled = false; }
  } catch (e) { st.textContent = 'Network error: ' + e; go.disabled = false; }
}
</script>
</body>
</html>
''';
    return Response.ok(html,
        headers: {'Content-Type': 'text/html; charset=utf-8'},);
  }

  Future<Response> _shareUpload(Request req) async {
    final pin = _webSharePin;
    if (pin == null) return Response(403, body: 'Sharing not active');
    if (req.url.queryParameters['pin'] != pin) {
      return Response(403, body: 'Wrong PIN');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final suppliedName = req.url.queryParameters['name'];
    final safeBase = (suppliedName == null || suppliedName.trim().isEmpty
            ? 'web_$ts'
            : suppliedName)
        .replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final ext = p.extension(safeBase);
    final kind = _kindForExtension(ext);
    final filename =
        '${p.basenameWithoutExtension(safeBase)}${ext.isEmpty ? '.bin' : ext}';
    final destPath = kind == ShareKind.pdf
        ? appPaths.pdfPathFor(filename)
        : appPaths.incomingPathFor(filename);
    await Directory(p.dirname(destPath)).create(recursive: true);

    final partial = File('$destPath.partial');
    final sink = partial.openWrite();
    int totalBytes = 0;
    try {
      await for (final chunk in req.read()) {
        totalBytes += chunk.length;
        if (totalBytes > _webShareMaxBytes) {
          throw const FileSystemException('Upload exceeds 512 MB limit');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } catch (e, st) {
      appLogger.e('LAN /share/upload failed', error: e, stackTrace: st);
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return Response(413, body: 'Upload failed: $e');
    }
    if (totalBytes == 0) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return Response(400, body: 'Empty upload');
    }
    await partial.rename(destPath);

    final remote =
        (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)
            ?.remoteAddress
            .address;
    _incoming.add(IncomingShare(
      path: destPath,
      kind: kind,
      fromPeerId: 'web:${remote ?? 'unknown'}',
      fromName: 'Web upload${remote == null ? '' : ' ($remote)'}',
      receivedAt: DateTime.now(),
      bytes: totalBytes,
    ),);
    appLogger.i('LAN web-share: received $filename ($totalBytes bytes) '
        'from ${remote ?? 'unknown'}');
    return Response.ok(jsonEncode({'ok': true, 'received': totalBytes}),
        headers: {'Content-Type': 'application/json'},);
  }

  // ── Cast: public API ─────────────────────────────────────────────────
  // The cast service mutates these to expose the current PDF + page over
  // the cast endpoints. Receivers pull `/cast/info` once, then poll
  // `/cast/page/{n}.png` as the user navigates.

  /// Register a PDF as the active cast source. Receivers can then GET
  /// `http://<this-device>:<port>/cast/page/N.png` for any 1-based page.
  ///
  /// [pdfPath] must point at a readable file. [documentTitle] is shown
  /// to receivers via `/cast/info`. [totalPages] is computed lazily by
  /// the page handler if null, so callers can pass it eagerly when known
  /// to save the receiver one round-trip.
  void setActiveCastPdf({
    required String pdfPath,
    required String documentTitle,
    int? totalPages,
    int currentPage = 1,
  }) {
    _activeCastPdfPath = pdfPath;
    _activeCastTitle = documentTitle;
    _activeCastTotalPages = totalPages;
    _activeCastPage = currentPage;
    appLogger.i('LAN cast active: $documentTitle ($pdfPath) @ p$currentPage');
  }

  /// Update the "current page" pointer the receiver should be displaying.
  /// Called by the cast service in response to viewer page changes.
  void setActiveCastPage(int page) {
    if (_activeCastPdfPath == null) return;
    _activeCastPage = page;
  }

  /// Tear down the cast registration. After this `/cast/info` returns 404.
  void clearActiveCast() {
    _activeCastPdfPath = null;
    _activeCastTitle = null;
    _activeCastPage = null;
    _activeCastTotalPages = null;
  }

  /// Build the public URL a receiver should use to fetch [page]. Returns
  /// null when there's no active cast or the LAN server isn't bound yet.
  String? castPageUrl({required int page, required String localIp}) {
    final port = _port;
    if (port == null || _activeCastPdfPath == null) return null;
    return 'http://$localIp:$port/cast/page/$page.png';
  }

  /// Sibling URL for `/cast/info`.
  String? castInfoUrl({required String localIp}) {
    final port = _port;
    if (port == null || _activeCastPdfPath == null) return null;
    return 'http://$localIp:$port/cast/info';
  }

  // ── Cast: handlers ───────────────────────────────────────────────────

  Future<Response> _castInfo(Request req) async {
    final pdfPath = _activeCastPdfPath;
    if (pdfPath == null) {
      return Response.notFound(jsonEncode({'error': 'No active cast'}),
          headers: {'Content-Type': 'application/json'},);
    }
    int total = _activeCastTotalPages ?? 0;
    if (total == 0) {
      // Lazy page-count only on first request; cheap with pdfx.
      try {
        final doc = await pdfx.PdfDocument.openFile(pdfPath);
        total = doc.pagesCount;
        _activeCastTotalPages = total;
        await doc.close();
      } catch (e) {
        appLogger.w('cast info: page-count failed: $e');
      }
    }
    return Response.ok(
      jsonEncode({
        'title': _activeCastTitle,
        'currentPage': _activeCastPage,
        'totalPages': total,
        'pageUrlTemplate': '/cast/page/{n}.png',
      }),
      headers: {
        'Content-Type': 'application/json',
        // Hint to receivers that this object will change as the user
        // navigates — they should poll /cast/info, not cache it.
        'Cache-Control': 'no-store',
      },
    );
  }

  /// Receiver-side handler. Sender POSTs:
  ///   { senderDeviceId, senderName, senderHost, senderPort,
  ///     documentTitle, currentPage, totalPages }
  /// We emit an `IncomingCast` event; the app-level bootstrap navigates
  /// to a CastReceiverScreen that polls `http://$senderHost:$senderPort`.
  Future<Response> _castStart(Request req) async {
    try {
      final body = await req.readAsString();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final senderHost = j['senderHost'] as String?;
      final senderPort = j['senderPort'] as int?;
      if (senderHost == null || senderPort == null) {
        return Response(400,
            body: jsonEncode({'error': 'senderHost + senderPort required'}),
            headers: {'Content-Type': 'application/json'},);
      }
      _incomingCasts.add(IncomingCast(
        senderDeviceId: (j['senderDeviceId'] as String?) ?? 'unknown',
        senderName: (j['senderName'] as String?) ?? 'A device',
        senderHost: senderHost,
        senderPort: senderPort,
        documentTitle:
            (j['documentTitle'] as String?) ?? 'Untitled document',
        currentPage: (j['currentPage'] as int?) ?? 1,
        totalPages: (j['totalPages'] as int?) ?? 0,
        startedAt: DateTime.now(),
      ),);
      appLogger.i(
        'LAN /cast/start: ${j['senderName']} → us '
        '($senderHost:$senderPort, doc="${j['documentTitle']}")',
      );
      return Response.ok(
        jsonEncode({'ok': true}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e, st) {
      appLogger.e('LAN /cast/start failed', error: e, stackTrace: st);
      return Response.internalServerError(
        body: jsonEncode({'error': '$e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// Receiver-side handler for sender page flips. Body:
  ///   { senderDeviceId, currentPage }
  Future<Response> _castPageChanged(Request req) async {
    try {
      final j = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      _castPageUpdates.add(CastPageUpdate(
        senderDeviceId: (j['senderDeviceId'] as String?) ?? 'unknown',
        currentPage: j['currentPage'] as int?,
      ),);
      return Response.ok(jsonEncode({'ok': true}),
          headers: {'Content-Type': 'application/json'},);
    } catch (e) {
      return Response(400, body: '$e');
    }
  }

  /// Receiver-side handler for sender ending the cast. Same shape as
  /// /cast/page-changed but with `currentPage: null` — keeps a single
  /// listener path on the receiver UI.
  Future<Response> _castStop(Request req) async {
    try {
      final j = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      _castPageUpdates.add(CastPageUpdate(
        senderDeviceId: (j['senderDeviceId'] as String?) ?? 'unknown',
        currentPage: null,
      ),);
      return Response.ok(jsonEncode({'ok': true}),
          headers: {'Content-Type': 'application/json'},);
    } catch (e) {
      return Response(400, body: '$e');
    }
  }

  Future<Response> _castPage(Request req, String pageStr) async {
    final pdfPath = _activeCastPdfPath;
    if (pdfPath == null) {
      return Response.notFound('No active cast');
    }
    final pageNum = int.tryParse(pageStr);
    if (pageNum == null || pageNum < 1) {
      return Response(400, body: 'Bad page number');
    }

    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(pdfPath);
      if (pageNum > doc.pagesCount) {
        return Response(404, body: 'Page out of range');
      }
      final page = await doc.getPage(pageNum);
      // 2.0× scale matches the share-sheet renderer — receivers tend to
      // be 1080p TVs where this hits a sweet spot of legibility vs. size.
      final rendered = await page.render(
        width: page.width * 2.0,
        height: page.height * 2.0,
        format: pdfx.PdfPageImageFormat.png,
      );
      await page.close();
      if (rendered == null) {
        return Response.internalServerError(body: 'Render failed');
      }
      return Response.ok(
        rendered.bytes,
        headers: {
          'Content-Type': 'image/png',
          'Content-Length': rendered.bytes.length.toString(),
          // The receiver should refetch on every navigation — the URL
          // path encodes the page number, but a smart proxy could still
          // cache. Disable to keep things accurate.
          'Cache-Control': 'no-store',
        },
      );
    } catch (e, st) {
      appLogger.e('cast page render failed', error: e, stackTrace: st);
      return Response.internalServerError(body: 'Render error');
    } finally {
      await doc?.close();
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  Middleware get _logRequests => (Handler inner) {
        return (Request req) async {
          final sw = Stopwatch()..start();
          final resp = await inner(req);
          appLogger.i('LAN ${req.method} ${req.url} → ${resp.statusCode} '
              '(${sw.elapsedMilliseconds}ms)');
          return resp;
        };
      };

  String _platform() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}

/// Tiny `Sink<Digest>` that just remembers the single digest emitted by
/// `Hmac.startChunkedConversion`. Avoids pulling in `package:convert` for
/// the common-case "I want the final HMAC value out of a chunked feed".
class _DigestCapture implements Sink<Digest> {
  Digest? captured;

  @override
  void add(Digest data) {
    captured = data;
  }

  @override
  void close() {}
}

class _PendingPair {
  _PendingPair({
    required this.challengeId,
    required this.pin,
    required this.fromDeviceId,
    required this.fromName,
    required this.fromPlatform,
    required this.expiresAt,
    this.fromTlsFingerprint,
  });

  final String challengeId;
  final String pin;
  final String fromDeviceId;
  final String fromName;
  final String fromPlatform;
  final DateTime expiresAt;

  /// Sender's TLS cert SHA-256 fingerprint, if it offered one. Stored on
  /// the receiver in PairedDevices for symmetry; not currently consumed
  /// because all transfers flow sender→receiver, but reserved for future
  /// receiver→sender flows (e.g. seeking remote signature).
  final String? fromTlsFingerprint;
}

final lanServerProvider = Provider<LanServer?>((ref) {
  // The server needs a stable device id + name, async paths, and the db.
  // The actual instance is created lazily by [LanRepository.boot] so we
  // can read those off `appPathsProvider.future` etc.
  return null;
});
