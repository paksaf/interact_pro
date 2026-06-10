import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/failures.dart';
import '../../../core/storage/app_database.dart' as db;
import '../../../core/storage/app_paths.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../domain/entities.dart';
import '../../signatures/data/sigchain_sidecar.dart'
    show sidecarPathIfExists;
import 'lan_discovery_service.dart';
import 'lan_server.dart';
import 'lan_tls.dart' show LanTlsKeypair, buildPinnedClient, ensureKeypair;
export '../domain/entities.dart'
    show
        CastPageUpdate,
        IncomingCast,
        IncomingPinChallenge,
        IncomingShare,
        ShareKind;

/// Single facade the UI talks to. Combines discovery, the local server,
/// and the trust store so screens don't juggle three providers.
class LanRepository {
  LanRepository({
    required this.discovery,
    required this.server,
    required this.database,
    required this.deviceId,
    required this.deviceName,
    this.currentUserIdGetter,
  });

  final LanDiscoveryService discovery;
  final LanServer server;
  final db.AppDatabase database;
  final String deviceId;
  final String deviceName;

  /// Same getter the LanServer uses — returns the currently signed-in
  /// Interact Pro user id, or null if signed out. Used to compute the
  /// `fromUserIdHash` field sent during pair init for auto-trust.
  final String? Function()? currentUserIdGetter;

  /// Hash a userId the same way the server side does (must match — it's
  /// how peers recognise "same account").
  static String _userIdHash(String userId) {
    return sha256.convert(utf8.encode('interact-pro:$userId')).toString();
  }

