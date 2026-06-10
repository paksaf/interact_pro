import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' as printing;

import '../../../core/error/failures.dart';
import '../../../core/storage/app_paths.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../viewer/data/repositories/pdf_repository_impl.dart';
import '../domain/supported_languages.dart';

/// Turns a recognised transcript into a one-or-more-page PDF and indexes
/// it so it shows up in Recents. The screen calls this from a "Save as
/// PDF" button and pushes the viewer with the resulting path.
///
/// Font strategy (offline-first):
///   1. Try to load a TTF bundled in `assets/fonts/` for the language's
///      script. We have NotoNaskhArabic, Gurmukhi, AppleGothic (Korean),
///      and a few others — fully offline, zero network.
///   2. If no bundled font for the script, try `PdfGoogleFonts` (network
///      on first call, then cached in app docs). Useful for Devanagari /
///      Han / Cyrillic / Japanese where we don't ship a TTF.
///   3. Final fallback: built-in Helvetica. Renders boxes for non-Latin
///      glyphs but at least the file is created.
///
/// All script-specific fonts are also added as `fontFallback` so mixed
/// content (an Urdu paragraph that quotes an English title, etc.) renders
/// every glyph rather than showing tofu where the primary font lacks
/// coverage.
final transcriptToPdfProvider = Provider<TranscriptToPdf>((ref) {
  return TranscriptToPdf(ref);
});

class TranscriptToPdf {
  TranscriptToPdf(this._ref);
  final Ref _ref;

  /// In-memory cache for bundled fonts. Loading a TTF off the asset
  /// bundle is cheap (~10–100ms for our biggest one), but doing it on
  /// every PDF save during a multi-export session is wasteful. The
  /// cache lives for the provider's lifetime.
  static final Map<String, pw.Font> _bundledFontCache = {};

  /// Returns the path of the saved PDF. The caller is responsible for
  /// pushing the viewer / refreshing the recents list — this method is
  /// pure I/O. The PDF is dropped into the same documents folder as
  /// scanned PDFs and OCR exports.
  Future<Result<String>> save({
    required String text,
    required String languageTag,
    String? title,
  }) async {
    if (text.trim().isEmpty) {
      return const Result.err(StorageFailure('Nothing to save — buffer is empty.'));
    }

    try {
      final language = HandwritingLanguage.byTag(languageTag);
      final fonts = await _resolveFonts(language);
      final document = _buildDocument(
        text: text.trim(),
        title: title,
        language: language,
        fonts: fonts,
      );

      final paths = await _ref.read(appPathsProvider.future);
      final outName = _sanitiseFileName(
        title?.trim().isNotEmpty == true
            ? title!.trim()
            : 'Handwriting_${DateTime.now().millisecondsSinceEpoch}',
      );
      final out = File(p.join(paths.pdfDir.path, '$outName.pdf'));
      await out.writeAsBytes(await document.save());

      // Index into drift so RecentDocuments picks it up.
      final repo = await _ref.read(pdfRepositoryProvider.future);
      await repo.open(out.path);

      return Result.ok(out.path);
    } catch (e, st) {
      appLogger.e('TranscriptToPdf.save failed', error: e, stackTrace: st);
      return Result.err(StorageFailure('Could not save PDF', cause: e));
    }
  }

  /// Resolve a primary font + a set of glyph fallbacks for [language].
  /// Tries bundled assets first (offline) and then falls back to Google
  /// Fonts on the network.
  Future<_FontPair> _resolveFonts(HandwritingLanguage language) async {
    pw.Font? primary;

    // 1) Offline bundled.
    final bundledPath = _bundledFontPathForScript(language.script);
    if (bundledPath != null) {
      primary = await _loadBundled(bundledPath);
    }

    // 2) Online Google fonts as backup.
    if (primary == null) {
      try {
        primary = await _googleFontForScript(language.script);
      } catch (e) {
        appLogger.w('Google font for ${language.script} unavailable: $e');
      }
    }

    // Fallbacks: every bundled non-Latin font we have, plus Noto Sans if
    // we managed to load it once. Using all of them as fallbacks gives
    // the renderer every glyph we ship before it has to draw a box.
    final fallbacks = <pw.Font>[];
    for (final entry in _scriptToBundledFont.entries) {
      if (entry.value == bundledPath) continue;
      final f = await _loadBundled(entry.value);
      if (f != null) fallbacks.add(f);
    }
    try {
      fallbacks.add(await printing.PdfGoogleFonts.notoSansRegular());
    } catch (_) {
      // Silently — universal Latin fallback below catches us anyway.
    }
    return _FontPair(primary: primary, fallbacks: fallbacks);
  }

