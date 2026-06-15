// SPDX-License-Identifier: AGPL-3.0
//
// GrowthHooks — Gate-C loop helpers (win-moment review prompt + invite-a-signer
// referral). Deliberately does NOT create its own analytics client: Pro already
// has `analyticsServiceProvider` (see core/analytics/analytics_service.dart), so
// events flow through that one pipeline. Call sites pass their existing
// `ref.read(analyticsServiceProvider).track` as the `track` arg.
//
// Wiring (per GROWTH_WIRING.md):
//   • after a doc is signed → GrowthHooks.docSigned(track)
//   • after a doc is cast   → GrowthHooks.docCast(track)
//   • adding a co-signer    → final url = GrowthHooks.inviteSigner(inviterId: id, track: track)
//   • app layer sets GrowthHooks.nativeReview once (in_app_review) — keeps the
//     in_app_review dependency out of this file.

import 'package:flutter/foundation.dart';

import '../analytics/analytics_service.dart';
import 'referral.dart';
import 'review_prompt.dart';

typedef TrackFn = Future<void> Function(String event, {Map<String, dynamic>? properties});

class GrowthHooks {
  GrowthHooks._();

  static const _base = 'https://pro.interactpak.com';

  /// in_app_review trigger, injected from the app layer (e.g. in main or a
  /// provider): `GrowthHooks.nativeReview = () => InAppReview.instance.requestReview().then((_) => true);`
  static Future<bool> Function()? nativeReview;

  // ── Win moments ─────────────────────────────────────────────────────────
  static Future<void> docSigned(TrackFn track) => _win(track, 'doc_signed');
  static Future<void> docCast(TrackFn track) => _win(track, 'doc_cast');

  static Future<void> _win(TrackFn track, String kind) async {
    try {
      await track(AnalyticsEvents.winMoment, properties: {'kind': kind});
      await ReviewPrompt.recordWin();
      final trigger = nativeReview;
      if (trigger != null) await ReviewPrompt.maybePrompt(trigger);
    } catch (e) {
      if (kDebugMode) debugPrint('GrowthHooks._win($kind) failed: $e');
    }
  }

  // ── Invite-a-signer loop ────────────────────────────────────────────────
  /// Returns an attributed invite URL to share with a co-signer (the invitee
  /// needs Pro to sign → the link is the referral). Null on failure (caller
  /// falls back to a plain link / its normal flow).
  static String? inviteSigner({
    required String inviterId,
    TrackFn? track,
    String? docTitle,
  }) {
    try {
      final inv = Referral.buildInviteLink(
        _base,
        app: 'interactpro',
        inviterId: inviterId,
        campaign: 'sign',
      );
      track?.call(AnalyticsEvents.inviteSent, properties: {
        'campaign': 'sign',
        'inviteId': inv.inviteId,
        if (docTitle != null) 'docTitle': docTitle,
      });
      return inv.url;
    } catch (e) {
      if (kDebugMode) debugPrint('GrowthHooks.inviteSigner failed: $e');
      return null;
    }
  }
}