  /// Convert whatever string Bonsoir handed us (numeric IP, `.local`
  /// mDNS hostname, or IPv6 link-local with a `%scope` suffix) into a
  /// numeric IP that `dart:io` Socket can actually reach.
  ///
  /// Why this exists: Bonsoir's `ResolvedBonsoirService.host` reflects
  /// the underlying platform NSD result. On some Android firmwares
  /// (notably Sony Bravia VH21 + several Samsung phones on Wi-Fi 6
  /// routers) NSD returns a `.local` mDNS hostname like
  /// `Pixel-8-Pro.local` instead of a numeric IP — Dart's HTTP / Socket
  /// stack cannot resolve `.local` (no native mDNS resolver) so every
  /// pair / send call fails with `SocketException: Failed host lookup`,
  /// which Android then surfaces in the UI as the generic "cant be
  /// found" toast the user reported on 2026-05-13.
  ///
  /// Strategy:
  ///   1. If the input is already a numeric IP (`InternetAddress.tryParse`),
  ///      return it unchanged.
  ///   2. Otherwise, call `InternetAddress.lookup(host)` with a tight
  ///      2-second timeout. Prefer IPv4; fall back to IPv6 only if
  ///      that's all we got. Strip any `%scope` suffix the OS attaches
  ///      to link-local IPv6 — Dart's HTTP client doesn't handle it.
  ///   3. On total failure return null — caller surfaces a user-friendly
  ///      "couldn't reach peer" message instead of leaking the lookup
  ///      exception.
  static Future<String?> _resolveLanHost(String host) async {
    final raw = host.trim();
    if (raw.isEmpty) return null;

    // Already numeric? Strip any `%scope` (IPv6 link-local) and accept.
    final stripped = raw.contains('%') ? raw.substring(0, raw.indexOf('%')) : raw;
    if (InternetAddress.tryParse(stripped) != null) return stripped;

    try {
      final results = await InternetAddress.lookup(raw)
          .timeout(const Duration(seconds: 2));
      if (results.isEmpty) return null;
      // Prefer IPv4 — wider router/firewall compat than IPv6 link-local.
      final v4 = results.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => results.first,
      );
      // Skip unusable link-local IPv6 (fe80::/10) — connect() against
      // one of these without a scope id fails. If that's all we have,
      // surface as "couldn't reach" rather than handing it back.
      final addr = v4.address;
      if (addr.toLowerCase().startsWith('fe80:')) return null;
      return addr;
    } catch (e) {
      appLogger.w('LAN: host lookup for "$raw" failed: $e');
      return null;
    }
  }

  /// Boot the whole stack — local server first (so we have a port), then
  /// broadcast that port over mDNS, then start browsing.
  Future<Result<void>> start() async {
    try {
      final port = await server.start();
      final br = await discovery.startBroadcasting(
        deviceId: deviceId,
        name: deviceName,
        port: port,
      );
      if (br.isErr) return br;
      final browseResult = await discovery.startBrowsing();
      // Auto-reconnect (#255 — 2026-05-20): on launch, ping every
      // paired device at its cached host:port to refresh presence.
      // Without this, users land on Nearby Devices to find their TV
      // listed as "last seen 1d ago" even when it's powered on and
      // on the same WiFi — discovery hadn't yet caught up. This
      // doesn't block startup; runs in the background.
      unawaited(_pingAllPairedDevices());
      return browseResult;
    } catch (e, st) {
      appLogger.e('LAN start failed', error: e, stackTrace: st);
      return Result<void>.err(LanFailure('Could not start LAN', cause: e));
    }
  }

  /// Ping every paired device at its cached host:port (from
  /// SharedPreferences `lan.peer.host.<id>` + `lan.peer.port.<id>`)
  /// and refresh the cache when one responds. Fire-and-forget — UI
  /// surfaces results through the existing peers() stream because
  /// _cachePeerLocation() writes to the same prefs keys peers() reads.
  ///
  /// We ping `/info` (lan_server.dart endpoint that returns name +
  /// device-id JSON without auth). 2-second timeout so an unreachable
  /// device doesn't hold up the others.
  Future<void> _pingAllPairedDevices() async {
    try {
      // AppDatabase doesn't expose a one-shot allPaired(), but the
      // watchPairedDevices() stream emits the current snapshot
      // immediately, so .first gives us the same result without
      // adding a new DB method.
      final paired = await database
          .watchPairedDevices()
          .first
          .timeout(const Duration(seconds: 1), onTimeout: () => const []);
      if (paired.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final client = http.Client();
      try {
        await Future.wait(
          paired.map((p) async {
            final host = prefs.getString('lan.peer.host.${p.deviceId}');
            final port = prefs.getInt('lan.peer.port.${p.deviceId}');
            if (host == null || port == null) return;
            // /info is the only LAN endpoint that's unauthenticated
            // and returns immediately — perfect for presence.
            for (final scheme in const ['https', 'http']) {
              try {
                final uri = Uri.parse('$scheme://$host:$port/info');
                final res = await client
                    .get(uri, headers: {'Accept': 'application/json'})
                    .timeout(const Duration(seconds: 2));
                if (res.statusCode == 200) {
                  // Touch the prefs to refresh the "last reachable" time
                  // so the UI can show "online" vs "offline" pills.
                  await prefs.setInt(
                    'lan.peer.lastSeen.${p.deviceId}',
                    DateTime.now().millisecondsSinceEpoch,
                  );
                  appLogger.i(
                    'Auto-reconnect: ${p.name} online at $host:$port',
                  );
                  return;
                }
              } catch (_) {
                // Try next scheme.
              }
            }
          }),
        );
      } finally {
        client.close();
      }
    } catch (e) {
      // Best-effort — don't crash startup on a ping pass.
      appLogger.w('Auto-reconnect ping pass failed: $e');
    }
  }

  Future<void> stop() async {
    await discovery.stopBrowsing();
    await discovery.stopBroadcasting();
    await server.stop();
  }

  /// Stream of peers cross-referenced against the trust store so the UI
  /// can render paired peers differently from strangers.
  ///
  /// Combines two sources:
  ///   1. ACTIVE — peers Bonsoir/mDNS just announced; have a definitive
  ///      host/port for this very moment.
  ///   2. PAIRED-OFFLINE — devices in our drift trust store whose
  ///      host+port we cached at pair time. Surfaced when Bonsoir is
  ///      blind (common on consumer routers with multicast filtering)
  ///      so the Send-to-Device sheet still lists them. Without this
  ///      branch, a user who paired via "Connect by IP" can't see the
  ///      TV in the send list moments later because discovery never
  ///      caught up — even though we have a perfectly good route stored.
  ///
  /// Emits whenever EITHER discovery or the paired table changes, so
  /// new pairs show up immediately and unpaired devices disappear.
  Stream<List<NearbyDevice>> peers() async* {
    final ctrl = StreamController<List<NearbyDevice>>();
    var lastHits = <NearbyDevice>[];
    var lastPaired = <db.PairedDevice>[];

    Future<void> emit() async {
      final byId = <String, NearbyDevice>{};
      // Pair lookup for naming + flagging discovered peers.
      final pairedById = <String, db.PairedDevice>{
        for (final p in lastPaired) p.deviceId: p,
      };
      // First, layer in active discovery hits — these have authoritative
      // current host/port.
      for (final d in lastHits) {
        byId[d.deviceId] = NearbyDevice(
          deviceId: d.deviceId,
          name: pairedById[d.deviceId]?.name ?? d.name,
          host: d.host,
          port: d.port,
          platform: d.platform,
          appVersion: d.appVersion,
          isPaired: pairedById.containsKey(d.deviceId),
        );
      }
      // Then layer in paired-offline using cached host/port. If a
      // paired peer is also in discovery we keep the discovery entry
      // (just synced above). If not, synthesize from cache.
      final prefs = await SharedPreferences.getInstance();
      for (final p in lastPaired) {
        if (byId.containsKey(p.deviceId)) continue;
        final host = prefs.getString('lan.peer.host.${p.deviceId}');
        final port = prefs.getInt('lan.peer.port.${p.deviceId}');
        if (host == null || port == null) continue;
        byId[p.deviceId] = NearbyDevice(
          deviceId: p.deviceId,
          name: p.name,
          host: host,
          port: port,
          platform: p.platform,
          appVersion: 'unknown',
          isPaired: true,
        );
      }
      if (!ctrl.isClosed) ctrl.add(byId.values.toList());
    }

    final discSub = discovery.peers().listen((hits) {
      lastHits = hits;
      unawaited(emit());
    });
    final pairSub = database.watchPairedDevices().listen((paired) {
      lastPaired = paired;
      unawaited(emit());
    });
    // Initial emit so subscribers don't sit waiting for the first
    // discovery hit (which never comes on multicast-blocked Wi-Fi).
    unawaited(emit());

    ctrl.onCancel = () async {
      await discSub.cancel();
      await pairSub.cancel();
    };
    yield* ctrl.stream;
  }

  /// Cache a paired peer's reachable host+port keyed by deviceId. Used
  /// by [peers] above to surface paired-but-undiscovered devices in the
  /// Send sheet. Called from [pair] after a successful handshake so the
  /// next session can find the device without depending on Bonsoir.
  Future<void> _cachePeerLocation(
      String deviceId, String host, int port,) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lan.peer.host.$deviceId', host);
      await prefs.setInt('lan.peer.port.$deviceId', port);
    } catch (e, st) {
      appLogger.w('cachePeerLocation failed', error: e, stackTrace: st);
    }
  }

  Stream<List<db.PairedDevice>> pairedDevices() => database.watchPairedDevices();

  Future<Result<void>> unpair(String deviceId) async {
    try {
      await database.unpairDevice(deviceId);
      return const Result<void>.ok(null);
    } catch (e) {
      return Result<void>.err(LanFailure('Unpair failed', cause: e));
    }
  }

  /// Send a file to a paired peer. Authenticates with the per-peer HMAC
  /// secret. The receiver writes to a folder appropriate for [kind] and
  /// fires an `IncomingShare` event so its UI can auto-open the file.
  ///
  /// **Transport:**
  ///   - If the peer was paired with a TLS fingerprint (post-2.1 pair) →
  ///     HTTPS with cert pinning. Cert mismatch → outright reject.
  ///   - If the paired row has no fingerprint (legacy 2.0.x pair) → falls
  ///     back to plain HTTP for backward compat. User can re-pair to upgrade.
  ///
  /// **Streaming:**
  ///   - The body is streamed from disk via `file.openRead()` — large videos
  ///     never load into memory. Matches the receiver's streamed write path.
  ///
  /// [kind] defaults to `pdf` for backward compatibility with the original
  /// 1.0 send signature; pass `image` / `video` / `text` when sharing
  /// non-PDF content from the OS share sheet (Samsung Gallery, etc.).
  ///
  /// [filename] is purely cosmetic — used as the on-disk basename on the
  /// receiver. If null we mint `lan_<timestamp>.<ext>`. If you supply one,
  /// keep it short and ASCII; the receiver sanitises but doesn't transliterate.
  Future<Result<void>> send({
    required NearbyDevice peer,
    required File file,
    ShareKind kind = ShareKind.pdf,
    String? filename,
  }) async {
    try {
      final paired = await database.pairedDevice(peer.deviceId);
      if (paired == null) {
        return Result<void>.err(
          PairingFailure('Pair with ${peer.name} before sending.'),
        );
      }

      // Same `.local` / IPv6-link-local trap as pair() — resolve once
      // up front so failure surfaces as a clear user-facing message
      // instead of a raw SocketException.
      final resolvedHost = await _resolveLanHost(peer.host);
      if (resolvedHost == null) {
        return Result<void>.err(LanFailure(
          'Could not reach ${peer.name} at ${peer.host}. '
          'Both devices need to be on the same Wi-Fi.',
        ),);
      }

      // HMAC over the raw file bytes. Computed up-front because `http`
      // requires a final body length; for true streaming HMAC we'd switch
      // to a chunked Sink over the read stream — TODO for >1GB transfers.
      final body = await file.readAsBytes();
      final sig =
          Hmac(sha256, _hexToBytes(paired.secretHex)).convert(body).toString();

      final query = <String, String>{
        'kind': kind.wireName,
        if (filename != null && filename.isNotEmpty) 'name': filename,
      };
      final useHttps = paired.tlsFingerprintSha256 != null;
      final uri = Uri(
        scheme: useHttps ? 'https' : 'http',
        host: resolvedHost,
        port: peer.port,
        path: '/receive',
        queryParameters: query,
      );

      // Build the right client per pair: pinned HTTPS for post-2.1 pairs,
      // plain HTTP for legacy pairs that haven't been re-paired yet.
      final client = useHttps
          ? http_io.IOClient(buildPinnedClient(paired.tlsFingerprintSha256!))
          : http.Client();

      try {
        final resp = await client.post(
          uri,
          headers: {
            'X-Peer-Id': deviceId,
            'X-Sig': sig,
            'Content-Type': 'application/octet-stream',
          },
          body: body,
        );
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          return Result<void>.err(
            LanFailure('Peer rejected transfer (${resp.statusCode}): ${resp.body}'),
          );
        }
        await database.markPairedDeviceSeen(peer.deviceId);
        return const Result<void>.ok(null);
      } on HandshakeException catch (e) {
        // Most likely cert pinning rejection — the fingerprint we stored at
        // pair time doesn't match what the peer is presenting. Either the
        // peer rotated certs (legitimate) or someone's MITMing (not).
        appLogger.w('LAN send: TLS handshake failed: ${e.message}');
        return Result<void>.err(
          LanFailure(
            'Could not securely connect to ${peer.name}. '
            'If you trust the device, unpair and re-pair to refresh its key.',
            cause: e,
          ),
        );
      } finally {
        client.close();
      }
    } catch (e, st) {
      appLogger.e('LAN send failed', error: e, stackTrace: st);
      return Result<void>.err(LanFailure('Transfer failed', cause: e));
    }
  }

  /// Phase 3: ship a signed PDF to the next signer in the chain along
  /// with its `.sigchain.json` sidecar. The sidecar carries the public
  /// keys + signature chain so the receiver can verify and continue
  /// signing without prior pairing of the original signer's identity.
  ///
  /// Two-call implementation: PDF first (kind=pdf), sidecar second
  /// (kind=other, filename=`<pdf-basename>.pdf.sigchain.json`). The
  /// server-side detects the `.sigchain.json` extension and parks the
  /// sidecar next to its PDF in the recents library so the existing
  /// `SigchainSidecar.read()` API finds it transparently.
  ///
  /// If the sidecar transfer fails after the PDF transfer succeeds we
  /// log + return ok — the receiver still has the PDF and can verify
  /// over a re-send. Failing both halves on a sidecar hiccup would
  /// frustrate the user for a verification-only artifact.
  Future<Result<void>> sendSignedDocument({
    required NearbyDevice peer,
    required String pdfPath,
    String? suggestedName,
  }) async {
    final pdfFile = File(pdfPath);
    if (!await pdfFile.exists()) {
      return Result<void>.err(
        LanFailure('PDF not found at $pdfPath'),
      );
    }

    // Determine the canonical basename the receiver should see — the
    // sidecar filename derives from this so the matching is reliable
    // regardless of whether sender + receiver normalized the path the
    // same way.
    final pdfBasename = suggestedName?.trim().isNotEmpty == true
        ? suggestedName!.trim()
        : _basename(pdfPath);

    final pdfRes = await send(
      peer: peer,
      file: pdfFile,
      kind: ShareKind.pdf,
      filename: pdfBasename,
    );
    if (pdfRes.isErr) return pdfRes;

    // Sidecar is optional — only ship one if it exists locally. The
    // receiver doesn't need it for the PDF to be readable; it's only
    // required for verification + continuation of the signature chain.
    final sidecar = sidecarPathIfExists(pdfPath);
    if (sidecar == null) return const Result<void>.ok(null);

    final sidecarRes = await send(
      peer: peer,
      file: File(sidecar),
      kind: ShareKind.other,
      // Naming convention: `<pdf-basename>.sigchain.json`. Server uses
      // the `.sigchain.json` extension as the routing signal.
      filename: '$pdfBasename.sigchain.json',
    );
    if (sidecarRes.isErr) {
      appLogger.w(
        'LAN: PDF sent OK to ${peer.name} but sidecar transfer failed — '
        'receiver can still open the PDF; verification of the chain '
        'will need a re-send. Error: ${sidecarRes.failureOrNull?.message}',
      );
    }
    return const Result<void>.ok(null);
  }

  /// Local basename helper that doesn't pull in `package:path`.
  /// LanRepository already minimizes deps to keep startup fast.
  static String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  /// Initiate the pair handshake with a peer. UI blocks waiting for the
  /// user to enter the 6-digit PIN shown on the receiver.
  ///
  /// **TLS exchange (post-2.1):** the pair flow now also exchanges TLS
  /// fingerprints so subsequent transfers can run over HTTPS with
  /// trust-on-first-use cert pinning. The peer's fingerprint comes back
  /// in `/pair/init` response (over the initial trust-by-PIN channel)
  /// and is persisted into PairedDevices.tlsFingerprintSha256. If the
  /// peer is on legacy 2.0.x (no TLS) the field stays null and `send()`
  /// falls back to plain HTTP.
  ///
  /// [requestPin] is called once we have the receiver's challenge id; the
  /// caller (UI) returns the digits the human typed.
  Future<Result<db.PairedDevice>> pair({
    required NearbyDevice peer,
    required Future<String?> Function() requestPin,
  }) async {
    try {
      // Resolve `.local` / IPv6-link-local hostnames to numeric IPs
      // BEFORE any HTTP call. Without this the pair init throws
      // SocketException("Failed host lookup") which the UI surfaces as
      // a generic "cant be found" snackbar even though the peer is
      // happily broadcasting on the LAN. See _resolveLanHost docstring.
      final resolvedHost = await _resolveLanHost(peer.host);
      if (resolvedHost == null) {
        appLogger.w(
          'LAN pair: could not resolve ${peer.name} host="${peer.host}" '
          'to a numeric IP — peer is discoverable via mDNS but its '
          'address is not reachable. Possible causes: peer on a different '
          'VLAN, Wi-Fi AP isolation enabled, or ${peer.host} is a '
          '.local hostname Dart cannot resolve.',
        );
        return Result<db.PairedDevice>.err(
          PairingFailure(
            'Could not reach ${peer.name} at ${peer.host}. '
            'Check that both devices are on the same Wi-Fi network and '
            'that "AP isolation" / "Client isolation" is off on the router.',
          ),
        );
      }
      appLogger.i(
        'LAN pair: ${peer.name} '
        '${peer.host == resolvedHost ? peer.host : '${peer.host} → $resolvedHost'}'
        ':${peer.port}',
      );

      // Step 0 — probe /info to learn the peer's TLS capabilities.
      //
      // Pro 2.1+ servers run TLS-only — `shelf_io.serve(...)` is called
      // with a `securityContext`, so plain HTTP gets RST'd. Older 2.0.x
      // servers ran plain HTTP. We try HTTPS first (current default) and
      // fall back to HTTP for legacy peers. The fingerprint we extract
      // here is then used to pin the next two requests.
      //
      // SAFETY: accepting any cert for the /info call is fine — /info
      // exposes only public capability data (deviceId, name, fingerprint,
      // hashed userId) and we IMMEDIATELY pin against the fingerprint we
      // learn for /pair/init + /pair/complete. The PIN ceremony provides
      // the actual security boundary.
      String? peerTlsFingerprint;
      bool peerSupportsTls = false;
      String pairScheme = 'http';

      final permissiveHttpClient = HttpClient()
        ..badCertificateCallback = (_, __, ___) => true;
      final permissiveClient = http_io.IOClient(permissiveHttpClient);
      try {
        // HTTPS first (Pro 2.1+ default)
        http.Response? infoResp;
        try {
          infoResp = await permissiveClient
              .get(Uri.parse('https://$resolvedHost:${peer.port}/info'))
              .timeout(const Duration(seconds: 5));
          if (infoResp.statusCode == 200) pairScheme = 'https';
        } catch (e) {
          appLogger.d('LAN pair: HTTPS /info probe failed ($e); '
              'trying plain HTTP for legacy peers.',);
        }
        // Plain HTTP fallback (Pro 2.0.x peers)
        if (infoResp == null || infoResp.statusCode != 200) {
          try {
            infoResp = await http
                .get(Uri.parse('http://$resolvedHost:${peer.port}/info'))
                .timeout(const Duration(seconds: 5));
            if (infoResp.statusCode == 200) pairScheme = 'http';
          } catch (_) {
            // Both probes failed — fall through; /pair/init will surface
            // a clearer SocketException with the right scheme.
          }
        }
        if (infoResp != null && infoResp.statusCode == 200) {
          final info = jsonDecode(infoResp.body) as Map<String, dynamic>;
          peerSupportsTls = info['tls'] == true;
          peerTlsFingerprint = info['fingerprintSha256'] as String?;
          // Refresh peer.name / peer.platform / peer.deviceId from the
          // /info response when the caller used a synthetic NearbyDevice
          // (manual-IP entry). Without this, the paired row shows
          // "Device at 192.168.100.4 / unknown" instead of the real
          // "BRAVIA 4K VH21 / android" the receiver self-reports.
          final realName = (info['name'] as String?)?.trim();
          final realPlatform = (info['platform'] as String?)?.trim();
          final realDeviceId = (info['deviceId'] as String?)?.trim();
          // ignore: parameter_assignments
          peer = peer.copyWith(
            name: (realName != null && realName.isNotEmpty) ? realName : null,
            platform: (realPlatform != null && realPlatform.isNotEmpty)
                ? realPlatform
                : null,
            deviceId: (realDeviceId != null && realDeviceId.isNotEmpty)
                ? realDeviceId
                : null,
          );
        }
      } finally {
        permissiveClient.close();
      }

      // Build the right HTTP client for the rest of the pair handshake.
      // If we have a fingerprint, pin against it; otherwise fall back to
      // a default client over whatever scheme /info responded on.
      http.Client buildPairClient() {
        if (pairScheme == 'https' && peerTlsFingerprint != null) {
          return http_io.IOClient(buildPinnedClient(peerTlsFingerprint!));
        }
        if (pairScheme == 'https') {
          // HTTPS but no fingerprint — temporarily accept any cert.
          // This branch is rare (peer claims TLS but didn't expose
          // fingerprintSha256 in /info). PIN ceremony still gates trust.
          final hc = HttpClient()
            ..badCertificateCallback = (_, __, ___) => true;
          return http_io.IOClient(hc);
        }
        return http.Client();
      }

      // Our own TLS fingerprint, sent along so the receiver can pin us too
      // (currently unused on the receiver side; reserved for receiver→sender
      // flows like remote signature requests).
      String? ownFingerprint;
      try {
        final pair = await ensureKeypair();
        ownFingerprint = pair.fingerprintSha256;
      } catch (_) {/* keypair gen failed — skip ownership claim */}

      // Step 1 — kick off the handshake. Receiver responds with EITHER:
      //   - `{autoPaired: true, secret: "..."}` if both peers are signed
      //     in to the same Interact Pro account (no PIN ceremony needed)
      //   - `{challengeId: "..."}` for the regular PIN flow
      final myUserId = currentUserIdGetter?.call();
      final initBody = jsonEncode({
        'fromDeviceId': deviceId,
        'fromName': deviceName,
        'fromPlatform': peer.platform,
        if (ownFingerprint != null) 'fromTlsFingerprint': ownFingerprint,
        if (myUserId != null) 'fromUserIdHash': _userIdHash(myUserId),
      });
      final http.Response initResp;
      final initClient = buildPairClient();
      try {
        initResp = await initClient
            .post(
              Uri.parse('$pairScheme://$resolvedHost:${peer.port}/pair/init'),
              headers: {'Content-Type': 'application/json'},
              body: initBody,
            )
            .timeout(const Duration(seconds: 6));
      } on SocketException catch (e) {
        initClient.close();
        // Numeric IP resolution succeeded but the peer isn't accepting
        // connections — most often because the LAN server hasn't bound
        // yet (peer just opened the app), the OS firewalled the port,
        // or AP isolation is silently dropping packets.
        appLogger.w(
          'LAN pair: connect to $resolvedHost:${peer.port} failed: ${e.message}',
        );
        return Result<db.PairedDevice>.err(
          PairingFailure(
            'Could not reach ${peer.name} at $resolvedHost:${peer.port}. '
            'Open Interact Pro on ${peer.name} first, then tap Pair again.',
            cause: e,
          ),
        );
      } on TimeoutException {
        initClient.close();
        return Result<db.PairedDevice>.err(
          PairingFailure(
            '${peer.name} did not respond within 6 seconds. '
            'Try again — first contact often needs a second attempt while '
            'the peer\'s server warms up.',
          ),
        );
      } catch (e) {
        initClient.close();
        rethrow;
      }
      initClient.close();
      if (initResp.statusCode != 200) {
        return Result<db.PairedDevice>.err(
          PairingFailure('Pair init rejected (${initResp.statusCode})'),
        );
      }
      final initJson = jsonDecode(initResp.body) as Map<String, dynamic>;
      // Prefer the fingerprint from /pair/init response (most authoritative);
      // fall back to /info probe.
      peerTlsFingerprint =
          (initJson['tlsFingerprintSha256'] as String?) ?? peerTlsFingerprint;

      // ── Auto-pair shortcut ────────────────────────────────────────
      // Same-account peers come back with the secret in /pair/init.
      // No PIN modal, no second request — just persist + return.
      if (initJson['autoPaired'] == true && initJson['secret'] is String) {
        final secretHex = initJson['secret'] as String;
        await database.upsertPairedDevice(db.PairedDevicesCompanion.insert(
          deviceId: peer.deviceId,
          name: peer.name,
          platform: peer.platform,
          secretHex: secretHex,
          pairedAt: DateTime.now(),
          tlsFingerprintSha256: peerTlsFingerprint == null
              ? const Value.absent()
              : Value(peerTlsFingerprint),
        ),);
        appLogger.i('LAN pair: auto-trusted ${peer.name} (same account)');
        await _cachePeerLocation(peer.deviceId, resolvedHost, peer.port);
        final stored = await database.pairedDevice(peer.deviceId);
        return Result<db.PairedDevice>.ok(stored!);
      }

      final challengeId = initJson['challengeId'] as String;

      // Step 2 — UI prompts the user.
      final pin = await requestPin();
      if (pin == null || pin.length != 6) {
        return const Result<db.PairedDevice>.err(
          PairingFailure('Pairing cancelled.'),
        );
      }

      // Step 3 — submit the PIN. Receiver returns the secret on match.
      // Same scheme + pinned client as /pair/init — they target the same
      // host:port, just a different endpoint.
      final completeClient = buildPairClient();
      final http.Response completeResp;
      try {
        completeResp = await completeClient.post(
          Uri.parse('$pairScheme://$resolvedHost:${peer.port}/pair/complete'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'challengeId': challengeId, 'pin': pin}),
        );
      } finally {
        completeClient.close();
      }
      if (completeResp.statusCode != 200) {
        return Result<db.PairedDevice>.err(
          PairingFailure(
            completeResp.statusCode == 403
                ? 'PIN mismatch — try again.'
                : 'Pair failed (${completeResp.statusCode}).',
          ),
        );
      }
      final completeJson =
          jsonDecode(completeResp.body) as Map<String, dynamic>;
      final secretHex = completeJson['secret'] as String;

      // Persist locally too — both sides need the same secret. Also store
      // the peer's TLS fingerprint so future sends pin against it.
      await database.upsertPairedDevice(db.PairedDevicesCompanion.insert(
        deviceId: peer.deviceId,
        name: peer.name,
        platform: peer.platform,
        secretHex: secretHex,
        pairedAt: DateTime.now(),
        tlsFingerprintSha256: peerTlsFingerprint == null
            ? const Value.absent()
            : Value(peerTlsFingerprint),
      ),);

      if (peerSupportsTls && peerTlsFingerprint == null) {
        appLogger.w(
          'LAN pair: peer says it supports TLS but didn\'t send a fingerprint. '
          'Falling back to plain HTTP for ${peer.name}.',
        );
      }

      await _cachePeerLocation(peer.deviceId, resolvedHost, peer.port);
      final stored = await database.pairedDevice(peer.deviceId);
      return Result<db.PairedDevice>.ok(stored!);
    } catch (e, st) {
      appLogger.e('Pair failed', error: e, stackTrace: st);
      return Result<db.PairedDevice>.err(PairingFailure('Pair failed', cause: e));
    }
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}