  /// Mapping from script tag (HandwritingLanguage.script) → asset path of
  /// a bundled TTF that covers that script. Add new entries here when
  /// dropping new font assets in.
  static const Map<String, String> _scriptToBundledFont = {
    'Arabic': 'assets/fonts/NotoNaskhArabic-Regular.ttf',
    'Gurmukhi': 'assets/fonts/Gurmukhi.ttf',
    'Hangul': 'assets/fonts/AppleGothic.ttf',
    // Latin is handled by built-in Helvetica — no asset needed.
    // Devanagari, Han, Japanese, Cyrillic: no bundled asset yet, so
    // the resolver falls through to PdfGoogleFonts for those scripts.
  };

  String? _bundledFontPathForScript(String script) =>
      _scriptToBundledFont[script];

  Future<pw.Font?> _loadBundled(String assetPath) async {
    final cached = _bundledFontCache[assetPath];
    if (cached != null) return cached;
    try {
      final bytes = await rootBundle.load(assetPath);
      final font = pw.Font.ttf(bytes);
      _bundledFontCache[assetPath] = font;
      return font;
    } catch (e) {
      appLogger.w('Bundled font $assetPath load failed: $e');
      return null;
    }
  }

  Future<pw.Font?> _googleFontForScript(String script) async {
    switch (script) {
      case 'Devanagari':
        return printing.PdfGoogleFonts.notoSansDevanagariRegular();
      case 'Han':
        return printing.PdfGoogleFonts.notoSansSCRegular();
      case 'Japanese':
        return printing.PdfGoogleFonts.notoSansJPRegular();
      case 'Hangul':
        // Backup if the bundled AppleGothic isn't there.
        return printing.PdfGoogleFonts.notoSansKRRegular();
      case 'Cyrillic':
        return printing.PdfGoogleFonts.notoSansRegular();
      case 'Arabic':
      case 'Gurmukhi':
        // Bundled assets handle these; only reached if asset load
        // failed at runtime (unusual). Hand back a Google equivalent.
        return script == 'Arabic'
            ? printing.PdfGoogleFonts.notoSansArabicRegular()
            : printing.PdfGoogleFonts.notoSansGurmukhiRegular();
      default:
        return null;
    }
  }

  pw.Document _buildDocument({
    required String text,
    required String? title,
    required HandwritingLanguage language,
    required _FontPair fonts,
  }) {
    final doc = pw.Document(
      title: title ?? 'Handwriting transcript',
      author: 'Interact Pro',
    );

    final theme = pw.ThemeData.withFont(
      base: fonts.primary ?? pw.Font.helvetica(),
      bold: fonts.primary ?? pw.Font.helveticaBold(),
      fontFallback: [
        ...fonts.fallbacks,
        // Always include Helvetica last so ASCII punctuation and
        // numerals render even when the primary font is glyph-sparse.
        pw.Font.helvetica(),
      ],
    );

    final textDirection =
        language.rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;

    doc.addPage(pw.MultiPage(
      pageFormat: pdf.PdfPageFormat.a4.copyWith(
        marginTop: 56,
        marginLeft: 48,
        marginRight: 48,
        marginBottom: 56,
      ),
      theme: theme,
      textDirection: textDirection,
      header: (ctx) => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 16),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              title ?? 'Handwriting transcript',
              style: const pw.TextStyle(
                fontSize: 11,
                color: pdf.PdfColors.grey700,
              ),
              textDirection: textDirection,
            ),
            pw.Text(
              language.label,
              style: const pw.TextStyle(
                fontSize: 11,
                color: pdf.PdfColors.grey500,
              ),
            ),
          ],
        ),
      ),
      footer: (ctx) => pw.Container(
        alignment: language.rtl
            ? pw.Alignment.bottomLeft
            : pw.Alignment.bottomRight,
        margin: const pw.EdgeInsets.only(top: 16),
        child: pw.Text(
          '${ctx.pageNumber} / ${ctx.pagesCount}',
          style: const pw.TextStyle(
            fontSize: 10,
            color: pdf.PdfColors.grey500,
          ),
        ),
      ),
      build: (ctx) => [
        pw.Paragraph(
          text: text,
          style: const pw.TextStyle(fontSize: 14, lineSpacing: 6),
          textAlign:
              language.rtl ? pw.TextAlign.right : pw.TextAlign.left,
        ),
      ],
    ),);
    return doc;
  }

  /// Strip path separators and characters Android / iOS / macOS
  /// disagree about. Keep it conservative — we'd rather emit a slightly
  /// uglier filename than fail silently on a save.
  String _sanitiseFileName(String raw) {
    final stripped = raw.replaceAll(RegExp(r'[^\w\s\-\.\(\)]'), '');
    final collapsed = stripped.replaceAll(RegExp(r'\s+'), '_');
    return collapsed.isEmpty
        ? 'Handwriting_${DateTime.now().millisecondsSinceEpoch}'
        : collapsed;
  }
}

class _FontPair {
  const _FontPair({this.primary, this.fallbacks = const []});
  final pw.Font? primary;
  final List<pw.Font> fallbacks;
}
