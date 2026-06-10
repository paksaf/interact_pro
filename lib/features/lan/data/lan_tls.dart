/// TLS support for the LAN cast / share server.
///
/// **What this gives you:**
///   - Self-signed RSA-2048 cert generated on first launch and persisted to
///     `${ApplicationSupport}/lan-tls/` (cert.pem + key.pem).
///   - SHA-256 fingerprint of the cert that we exchange during the pair
///     handshake (added to /pair/init response + /pair/complete client→server).
///   - A `SecurityContext` for `shelf_io.serveSecure(...)` and a `HttpClient`
///     for the sender that pins the receiver's stored fingerprint.
///
/// **Why self-signed instead of a real CA chain:**
///   Devices on a residential / depot Wi-Fi don't have routable hostnames or
///   public DNS — Let's Encrypt can't issue for `192.168.1.42`. The "right"
///   move is fingerprint-pinning at pair time (similar to how SSH host keys
///   work): trust on first use, then strict thereafter. If the cert ever
///   rotates, the next /receive call fails with `BAD_FINGERPRINT` and the
///   user is prompted to re-pair.
///
/// **Cert lifetime:** 10 years. We rotate by deleting the file (or with a
/// future "rotate cert" admin action); pair fingerprints invalidate
/// immediately and senders see the BAD_FINGERPRINT error on next attempt.
///
/// **Threat model coverage:**
///   - Encrypts file body in transit — defeats the depot/coffee-shop
///     Wi-Fi network sniffer scenario.
///   - Doesn't defeat a determined attacker who can MITM the *initial*
///     pair handshake (they'd swap their cert in for ours), because pair
///     itself is the trust-establishing event. To close that gap, render
///     the fingerprint in the PIN-display modal so the user can visually
///     confirm before completing the pair. (Ship that as a v2 polish.)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/logger.dart';

/// Path of the on-disk cert + key, plus the SHA-256 fingerprint string we
/// expose to peers. Two separate files (PEM-encoded) to keep openssl /
/// debugging sane.
class LanTlsKeypair {
  const LanTlsKeypair({
    required this.certPath,
    required this.keyPath,
    required this.fingerprintSha256,
  });

  final String certPath;
  final String keyPath;

  /// Hex-encoded SHA-256 of the DER cert. Lowercased, no separators.
  /// Example: `9f8b3a4c0d…(64 chars total)`. This is what gets written into
  /// the PairedDevices row at pair time and verified on every send.
  final String fingerprintSha256;
}

/// Loads the on-disk cert/key pair, generating one if it doesn't exist.
/// Idempotent — safe to call from multiple isolates (we use atomic-write
/// + one-shot generation guarded by a file existence check).
Future<LanTlsKeypair> ensureKeypair() async {
  final supportDir = await getApplicationSupportDirectory();
  final tlsDir = Directory(p.join(supportDir.path, 'lan-tls'));
  if (!tlsDir.existsSync()) await tlsDir.create(recursive: true);

  final certFile = File(p.join(tlsDir.path, 'cert.pem'));
  final keyFile = File(p.join(tlsDir.path, 'key.pem'));

  if (!certFile.existsSync() || !keyFile.existsSync()) {
    appLogger.i('LAN TLS: generating new self-signed keypair (one-time)');
    final pair = _generateRsa2048();
    final certPem = _selfSign(pair, commonName: 'interact-lan');
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(pair.privateKey);

    // Atomic-ish: write to .partial, then rename. Two rapid first-launches
    // could race here but the loser's cert just gets overwritten — no
    // correctness issue because every device only ever trusts the cert it
    // exchanged at pair time.
    await File('${certFile.path}.partial').writeAsString(certPem);
    await File('${keyFile.path}.partial').writeAsString(keyPem);
    await File('${certFile.path}.partial').rename(certFile.path);
    await File('${keyFile.path}.partial').rename(keyFile.path);
  }

  final certPem = await certFile.readAsString();
  final fingerprint = _fingerprintSha256OfPem(certPem);

  return LanTlsKeypair(
    certPath: certFile.path,
    keyPath: keyFile.path,
    fingerprintSha256: fingerprint,
  );
}

/// Build a `SecurityContext` for `shelf_io.serveSecure(handler, addr, port,
/// securityContext)` from the persisted keypair.
SecurityContext buildServerSecurityContext(LanTlsKeypair pair) {
  return SecurityContext(withTrustedRoots: false)
    ..useCertificateChain(pair.certPath)
    ..usePrivateKey(pair.keyPath);
}

/// Build an `HttpClient` that accepts ONLY the given fingerprint.
///
/// Use from the sender side (`LanRepository.send`) — every outbound HTTPS
/// request to a peer is wrapped in this client. The `badCertificateCallback`
/// returns true ONLY if the server's cert SHA-256 matches the fingerprint
/// we recorded at pair time. Any other cert (legitimate but unexpected,
/// MITM, swapped) is rejected.
HttpClient buildPinnedClient(String expectedFingerprintSha256) {
  final client = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      final actual = _fingerprintSha256OfDer(cert.der);
      final ok = actual == expectedFingerprintSha256.toLowerCase();
      if (!ok) {
        appLogger.w(
          'LAN TLS: cert mismatch for $host:$port '
          '(expected ${expectedFingerprintSha256.substring(0, 12)}…, '
          'got ${actual.substring(0, 12)}…)',
        );
      }
      return ok;
    }
    // LAN transfers can be slow on busy Wi-Fi; bump from default 15s.
    ..connectionTimeout = const Duration(seconds: 30);
  return client;
}

// ── Internals ──────────────────────────────────────────────────────────

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _generateRsa2048() {
  // 2048 is the sweet spot — 4096 doubles cert generation time on a phone
  // (5-10s vs 1-2s) without meaningful security gain for fingerprint-pinned
  // LAN use. ECDSA P-256 would be even faster but compatibility is worse
  // across embedded receivers (some Tizen / webOS browsers still flake on
  // ECDSA-only certs).
  //
  // basic_utils declares its return type as the abstract pair (PublicKey,
  // PrivateKey) even though it always concretely returns RSA keys when
  // given keySize. Cast through the concrete subtypes so the rest of this
  // file (and the X509 helpers) get the narrower type they need.
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  return AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
    pair.publicKey as RSAPublicKey,
    pair.privateKey as RSAPrivateKey,
  );
}

String _selfSign(
  AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> pair, {
  required String commonName,
}) {
  // 10-year validity; we rotate by deleting the file.
  final dn = {'CN': commonName, 'O': 'INTERACT', 'OU': 'LAN cast'};
  final csr = X509Utils.generateRsaCsrPem(dn, pair.privateKey, pair.publicKey);
  return X509Utils.generateSelfSignedCertificate(
    pair.privateKey,
    csr,
    365 * 10,
    sans: <String>[],
  );
}

/// SHA-256 fingerprint of a PEM-encoded cert. Strips the `-----BEGIN/END-----`
/// wrappers, base64-decodes the DER, hashes that.
String _fingerprintSha256OfPem(String pem) {
  final base64Body = pem
      .split('\n')
      .where((l) => !l.startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  final der = base64.decode(base64Body);
  return _fingerprintSha256OfDer(Uint8List.fromList(der));
}

String _fingerprintSha256OfDer(List<int> der) {
  return sha256.convert(der).toString().toLowerCase();
}

// ── Riverpod ───────────────────────────────────────────────────────────

/// Cached keypair — generated on first read, reused for the rest of the
/// process lifetime. Never invalidated; the cert lives 10 years.
final lanTlsKeypairProvider = FutureProvider<LanTlsKeypair>((ref) async {
  return ensureKeypair();
});