// ── Riverpod wiring ─────────────────────────────────────────────────────

const _kDeviceIdKey = 'lan.device_id';
const _kDeviceNameKey = 'lan.device_name';

/// Stable per-install id for LAN discovery. Different from the analytics
/// visitor id so unpairing privacy concerns are independent.
final lanDeviceIdProvider = FutureProvider<String>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(_kDeviceIdKey);
  if (id == null) {
    id = const Uuid().v4();
    await prefs.setString(_kDeviceIdKey, id);
  }
  return id;
});

final lanDeviceNameProvider = FutureProvider<String>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString(_kDeviceNameKey);
  if (stored != null && stored.trim().isNotEmpty) return stored.trim();

  // Fallback: derive a user-recognizable name from device_info_plus.
  // Platform.localHostname returns "localhost" on Android (no useful
  // device name exposed at the libc layer) — useless as a UI label in
  // the Nearby Devices picker. device_info_plus surfaces the OEM-set
  // name that users actually recognize ("Sony BRAVIA", "Galaxy A23",
  // "Pixel 8 Pro"). The user can still override via Settings →
  // Nearby Devices → Rename if they want a custom label.
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      // Try marketing-friendly fields first. `model` is usually the
      // best (e.g. "SM-A235F" → "Galaxy A23" on retail Samsung firmware;
      // Sony Bravia reports "BRAVIA 4K VH21"). Falls back to product/
      // device code if model is empty.
      final candidate = [a.model, a.product, a.device]
          .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
      if (candidate.isNotEmpty) return candidate;
    } else if (Platform.isIOS) {
      final i = await info.iosInfo;
      if (i.name.trim().isNotEmpty) return i.name;
    } else if (Platform.isMacOS) {
      final m = await info.macOsInfo;
      if (m.computerName.trim().isNotEmpty) return m.computerName;
    }
  } catch (e, st) {
    appLogger.w('device_info_plus lookup failed', error: e, stackTrace: st);
  }
  // Last-ditch fallback. Better than nothing, even if it's literally
  // the string "localhost" on Android — at least it's deterministic.
  return Platform.localHostname;
});

