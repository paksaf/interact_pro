// SPDX-License-Identifier: AGPL-3.0
//
// SignatureNotifier — Spike A (originator-notify on sign).
//
// When a user signs a document that arrived via incoming share, the
// person who sent it usually wants to know: "Has Ali signed yet?". Up
// until now the audit chain lived only on the signer's device — the
// originator had to keep asking. This notifier closes that loop:
//
//   1. PdfDocuments table now stores `originatorEmail` and
//      `originatorPhone` (nullable) — captured by
//      IncomingFileListener when the file arrives.
//   2. After SignatureRepository.signDocument() commits the audit row,
//      it calls notifyOriginator(...) below.
//   3. notifyOriginator() looks up the doc; if either originator
//      contact is set, it POSTs to the Comms Hub at
//      connect.interactpak.com/api/comms/send with channel=email or
//      channel=sms — same endpoint Sahulat / FleetOps / Rewards use
//      for OTPs and reminders. The Hub already handles transport
//      selection (Resend / capcom6 / Baileys / Twilio fallback).
//   4. Send is best-effort: a network failure or Hub 5xx is logged
//      and swallowed. The signature itself is already committed —
//      we don't want a flaky Hub to fail a successful sign.
//
// Why Comms Hub (not direct Resend): the Hub centralises OTP / WA /
// SMS routing across all INTERACT apps. Pro reuses that infra rather
// than maintaining its own email + SMS fan-out. See
// comms_hub_centralisation memory note.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/storage/app_database.dart';
import '../../../core/utils/logger.dart';

class SignatureNotifier {
  SignatureNotifier({
    required this.commsHubBase,
    required this.commsHubToken,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// connect.interactpak.com is the canonical Comms Hub host. The
  /// constructor takes the base so unit tests can swap to a local
  /// fixture server.
  final String commsHubBase;

  /// INTERACT_HUB_TOKEN — shared bearer for every consumer app. NEVER
  /// ship this in an APK build define; the Pro app should proxy
  /// through pro-api's /api/sign/notify which holds the token
  /// server-side. The class accepts the token directly so server-side
  /// callers can use it too.
  final String commsHubToken;

  final http.Client _http;

  /// Fire-and-forget: notifies the originator that [signerName] just
  /// signed [doc] at [signedAtMs] with optional [note]. Returns true
  /// iff the Hub accepted at least one channel. Failure is always
  /// non-fatal — the audit row is already committed.
  Future<bool> notifyOriginator({
    required PdfDocument doc,
    required String signerName,
    required String shortCode,
    required int signedAtMs,
    String? note,
  }) async {
    final email = doc.originatorEmail;
    final phone = doc.originatorPhone;
    if ((email == null || email.isEmpty) &&
        (phone == null || phone.isEmpty)) {
      return false; // no originator on file — share didn't carry it.
    }

    final timestampIso =
        DateTime.fromMillisecondsSinceEpoch(signedAtMs).toIso8601String();
    final docTitle = doc.title.isEmpty ? 'your document' : '"${doc.title}"';
    final body =
        '$signerName signed $docTitle on $timestampIso\n'
        'Audit code: $shortCode${note == null || note.isEmpty ? '' : '\nNote: $note'}\n'
        '\nThis is an automated notice from Interact Pro.';

    var anyOk = false;
    if (email != null && email.isNotEmpty) {
      anyOk |= await _send(
        channel: 'email',
        to: email,
        subject: 'Signed: $docTitle',
        body: body,
      );
    }
    if (phone != null && phone.isNotEmpty) {
      anyOk |= await _send(
        channel: 'sms',
        to: phone,
        subject: null,
        body: body,
      );
    }
    return anyOk;
  }

  Future<bool> _send({
    required String channel,
    required String to,
    String? subject,
    required String body,
  }) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('$commsHubBase/api/comms/send'),
            headers: {
              'Authorization': 'Bearer $commsHubToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'channel': channel,
              'to': to,
              if (subject != null) 'subject': subject,
              'body': body,
              'tags': ['interact-pro', 'signature-notify'],
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
      appLogger.w(
        'Comms Hub $channel send rejected: ${resp.statusCode} ${resp.body}',
      );
      return false;
    } catch (e) {
      appLogger.w('Comms Hub $channel send failed: $e');
      return false;
    }
  }
}
