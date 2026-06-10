// SPDX-License-Identifier: AGPL-3.0
//
// Signing key management for the stepwise approval workflow (task #3).
//
// One Ed25519 keypair per device. Generated lazily on first sign attempt.
// Private key lives in flutter_secure_storage (encrypted at rest by the
// platform keychain on iOS, EncryptedSharedPreferences on Android).
// Public key is mirrored into the [SigningIdentities] drift table so
// verification works without touching secure storage.
//
// This is foundation-only — the visible PDF stamp (annotation embedded
// into the PDF body) and the verification UI ship in Phase 2. Today's
// MVP just records signatures in the DB so the audit trail exists from
// day one and won't need backfill later.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart' as uuid_pkg;

// Restrict the drift import to the symbols we actually use. The
// generated app_database.dart also exports a `Signature` class
// (the row data type for the `signatures` table) which clashes with
// the `Signature` exported by `package:cryptography` (the Ed25519
// signature container). We never touch the drift Signature row in
// this file — that's the SignatureRepository's job — so omitting it
// here resolves the ambiguity cleanly.
import '../../../core/storage/app_database.dart'
    show
        AppDatabase,
        SigningIdentities,
        SigningIdentitiesCompanion,
        SigningIdentity;

/// Storage key for the local device's Ed25519 private key in secure storage.
/// Format: 32 raw bytes, base64-encoded. Keep this stable across releases —
/// changing it would lock users out of past signatures.
const _kPrivateKeyStorageKey = 'interact_pro.signing.ed25519.private_key_v1';

/// Storage key for the local device's identity UUID (matches the row in
/// [SigningIdentities] where isLocal=true).
const _kLocalIdentityIdKey = 'interact_pro.signing.local_identity_id_v1';

/// Bundle returned by [SigningKeysService.currentIdentity]. Combines the
/// drift row's display fields with the actual keypair for signing.
class LocalSigningIdentity {
  const LocalSigningIdentity({
    required this.id,
    required this.name,
    required this.email,
    required this.publicKey,
    required this.keyPair,
  });

  final String id;
  final String name;
  final String? email;
  final SimplePublicKey publicKey;
  final SimpleKeyPair keyPair;

  String get publicKeyB64 =>
      base64Encode(_extractPublicKeyBytesSync(publicKey));

  /// Sign an arbitrary message with this identity's private key. Returns
  /// the raw 64-byte signature; callers usually base64-encode before
  /// persisting. Throws if the key pair is malformed (shouldn't happen
  /// in practice — would indicate corruption in secure storage).
  Future<Uint8List> sign(Uint8List message) async {
    final algorithm = Ed25519();
    final sig = await algorithm.sign(message, keyPair: keyPair);
    return Uint8List.fromList(sig.bytes);
  }
}

/// Verifies a signature against a known public key. Pure function — used
/// both for "did I really sign this?" and "did the peer who claims to be
/// X really sign this?" cases.
Future<bool> verifyEd25519Signature({
  required Uint8List message,
  required Uint8List signatureBytes,
  required SimplePublicKey publicKey,
}) async {
  final algorithm = Ed25519();
  final sig = Signature(signatureBytes, publicKey: publicKey);
  return algorithm.verify(message, signature: sig);
}

/// Encode a [SimplePublicKey] as base64. The cryptography package stores
/// the raw bytes inside; this helper exists because [SimplePublicKey.bytes]
/// returns `Future<List<int>>` on some platforms and `List<int>` on
/// others depending on the version — we normalize to base64-of-raw-bytes
/// for storage.
String publicKeyToBase64(SimplePublicKey key) =>
    base64Encode(_extractPublicKeyBytesSync(key));

/// Decode a base64 string back to a [SimplePublicKey] for use with the
/// Ed25519 verifier. Throws [FormatException] if the input isn't valid
/// base64 or the decoded payload isn't 32 bytes.
SimplePublicKey publicKeyFromBase64(String b64) {
  final bytes = base64Decode(b64);
  if (bytes.length != 32) {
    throw FormatException(
      'Ed25519 public keys are 32 bytes, got ${bytes.length}',
    );
  }
  return SimplePublicKey(bytes, type: KeyPairType.ed25519);
}

/// Pull the raw bytes out of a [SimplePublicKey] synchronously. The
/// cryptography package's pure-Dart implementation stores them on the
/// `bytes` getter; if a platform-specific impl ever wraps them in a
/// Future we'll need to call `await key.extract()` first — that path
/// hasn't shown up for Ed25519 on Android/iOS in cryptography 2.x.
List<int> _extractPublicKeyBytesSync(SimplePublicKey key) => key.bytes;