final lanRepositoryProvider = FutureProvider<LanRepository>((ref) async {
  final paths = await ref.watch(appPathsProvider.future);
  final database = ref.watch(db.appDatabaseProvider);
  final deviceId = await ref.watch(lanDeviceIdProvider.future);
  final deviceName = await ref.watch(lanDeviceNameProvider.future);

  // TLS keypair — generated lazily on first launch (1-2s on a phone),
  // cached from then on. If generation fails (e.g. basic_utils incompat),
  // we proceed without TLS — the server falls back to plain HTTP and
  // pairs that have no fingerprint stored use the same fallback path.
  LanTlsKeypair? tlsKeypair;
  try {
    tlsKeypair = await ensureKeypair();
  } catch (e, st) {
    appLogger.w('LAN: TLS init failed, running plain HTTP', error: e, stackTrace: st);
  }

  // Same-account auto-trust: when the same Interact Pro user is signed
  // in on two peers, they auto-pair without a PIN. This getter is read
  // at every /info and /pair/init handler invocation, so signing in or
  // out takes effect immediately without restarting the LAN server.
  String? currentUserId() {
    return ref.read(authUserProvider).asData?.value?.id;
  }

  final server = LanServer(
    deviceId: deviceId,
    deviceName: deviceName,
    appPaths: paths,
    database: database,
    tlsKeypair: tlsKeypair,
    currentUserIdGetter: currentUserId,
  );

  final repo = LanRepository(
    discovery: ref.watch(lanDiscoveryServiceProvider),
    server: server,
    database: database,
    deviceId: deviceId,
    deviceName: deviceName,
    currentUserIdGetter: currentUserId,
  );
  ref.onDispose(repo.stop);

  // CRITICAL: actually bootstrap the repo. This was missing pre-2026-05-13
  // — the provider constructed LanRepository and returned it without ever
  // calling start(), so the HTTP server never bound, Bonsoir never
  // broadcast our presence, and `dns-sd -B _interact._tcp local.` from a
  // Mac on the same Wi-Fi found nothing. Symptoms: Nearby Devices screen
  // empty on every device, Send-to-Device sheet showing "no devices",
  // multi-signer routing dead in the water.
  //
  // start() returns a Result; on failure we LOG and continue so the UI
  // can still render (it'll just show an empty peer list). Users can
  // retry via the refresh button → ref.invalidate(lanRepositoryProvider),
  // which rebuilds the provider and re-attempts start().
  final startRes = await repo.start();
  if (startRes.isErr) {
    appLogger.e(
      'LAN repo start failed: ${startRes.failureOrNull?.message}. '
      'Nearby Devices will be empty until the next refresh.',
    );
  } else {
    appLogger.i(
      'LAN repo started: serving on port ${repo.server.port}, '
      'broadcasting as "${repo.deviceName}" via Bonsoir mDNS.',
    );
  }

  return repo;
});

