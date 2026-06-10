// SPDX-License-Identifier: AGPL-3.0
//
// Sidecar .sigchain JSON — portable signature manifest that travels
// alongside a PDF when shared via LAN / Drive / file export. Lets a
// receiving Pro instance verify the signature chain even if they've
// never paired with the original signer (the signer's public key is
// embedded in the sidecar).
//
// File layout: <pdfPath>.sigchain.json — a UTF-8 JSON object:
//
//   {
//     "version": 1,
//     "documentTitle": "Contract.pdf",
//     "createdAt": "2026-05-12T14:30:00Z",
//     "identities": [
//       { "id": "...", "name": "...", "email": "...", "publicKeyB64": "..." }
//     ],
//     "signatures": [
//       {
//         "id": "...",
//         "signerId": "...",
//         "code": "...",
//         "timestampMs": 1747...,
//         "pdfHashHex": "...",
//         "signatureB64": "...",
//         "note": "...",
//         "pageIndex": 0,  "x": 0.1, "y": 0.05, "width": 0.3, "height": 0.08
//       }
//     ]
//   }
//
// On import (e.g. when a Pro instance receives a PDF via LAN), the
// SignatureRepository can read the sidecar and create matching rows
// in Signatures + SigningIdentities so verification works locally.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../../../core/storage/app_database.dart';
import 'signing_keys.dart';

const _kSidecarVersion = 1;
const _kSidecarExtension = '.sigchain.json';

/// Compute the sidecar path for a given PDF path. Just adds the
/// `.sigchain.json` suffix — keeps the sidecar next to the PDF so
/// file managers / share intents pick it up alongside.
String sidecarPathFor(String pdfPath) => '$pdfPath$_kSidecarExtension';

class SigchainSidecar {
  SigchainSidecar({required AppDatabase db, required SigningKeysService keys})
      : _db = db,
        _keys = keys;

  final AppDatabase _db;
  final SigningKeysService _keys;

  /// Build + write the sidecar for [pdfPath]. Includes all signatures
  /// on [documentId] plus the public keys of every distinct signer
  /// (so the receiver can verify without prior pairing).
  Future<File> write({
    required String pdfPath,
    required String documentId,
    required String documentTitle,
  }) async {
    final signatures = await (_db.select(_db.signatures)
          ..where((t) => t.documentId.equals(documentId)))
        .get();

    // Dedupe signers across the chain so we ship each pubkey once.
    final signerIds = signatures.map((s) => s.signerId).toSet();
    final identities = <SigningIdentity>[];
    for (final id in signerIds) {
      final row = await _keys.lookupIdentity(id);
      if (row != null) identities.add(row);
    }

    final payload = <String, Object?>{
      'version': _kSidecarVersion,
      'documentTitle': documentTitle,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'identities': identities
          .map((i) => {
                'id': i.id,
                'name': i.name,
                if (i.email != null) 'email': i.email,
                'publicKeyB64': i.publicKeyB64,
              },)
          .toList(),
      'signatures': signatures
          .map((s) => {
                'id': s.id,
                'signerId': s.signerId,
                'code': s.code,
                'timestampMs': s.timestampMs,
                'pdfHashHex': s.pdfHashHex,
                'signatureB64': s.signatureB64,
                if (s.note != null) 'note': s.note,
                if (s.pageIndex != null) 'pageIndex': s.pageIndex,
                if (s.x != null) 'x': s.x,
                if (s.y != null) 'y': s.y,
                if (s.width != null) 'width': s.width,
                if (s.height != null) 'height': s.height,
              },)
          .toList(),
    };

    final file = File(sidecarPathFor(pdfPath));
    await file.writeAsString(jsonEncode(payload), flush: true);
    return file;
  }

  /// True when a sidecar exists next to [pdfPath]. Used by the import
  /// flow to decide whether to offer "Import signatures from sidecar".
  Future<bool> exists(String pdfPath) {
    return File(sidecarPathFor(pdfPath)).exists();
  }

