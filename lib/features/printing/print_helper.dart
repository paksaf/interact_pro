import 'dart:io';

import 'package:printing/printing.dart';

/// Print actions backed by the OS native print sheet.
///
/// Why this is mostly a one-page file: AirPrint (iOS / macOS) and the
/// Android print framework already do mDNS-based printer discovery,
/// paper size selection, copies, color/B&W, and queueing. We just hand
/// the bytes to the OS and let the user pick the printer they want.
///
/// IMPORTANT — iOS local-network sandboxing:
///   For AirPrint to actually FIND your Wi-Fi printer (Brother, HP,
///   Canon, Epson, etc.) the host app's `Info.plist` must declare the
///   IPP service types under `NSBonjourServices`. Without them, iOS
///   shows "No AirPrint Printers Found" even when the printer is
///   reachable. See ios/Runner/Info.plist for the live list.
class PrintHelper {
  PrintHelper._();

  /// Open the system print sheet for [pdfFile]. Returns `true` if the
  /// user actually sent it to a printer, `false` if they cancelled or
  /// no printer was found.
  ///
  /// The caller should treat `false` as "user wants out — but maybe
  /// also wants to save / share / send to Drive instead", and surface
  /// those alternatives via the bottom-sheet pattern in `print_fallback_sheet.dart`.
  static Future<bool> printPdf({
    required File pdfFile,
    String? jobName,
  }) async {
    final bytes = await pdfFile.readAsBytes();
    return Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: jobName ?? pdfFile.uri.pathSegments.last,
    );
  }

  /// Quick "Share via system sheet" alternative — useful when the user
  /// wants AirDrop / Save to Files / Mail rather than print specifically.
  static Future<void> sharePdf({
    required File pdfFile,
    String? subject,
  }) async {
    final bytes = await pdfFile.readAsBytes();
    await Printing.sharePdf(
      bytes: bytes,
      filename: pdfFile.uri.pathSegments.last,
      subject: subject,
    );
  }

  /// True if the OS has a print pipeline available. False on platforms
  /// where Printing's native side hasn't shipped (mostly headless
  /// Linux). Use to gate the print menu item entirely.
  static Future<bool> isAvailable() => Printing.info().then((i) => i.canPrint);

  /// True if the OS thinks it can SEE at least one printer right now.
  /// On iOS this depends on NSBonjourServices being correctly declared
  /// AND the Local Network permission being granted AND a printer being
  /// reachable. We can't introspect the printer list directly from
  /// Flutter, so the boolean is a best-effort proxy: if `info()` says
  /// directPrint is supported, the OS dialog will at least browse.
  static Future<bool> canDiscoverPrinters() async {
    try {
      final info = await Printing.info();
      return info.canPrint && info.directPrint;
    } catch (_) {
      return false;
    }
  }
}
