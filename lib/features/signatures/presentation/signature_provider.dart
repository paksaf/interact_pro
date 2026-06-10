// SPDX-License-Identifier: AGPL-3.0
//
// Riverpod providers for the signature feature (task #3).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../../sync/data/auto_sync_service.dart';
import '../data/sigchain_sidecar.dart';
import '../data/signature_repository.dart';
import '../data/signing_keys.dart';

/// The device's keypair service. Lives for the app lifetime.
final signingKeysServiceProvider = Provider<SigningKeysService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return SigningKeysService(db: db);
});

/// Repository for signing + verifying + listing signatures.
final signatureRepositoryProvider = Provider<SignatureRepository>((ref) {
  return SignatureRepository(
    db: ref.watch(appDatabaseProvider),
    keys: ref.watch(signingKeysServiceProvider),
    // Spike F — debounced cloud upload after each successful sign.
    // No-op when the user hasn't opted in via Settings → Privacy.
    autoSync: ref.watch(autoSyncServiceProvider),
  );
});

/// Signatures on a specific document, refreshed on every dependency change.
/// Used by the audit-trail UI in the viewer to show "this doc is signed
/// by X people".
final signaturesForDocumentProvider =
    FutureProvider.family<List<Signature>, String>((ref, documentId) {
  final repo = ref.watch(signatureRepositoryProvider);
  return repo.signaturesFor(documentId);
});

/// Sidecar (.sigchain.json) read/write/import service. Used by the
/// SignSheet (optionally writes the sidecar after a successful sign)
/// and by the LAN import flow.
final sigchainSidecarProvider = Provider<SigchainSidecar>((ref) {
  return SigchainSidecar(
    db: ref.watch(appDatabaseProvider),
    keys: ref.watch(signingKeysServiceProvider),
  );
});