  /// Read + parse the sidecar at [pdfPath]. Returns null if not found.
  /// Throws [FormatException] if the file exists but isn't valid JSON
  /// or doesn't match the expected schema version.
  Future<ParsedSidecar?> read(String pdfPath) async {
    final file = File(sidecarPathFor(pdfPath));
    if (!await file.exists()) return null;

    final text = await file.readAsString();
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('Sidecar root must be a JSON object');
    }
    final version = json['version'];
    if (version != _kSidecarVersion) {
      throw FormatException(
        'Unsupported sidecar version: $version (this build supports $_kSidecarVersion)',
      );
    }
    return ParsedSidecar.fromJson(json);
  }

  /// Import signatures from a sidecar into the local DB. Creates
  /// SigningIdentities rows for unknown signers (so verify can find
  /// their public keys) and Signatures rows for each entry in the
  /// chain. Idempotent — rows with the same id are skipped via
  /// insertOnConflictUpdate semantics.
  ///
  /// [documentId] is the LOCAL document id (the PdfDocuments.id row)
  /// of the imported PDF. The sidecar doesn't store this because PDF
  /// rows have device-local ids that don't transfer.
  Future<int> importInto({
    required String pdfPath,
    required String documentId,
  }) async {
    final parsed = await read(pdfPath);
    if (parsed == null) return 0;

    // Upsert identities first so the FK-style lookup at verify time
    // finds the right pubkey for each signature.
    for (final identity in parsed.identities) {
      await _keys.upsertPeerIdentity(
        id: identity.id,
        name: identity.name,
        email: identity.email,
        publicKeyB64: identity.publicKeyB64,
      );
    }

    // Insert each signature, rewriting the documentId to the local row.
    int inserted = 0;
    for (final s in parsed.signatures) {
      await _db.into(_db.signatures).insertOnConflictUpdate(
            SignaturesCompanion(
              id: Value(s.id),
              documentId: Value(documentId),
              signerId: Value(s.signerId),
              code: Value(s.code),
              timestampMs: Value(s.timestampMs),
              pdfHashHex: Value(s.pdfHashHex),
              signatureB64: Value(s.signatureB64),
              note: Value(s.note),
              pageIndex: Value(s.pageIndex),
              x: Value(s.x),
              y: Value(s.y),
              width: Value(s.width),
              height: Value(s.height),
              createdAt: Value(DateTime.now()),
            ),
          );
      inserted++;
    }
    return inserted;
  }
}

/// Plain-data view of a parsed sidecar file. Used to inspect contents
/// before importing (e.g. show a confirmation dialog "Import 3 signatures
/// from 2 signers?").
class ParsedSidecar {
  ParsedSidecar({
    required this.version,
    required this.documentTitle,
    required this.createdAt,
    required this.identities,
    required this.signatures,
  });

  final int version;
  final String documentTitle;
  final DateTime createdAt;
  final List<SidecarIdentity> identities;
  final List<SidecarSignature> signatures;

  factory ParsedSidecar.fromJson(Map<String, Object?> json) {
    return ParsedSidecar(
      version: json['version'] as int,
      documentTitle: json['documentTitle'] as String? ?? 'Untitled',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      identities: ((json['identities'] as List?) ?? const [])
          .whereType<Map<String, Object?>>()
          .map(SidecarIdentity.fromJson)
          .toList(),
      signatures: ((json['signatures'] as List?) ?? const [])
          .whereType<Map<String, Object?>>()
          .map(SidecarSignature.fromJson)
          .toList(),
    );
  }
}

class SidecarIdentity {
  SidecarIdentity({
    required this.id,
    required this.name,
    this.email,
    required this.publicKeyB64,
  });

  final String id;
  final String name;
  final String? email;
  final String publicKeyB64;

  factory SidecarIdentity.fromJson(Map<String, Object?> json) =>
      SidecarIdentity(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String?,
        publicKeyB64: json['publicKeyB64'] as String,
      );
}

class SidecarSignature {
  SidecarSignature({
    required this.id,
    required this.signerId,
    required this.code,
    required this.timestampMs,
    required this.pdfHashHex,
    required this.signatureB64,
    this.note,
    this.pageIndex,
    this.x,
    this.y,
    this.width,
    this.height,
  });

  final String id;
  final String signerId;
  final String code;
  final int timestampMs;
  final String pdfHashHex;
  final String signatureB64;
  final String? note;
  final int? pageIndex;
  final double? x;
  final double? y;
  final double? width;
  final double? height;

  factory SidecarSignature.fromJson(Map<String, Object?> json) {
    double? d(Object? v) => v is num ? v.toDouble() : null;
    return SidecarSignature(
      id: json['id'] as String,
      signerId: json['signerId'] as String,
      code: json['code'] as String,
      timestampMs: (json['timestampMs'] as num).toInt(),
      pdfHashHex: json['pdfHashHex'] as String,
      signatureB64: json['signatureB64'] as String,
      note: json['note'] as String?,
      pageIndex: (json['pageIndex'] as num?)?.toInt(),
      x: d(json['x']),
      y: d(json['y']),
      width: d(json['width']),
      height: d(json['height']),
    );
  }
}

/// Convenience: helper for the LAN-share flow to bundle the sidecar
/// with the PDF as a pair of files. Returns the sidecar path if it
/// exists, null otherwise.
String? sidecarPathIfExists(String pdfPath) {
  final path = sidecarPathFor(pdfPath);
  return File(path).existsSync() ? path : null;
}

/// Sanity helper for the unit tests we'll add later: extract the
/// PDF basename for use in share / log messages. Lives here rather
/// than core/utils so the sigchain module stays self-contained.
String prettyPdfBasename(String pdfPath) => p.basename(pdfPath);
