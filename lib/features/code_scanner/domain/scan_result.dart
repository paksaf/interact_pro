/// What a single barcode / QR scan returned.
///
/// Wraps just enough of the ML Kit detection result to drive the result
/// sheet — raw value, format, and a [kind] discriminator the UI uses to
/// decide which quick-action chip to surface (Open URL vs. Call vs. ...).
class ScannedCode {
  const ScannedCode({
    required this.rawValue,
    required this.format,
    required this.kind,
    required this.scannedAt,
  });

  /// The literal text decoded from the code. For URLs this is the URL,
  /// for raw-text QRs the text, for vCards the unparsed vCard payload.
  final String rawValue;

  /// Human-readable format label — "QR", "EAN-13", "Code 128", etc.
  /// Used purely for display; the [kind] derived from rawValue is what
  /// drives behaviour.
  final String format;

  /// Higher-level classification we infer from rawValue. Drives which
  /// action chips show up: open URL, dial, compose email, copy, share.
  final ScannedCodeKind kind;

  final DateTime scannedAt;
}

enum ScannedCodeKind {
  url,
  email,
  phone,
  wifi,
  geo,
  vcard,
  text,
}

/// Cheap heuristics — no parsing libraries needed. Each branch matches a
/// well-known QR convention; falls through to [ScannedCodeKind.text].
ScannedCodeKind classifyCode(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return ScannedCodeKind.text;
  final lower = v.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return ScannedCodeKind.url;
  }
  if (lower.startsWith('mailto:') || _looksLikeEmail(v)) {
    return ScannedCodeKind.email;
  }
  if (lower.startsWith('tel:') || lower.startsWith('sms:')) {
    return ScannedCodeKind.phone;
  }
  if (lower.startsWith('wifi:')) return ScannedCodeKind.wifi;
  if (lower.startsWith('geo:')) return ScannedCodeKind.geo;
  if (lower.startsWith('begin:vcard')) return ScannedCodeKind.vcard;
  return ScannedCodeKind.text;
}

bool _looksLikeEmail(String v) {
  final at = v.indexOf('@');
  if (at <= 0 || at == v.length - 1) return false;
  return !v.contains(' ') && v.contains('.', at);
}

/// Parse a `WIFI:S:<ssid>;T:<auth>;P:<pass>;H:<hidden>;;` payload into a
/// flat map. Returns null if [raw] doesn't look like a Wi-Fi QR.
Map<String, String>? parseWifiPayload(String raw) {
  if (!raw.toLowerCase().startsWith('wifi:')) return null;
  final body = raw.substring(5);
  final out = <String, String>{};
  for (final part in body.split(';')) {
    final idx = part.indexOf(':');
    if (idx <= 0) continue;
    out[part.substring(0, idx).toUpperCase()] = part.substring(idx + 1);
  }
  return out.isEmpty ? null : out;
}
