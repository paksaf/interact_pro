// SPDX-License-Identifier: AGPL-3.0
//
// Signature repository — drift queries + the canonical hash/sign/verify
// helpers for the stepwise approval workflow (task #3).
//
// Phase 1 MVP responsibilities:
//   - sign(document, signer) → write a Signatures row whose
//     [signatureB64] field is an Ed25519 sig over the canonical message
//   - signaturesFor(documentId) → list signatures on a PDF (audit trail)
//   - verify(signature) → recompute the message + run Ed25519.verify
//
// Phase 2 (deferred):
//   - embed visible stamp annotation onto the PDF page via syncfusion
//   - emit sidecar .sigchain JSON so signatures travel with the PDF
//   - chain mode where each signature signs the prior signature's hash
//
// The canonical message format is:
//   sha256(pdf_bytes_hex_ascii || '|' || code || '|' || timestampMs || '|' || signerId)
//
// All ASCII, no separators that could appear in any field, fixed-length
// timestampMs (right-padded to 13 digits). This is what gets signed and
// what gets verified — implementations on other languages/platforms will
// need to match this byte-for-byte.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import 'package:uuid/uuid.dart' as uuid_pkg;

import '../../../core/storage/app_database.dart';
import '../../sync/data/auto_sync_service.dart';
import 'signature_notifier.dart';
import 'signing_keys.dart';
import 'stamp_embedder.dart';

/// Result returned from [SignatureRepository.signDocument]. Caller can
/// hand this to the UI for displaying the stamp toast + copying the
/// human-readable code to clipboard.
class SignatureResult {
  const SignatureResult({
    required this.signatureRow,
    required this.shortCode,
    this.stampEmbedded = false,
    this.stampError,
  });

  final Signature signatureRow;

  /// Last 8 hex chars of the UUID code, in upper case. This is what
  /// appears on the visible stamp ("Code: 7B3F2A91").
  final String shortCode;

  /// True when the visible signature stamp was successfully drawn
  /// onto the PDF page. False if embedding was disabled OR failed
  /// (in the failure case [stampError] holds the reason).
  final bool stampEmbedded;

  /// Reason embedding failed, when not null. Common cases: PDF was
  /// read-only, page index out of range, syncfusion couldn't parse
  /// the PDF (encrypted / malformed). The DB audit row is still
  /// committed in either case — only the visible stamp is missing.
  final String? stampError;
}

class SignatureRepository {
  SignatureRepository({
    required AppDatabase db,
    required SigningKeysService keys,
    SignatureNotifier? notifier,
    AutoSyncService? autoSync,
  })  : _db = db,
        _keys = keys,
        _notifier = notifier,
        _autoSync = autoSync;

  final AppDatabase _db;
  final SigningKeysService _keys;

  /// Spike A — optional originator-notify. When non-null and the
  /// signed document has [PdfDocument.originatorEmail] or
  /// [PdfDocument.originatorPhone] set, we fire a Comms Hub message
  /// after each successful sign. Best-effort; failure is logged but
  /// never fails the sign.
  final SignatureNotifier? _notifier;

  /// Spike F — optional auto-sync trigger. When non-null and the
  /// user has flipped `auto_sync_enabled` in Settings, every
  /// successful sign queues a debounced upload to /api/sync/upload.
  final AutoSyncService? _autoSync;

  static const _uuid = uuid_pkg.Uuid();

