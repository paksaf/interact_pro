import 'dart:ui' show Rect;

/// PRD SIGN-01..06.
enum SignatureKind {
  /// SIGN-01: drawn with finger / stylus.
  drawn,
  /// SIGN-02: imported from camera / gallery.
  imported,
  /// Typed name in a script font.
  typed,
  /// SIGN-05: certificate-based digital signature (PKCS#12).
  certificate,
}

/// PRD SIGN-03: up to 5 saved presets the user can quickly tap.
class SignaturePreset {
  const SignaturePreset({
    required this.id,
    required this.name,
    required this.kind,
    required this.assetPath,
    required this.createdAt,
  });
  final String id;
  final String name;
  final SignatureKind kind;

  /// PNG (drawn / imported / typed) or `.p12` (certificate).
  final String assetPath;
  final DateTime createdAt;
}

/// PRD SIGN-04: a placed signature on a specific page.
class PlacedSignature {
  const PlacedSignature({
    required this.id,
    required this.preset,
    required this.pageIndex,
    required this.bounds,
    required this.placedAt,
  });
  final String id;
  final SignaturePreset preset;
  final int pageIndex;
  final Rect bounds;
  final DateTime placedAt;
}