/// Service that owns the device's signing keypair and the local row in
/// [SigningIdentities]. Singleton via Riverpod (provider lives in
/// `signature_provider.dart`).
class SigningKeysService {
  SigningKeysService({
    required AppDatabase db,
    FlutterSecureStorage? storage,
  })  : _db = db,
        _storage = storage ?? const FlutterSecureStorage();

  final AppDatabase _db;
  final FlutterSecureStorage _storage;
  static const _uuid = uuid_pkg.Uuid();

  LocalSigningIdentity? _cached;

  /// Returns the device's signing identity. Lazily generates a fresh
  /// Ed25519 keypair + identity row on first call, then caches in
  /// memory for subsequent calls.
  ///
  /// [displayName] is only consulted on first-ever launch — the row's
  /// name field is stamped from this value and persisted. Subsequent
  /// calls return the existing identity regardless of [displayName].
  /// Update the display name via [setDisplayName] instead.
  Future<LocalSigningIdentity> currentIdentity({
    required String displayName,
    String? email,
  }) async {
    if (_cached != null) return _cached!;

    final existingPriv = await _storage.read(key: _kPrivateKeyStorageKey);
    final existingId = await _storage.read(key: _kLocalIdentityIdKey);

    if (existingPriv != null && existingId != null) {
      // Restore from secure storage. Reconstruct keypair from the raw
      // 32-byte seed (Ed25519 private keys ARE the seed in cryptography 2.x).
      final algorithm = Ed25519();
      final privBytes = base64Decode(existingPriv);
      final keyPair = await algorithm.newKeyPairFromSeed(privBytes);
      final pubKey = await keyPair.extractPublicKey();

      // Pull the display name from the DB row if it exists; this lets
      // [setDisplayName] take effect even when called offline.
      final row = await (_db.select(_db.signingIdentities)
            ..where((t) => t.id.equals(existingId)))
          .getSingleOrNull();
      final name = row?.name ?? displayName;
      final emailVal = row?.email ?? email;

      _cached = LocalSigningIdentity(
        id: existingId,
        name: name,
        email: emailVal,
        publicKey: pubKey,
        keyPair: keyPair,
      );
      return _cached!;
    }

    // Fresh device or wiped storage — generate a new keypair.
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    final id = _uuid.v4();

    await _storage.write(
      key: _kPrivateKeyStorageKey,
      value: base64Encode(privBytes),
    );
    await _storage.write(key: _kLocalIdentityIdKey, value: id);

    // Persist the public half + display fields to drift so the rest of
    // the app can list known signers without touching secure storage.
    await _db.into(_db.signingIdentities).insert(
          SigningIdentitiesCompanion(
            id: Value(id),
            name: Value(displayName),
            email: Value(email),
            publicKeyB64: Value(publicKeyToBase64(pubKey)),
            isLocal: const Value(true),
            createdAt: Value(DateTime.now()),
          ),
        );

    _cached = LocalSigningIdentity(
      id: id,
      name: displayName,
      email: email,
      publicKey: pubKey,
      keyPair: keyPair,
    );
    return _cached!;
  }

  /// Update the local identity's display name (e.g. when the user
  /// changes it in Settings). Doesn't touch the keypair — past
  /// signatures remain verifiable.
  Future<void> setDisplayName(String name, {String? email}) async {
    final id = await _storage.read(key: _kLocalIdentityIdKey);
    if (id == null) return;
    await (_db.update(_db.signingIdentities)
          ..where((t) => t.id.equals(id)))
        .write(SigningIdentitiesCompanion(
      name: Value(name),
      email: Value(email),
    ),);
    if (_cached != null && _cached!.id == id) {
      _cached = LocalSigningIdentity(
        id: _cached!.id,
        name: name,
        email: email,
        publicKey: _cached!.publicKey,
        keyPair: _cached!.keyPair,
      );
    }
  }

  /// Look up a peer's identity row by id (used during signature
  /// verification — we need their public key to run Ed25519.verify).
  /// Returns null if the peer is unknown (signature came from a device
  /// we've never paired with).
  Future<SigningIdentity?> lookupIdentity(String id) {
    return (_db.select(_db.signingIdentities)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Register (or update) a peer's public key. Called during LAN pair
  /// handshake once we've verified the peer's TLS fingerprint, and when
  /// importing a signed PDF from outside (the sidecar JSON includes the
  /// signer's public key for offline verification).
  Future<void> upsertPeerIdentity({
    required String id,
    required String name,
    String? email,
    required String publicKeyB64,
  }) {
    return _db.into(_db.signingIdentities).insertOnConflictUpdate(
          SigningIdentitiesCompanion(
            id: Value(id),
            name: Value(name),
            email: Value(email),
            publicKeyB64: Value(publicKeyB64),
            isLocal: const Value(false),
            createdAt: Value(DateTime.now()),
          ),
        );
  }
}