  /// Read PDF bytes off disk and compute SHA-256. Streaming impl so we
  /// don't blow the heap on a 200MB scanned doc. Returns the hex digest.
  Future<String> hashPdfFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('PDF not found for hashing', path);
    }
    // sha256.bind() returns a Stream<Digest> that emits exactly one
    // digest when the input stream closes. `.first` waits for it.
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString(); // hex-encoded by Digest.toString()
  }

  /// Compose the canonical message that gets signed. Same format used at
  /// verify time — keep these in lockstep.
  Uint8List canonicalMessage({
    required String pdfHashHex,
    required String code,
    required int timestampMs,
    required String signerId,
  }) {
    // 13-digit zero-padded ms — covers up through year 2286, after which
    // the spec needs revisiting. Padding makes the byte length stable so
    // length-extension worries are nil even though SHA-256 isn't
    // vulnerable to that anyway.
    final tsPad = timestampMs.toString().padLeft(13, '0');
    final joined = '$pdfHashHex|$code|$tsPad|$signerId';
    return Uint8List.fromList(utf8.encode(joined));
  }

  /// Sign [documentId] with the current device's local identity. Caller
  /// must have already ensured the local identity is created (call
  /// [SigningKeysService.currentIdentity] once on app start — typically
  /// from the Settings screen or the first time the user taps "Sign").
  ///
  /// [pdfPath] is the absolute path to the PDF file on disk; we hash it
  /// directly rather than trusting whatever is in the [PdfDocuments] row
  /// in case the file has been re-saved since the row was created.
  ///
  /// When [embedVisibleStamp] is true (default Phase 2.5), the stamp
  /// is drawn onto the PDF page FIRST, then we hash the modified file,
  /// then sign. This way the signature attests to the version of the
  /// PDF that includes the visible stamp — verification on the same
  /// file produces a clean `valid` rather than `documentAltered`.
  ///
  /// The returned [SignatureResult] includes [stampEmbedded] so the UI
  /// can show "Signed + stamp added" vs "Signed (stamp failed, audit
  /// row recorded)" if the file was read-only.
  Future<SignatureResult> signDocument({
    required String documentId,
    required String pdfPath,
    required String signerDisplayName,
    String? signerEmail,
    String? note,
    int pageIndex = 0,
    double? x,
    double? y,
    double? width,
    double? height,
    bool embedVisibleStamp = true,
  }) async {
    final identity = await _keys.currentIdentity(
      displayName: signerDisplayName,
      email: signerEmail,
    );
    final code = _uuid.v4();
    final timestampMs = DateTime.now().millisecondsSinceEpoch;
    final shortCode =
        code.replaceAll('-', '').substring(0, 8).toUpperCase();

    // PHASE 2.5: Embed the visible stamp BEFORE hashing so the
    // signature attests to the post-stamp file. If embedding fails,
    // we degrade gracefully — keep the DB audit row, surface the
    // failure to the caller via SignatureResult.stampError, and hash
    // the (un-stamped) original. Most common cause of failure is a
    // read-only path; the audit row is still useful in that case.
    String? stampError;
    bool stampEmbedded = false;
    if (embedVisibleStamp) {
      final stampPos = (x != null && y != null && width != null && height != null)
          ? StampPosition(x: x, y: y, width: width, height: height)
          : null;
      final stampResult = await embedSignatureStamp(
        pdfPath: pdfPath,
        pageIndex: pageIndex,
        signerName: identity.name,
        timestampMs: timestampMs,
        shortCode: shortCode,
        position: stampPos,
      );
      if (stampResult.succeeded) {
        stampEmbedded = true;
      } else {
        stampError = stampResult.errorMessage;
      }
    }

    final pdfHashHex = await hashPdfFile(pdfPath);

    final message = canonicalMessage(
      pdfHashHex: pdfHashHex,
      code: code,
      timestampMs: timestampMs,
      signerId: identity.id,
    );
    final sigBytes = await identity.sign(message);

    final row = SignaturesCompanion(
      id: Value(_uuid.v4()),
      documentId: Value(documentId),
      signerId: Value(identity.id),
      code: Value(code),
      timestampMs: Value(timestampMs),
      pdfHashHex: Value(pdfHashHex),
      signatureB64: Value(base64Encode(sigBytes)),
      note: Value(note),
      pageIndex: Value(pageIndex),
      x: Value(x),
      y: Value(y),
      width: Value(width),
      height: Value(height),
      createdAt: Value(DateTime.now()),
    );
    final inserted = await _db.into(_db.signatures).insertReturning(row);

    // Spike A — originator-notify. Best-effort, fire-and-forget so
    // the sign UX isn't blocked by a flaky Comms Hub or a slow
    // network. The audit row above is already committed.
    final notifier = _notifier;
    if (notifier != null) {
      // ignore: discarded_futures
      _safeNotify(
        notifier: notifier,
        documentId: documentId,
        signerName: identity.name,
        shortCode: shortCode,
        timestampMs: timestampMs,
        note: note,
      );
    }

    // Spike F — auto-sync trigger. Debounced 3s on the service side so
    // a rapid burst of saves coalesces into one upload. No-op when
    // the user hasn't opted in via Settings → Privacy.
    // ignore: discarded_futures
    _autoSync?.triggerForDocument(documentId);

    return SignatureResult(
      signatureRow: inserted,
      shortCode: shortCode,
      stampEmbedded: stampEmbedded,
      stampError: stampError,
    );
  }

  Future<void> _safeNotify({
    required SignatureNotifier notifier,
    required String documentId,
    required String signerName,
    required String shortCode,
    required int timestampMs,
    String? note,
  }) async {
    try {
      final doc = await (_db.select(_db.pdfDocuments)
            ..where((t) => t.id.equals(documentId)))
          .getSingleOrNull();
      if (doc == null) return;
      await notifier.notifyOriginator(
        doc: doc,
        signerName: signerName,
        shortCode: shortCode,
        signedAtMs: timestampMs,
        note: note,
      );
    } catch (_) {
      // SignatureNotifier already swallows its own errors; this catch
      // is for the doc lookup itself. Either way — silent.
    }
  }

  /// Verify a stored signature. Returns true if the signer's public key
  /// validates against the recomputed canonical message AND the current
  /// PDF on disk still hashes to what was signed (i.e. the doc hasn't
  /// been altered since signing).
  ///
  /// Returns [VerificationResult] so callers can show a fine-grained
  /// error ("doc altered" vs "bad signature" vs "unknown signer").
  Future<VerificationResult> verifySignature({
    required Signature signature,
    required String currentPdfPath,
  }) async {
    final identity = await _keys.lookupIdentity(signature.signerId);
    if (identity == null) {
      return const VerificationResult.unknownSigner();
    }
    final currentHash = await hashPdfFile(currentPdfPath);
    if (currentHash != signature.pdfHashHex) {
      return const VerificationResult.documentAltered();
    }
    final message = canonicalMessage(
      pdfHashHex: signature.pdfHashHex,
      code: signature.code,
      timestampMs: signature.timestampMs,
      signerId: signature.signerId,
    );
    final pubKey = publicKeyFromBase64(identity.publicKeyB64);
    final ok = await verifyEd25519Signature(
      message: message,
      signatureBytes: base64Decode(signature.signatureB64),
      publicKey: pubKey,
    );
    return ok
        ? const VerificationResult.valid()
        : const VerificationResult.badSignature();
  }

  /// All signatures on a document, oldest first. Used to render the
  /// audit trail tab.
  Future<List<Signature>> signaturesFor(String documentId) {
    return (_db.select(_db.signatures)
          ..where((t) => t.documentId.equals(documentId))
          ..orderBy([(t) => OrderingTerm.asc(t.timestampMs)]))
        .get();
  }

  /// Delete a signature row. The visible stamp annotation (Phase 2)
  /// must be removed separately — this just clears the audit row.
  Future<int> deleteSignature(String signatureId) {
    return (_db.delete(_db.signatures)..where((t) => t.id.equals(signatureId)))
        .go();
  }
}

