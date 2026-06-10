/// Granular entitlements that a Pro subscription unlocks.
///
/// Free users get [proFree]; Pro subscribers get [proAll].
/// Adding a new gated feature: append a value here, add it to [proAll],
/// then call `ProGate(entitlement: ...)` around the UI you want to lock.
enum ProEntitlement {
  /// Always-available marker so widgets can express "free baseline".
  free,

  // ── Paid features ───────────────────────────────────────────────
  unlimitedOcr,         // free tier capped at N pages/month
  voiceReadAloud,       // TTS — flutter_tts
  voiceDictation,       // STT — speech_to_text
  translation,          // DeepSeek-powered AI translation
  hotspots,             // Interactive PDF hotspots
  advancedRtl,          // Polished Urdu / Arabic / Hebrew shaping
  unlimitedDriveSync,   // free tier capped at N MB
  noWatermark,          // remove the export watermark
}

const proAll = <ProEntitlement>{
  ProEntitlement.free,
  ProEntitlement.unlimitedOcr,
  ProEntitlement.voiceReadAloud,
  ProEntitlement.voiceDictation,
  ProEntitlement.translation,
  ProEntitlement.hotspots,
  ProEntitlement.advancedRtl,
  ProEntitlement.unlimitedDriveSync,
  ProEntitlement.noWatermark,
};

const proFree = <ProEntitlement>{ProEntitlement.free};

/// Why someone has Pro entitlements right now.
enum ProSource { none, trial, paid }

class ProSubscription {
  const ProSubscription({
    required this.isPro,
    required this.entitlements,
    this.source = ProSource.none,
    this.productId,
    this.expiresAt,
    this.trialEndsAt,
  });

  /// True for either a paid subscription OR an active trial. UI gates should
  /// check this — trial users see the full feature set.
  final bool isPro;
  final Set<ProEntitlement> entitlements;
  final ProSource source;
  final String? productId;
  final DateTime? expiresAt;

  /// When the current trial ends (null if no trial active).
  final DateTime? trialEndsAt;

  bool get isTrial => source == ProSource.trial;
  bool get isPaid => source == ProSource.paid;

  /// Whole days remaining on the trial (0 if no trial or expired).
  int get trialDaysRemaining {
    if (trialEndsAt == null) return 0;
    final hours = trialEndsAt!.difference(DateTime.now()).inHours;
    return hours <= 0 ? 0 : (hours / 24).ceil();
  }

  static const ProSubscription free = ProSubscription(
    isPro: false,
    entitlements: proFree,
  );

  factory ProSubscription.trial(DateTime endsAt) => ProSubscription(
        isPro: true,
        entitlements: proAll,
        source: ProSource.trial,
        trialEndsAt: endsAt,
      );

  factory ProSubscription.paid({
    required String productId,
    DateTime? expiresAt,
  }) =>
      ProSubscription(
        isPro: true,
        entitlements: proAll,
        source: ProSource.paid,
        productId: productId,
        expiresAt: expiresAt,
      );

  bool has(ProEntitlement e) => entitlements.contains(e);
}
