/// Authenticated user. Persisted alongside the JWT in secure storage so
/// the app can render the right name / avatar without a network round-
/// trip on cold start.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.phone,
    required this.displayName,
    required this.role,
    required this.trialEndsAt,
    required this.proActive,
  });

  final String id;
  final String? email;
  final String? phone;
  final String displayName;

  /// Server-side role string. The client treats anything other than
  /// `admin` as a regular user; we don't enforce role gates client-side
  /// for security, only for UI gating (admin nav item visibility, etc.).
  final String role;

  /// When the free trial ends. `null` means no trial — the user signed
  /// up after trials ended OR was provisioned with Pro from day one.
  final DateTime? trialEndsAt;

  /// True iff the user has an active Pro subscription according to the
  /// server (paid via in-app purchase OR via web Stripe). The client
  /// re-checks this on every cold start.
  final bool proActive;

  bool get isAdmin => role == 'admin';
  bool get hasActiveTrial =>
      trialEndsAt != null && trialEndsAt!.isAfter(DateTime.now());
  bool get hasFullAccess => proActive || hasActiveTrial;

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'phone': phone,
        'displayName': displayName,
        'role': role,
        'trialEndsAt': trialEndsAt?.toIso8601String(),
        'proActive': proActive,
      };

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      displayName: (json['displayName'] as String?) ?? 'User',
      role: (json['role'] as String?) ?? 'user',
      trialEndsAt: json['trialEndsAt'] == null
          ? null
          : DateTime.tryParse(json['trialEndsAt'] as String),
      proActive: (json['proActive'] as bool?) ?? false,
    );
  }
}