/// Outcome of [SignatureRepository.verifySignature]. Sealed class so
/// only these four states exist. Boolean getters expose state for
/// cross-file consumers since the concrete subtypes are private to
/// this file (pattern-matching them from elsewhere would require
/// publicizing internals).
sealed class VerificationResult {
  const VerificationResult();

  const factory VerificationResult.valid() = _Valid;
  const factory VerificationResult.badSignature() = _BadSig;
  const factory VerificationResult.documentAltered() = _DocAltered;
  const factory VerificationResult.unknownSigner() = _UnknownSigner;

  bool get isValid => this is _Valid;
  bool get isBadSignature => this is _BadSig;
  bool get isDocumentAltered => this is _DocAltered;
  bool get isUnknownSigner => this is _UnknownSigner;

  /// Stable identifier for switch-style dispatch in UI code. Avoids the
  /// need to expose the private subtypes for pattern matching.
  String get kind => switch (this) {
        _Valid() => 'valid',
        _BadSig() => 'badSignature',
        _DocAltered() => 'documentAltered',
        _UnknownSigner() => 'unknownSigner',
      };
}

class _Valid extends VerificationResult {
  const _Valid();
}

class _BadSig extends VerificationResult {
  const _BadSig();
}

class _DocAltered extends VerificationResult {
  const _DocAltered();
}

class _UnknownSigner extends VerificationResult {
  const _UnknownSigner();
}
