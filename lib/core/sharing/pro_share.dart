import 'package:share_plus/share_plus.dart';

/// Centralised outbound-share wrapper (Gate C growth loop).
///
/// Interact Pro shares a LOT — OCR text, handwriting transcripts, identified
/// images, measurement annotations, exported pages. Every one of those shares
/// previously went out as bare content with no path back to the app. This
/// wrapper appends a short branded install line to each share, so anyone who
/// receives a result has a one-tap way to get Pro — turning the app's existing
/// share behaviour into an acquisition surface (the cheapest viral loop there
/// is: the product markets itself every time a user shares its output).
class ProShare {
  /// Canonical landing/install page (interactpak.com/apps/interact-pro hosts
  /// the Android + web download links).
  static const String installUrl = 'https://interactpak.com/apps/interact-pro';

  static String footer() =>
      '— Made with Interact Pro 📄  Get the app: $installUrl';

  /// Append the install footer to a (possibly empty) message body.
  static String withFooter(String? body) {
    final b = (body == null || body.trim().isEmpty) ? '' : '${body.trimRight()}\n\n';
    return '$b${footer()}';
  }

  /// Text-only share with the install footer appended.
  static Future<ShareResult> text(String body, {String? subject}) =>
      SharePlus.instance.share(ShareParams(text: withFooter(body), subject: subject));

  /// File share — the accompanying message carries the install footer so the
  /// link travels with attachments too (WhatsApp/email show the text alongside).
  static Future<ShareResult> files(List<XFile> files,
          {String? text, String? subject}) =>
      SharePlus.instance.share(
          ShareParams(files: files, text: withFooter(text), subject: subject));
}