/// Live list of peers visible right now (paired status flagged).
final discoveredDevicesProvider =
    StreamProvider<List<NearbyDevice>>((ref) async* {
  final repo = await ref.watch(lanRepositoryProvider.future);
  yield* repo.peers();
});

/// Live list of paired peers from Drift (regardless of online status).
final pairedDevicesProvider =
    StreamProvider<List<db.PairedDevice>>((ref) async* {
  final repo = await ref.watch(lanRepositoryProvider.future);
  yield* repo.pairedDevices();
});

/// Stream of files sent to us by paired peers. Mount a listener once at app
/// boot (in `app.dart`) and route each event to the right viewer:
/// PDF → /viewer, Image → image viewer, Video → external player, etc.
///
/// Designed for the "phone shares photo → arrives on TV" flow but reusable
/// across every INTERACT app that needs LAN file delivery (Sahulat operator
/// pushing animal photos to dispatch tablet, FleetOps dispatch pushing
/// route docs to driver phones, etc.). Adopting apps just need to copy
/// `lib/features/lan/` and provide their own viewer routing.
final incomingSharesProvider = StreamProvider<IncomingShare>((ref) async* {
  final repo = await ref.watch(lanRepositoryProvider.future);
  yield* repo.server.incomingShares;
});

/// Stream of cast-start events. Mount an `IncomingCastBootstrap` listener
/// in app.dart so when another Pro device decides to cast TO us, we
/// auto-navigate to a CastReceiverScreen.
final incomingCastsProvider = StreamProvider<IncomingCast>((ref) async* {
  final repo = await ref.watch(lanRepositoryProvider.future);
  yield* repo.server.incomingCasts;
});

/// Stream of subsequent page updates from a sender we're already cast-
/// receiving from. CastReceiverScreen filters by the sender's deviceId.
final castPageUpdatesProvider =
    StreamProvider<CastPageUpdate>((ref) async* {
  final repo = await ref.watch(lanRepositoryProvider.future);
  yield* repo.server.castPageUpdates;
});

/// Stream of incoming pair-PIN challenges. Mount an
/// `IncomingPinBootstrap` in app.dart so when another Pro device starts
/// a pair handshake against us, the user sees the PIN they need to read
/// to the other device. Without this stream, the LAN server generates
/// the PIN silently and the pair flow hangs at the sender's "Enter PIN"
/// dialog.
final incomingPinChallengesProvider =
    StreamProvider<IncomingPinChallenge>((ref) async* {
  final repo = await ref.watch(lanRepositoryProvider.future);
  yield* repo.server.incomingPinChallenges;
});
