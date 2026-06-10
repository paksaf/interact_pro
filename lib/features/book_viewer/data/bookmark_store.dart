// SPDX-License-Identifier: AGPL-3.0
//
// BookmarkStore — lightweight per-document bookmark persistence.
//
// We deliberately avoid a drift schema change here so this feature can
// ship without a migration. Bookmarks are small (a list of page
// numbers, 1-based) and keyed by a stable hash of the document path,
// so SharedPreferences is the right primitive. The PDF file itself
// doesn't change once imported; if the user moves it the hash drifts
// and bookmarks would be "lost" — that's fine for this v1.
//
// Persistence shape: prefs key `bookmarks.<pathHash>` holds a CSV of
// page numbers, e.g. "1,42,250,1015". Empty string = no bookmarks.
// CSV is more robust than JSON for a small int list and avoids the
// encoding tax on every read.
//
// Reading time + last-page (resume) live in adjacent prefs keys with
// the same hash prefix so future features can share the namespace.

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// 16-hex-char SHA1 prefix of the absolute PDF path. Stable across
/// app launches as long as the file stays put.
String bookmarkDocKey(String pdfPath) =>
    sha1.convert(utf8.encode(pdfPath)).toString().substring(0, 16);

class BookmarkStore {
  BookmarkStore(this._prefs);
  final SharedPreferences _prefs;

  static String _key(String pdfPath) => 'bookmarks.${bookmarkDocKey(pdfPath)}';
  static String _lastPageKey(String pdfPath) =>
      'lastpage.${bookmarkDocKey(pdfPath)}';

  /// Set of 1-based page numbers bookmarked in this PDF.
  Set<int> bookmarks(String pdfPath) {
    final raw = _prefs.getString(_key(pdfPath));
    if (raw == null || raw.isEmpty) return const <int>{};
    return raw
        .split(',')
        .map((s) => int.tryParse(s))
        .whereType<int>()
        .toSet();
  }

  Future<void> toggle(String pdfPath, int onePagePage) async {
    final set = {...bookmarks(pdfPath)};
    if (set.contains(onePagePage)) {
      set.remove(onePagePage);
    } else {
      set.add(onePagePage);
    }
    final csv = (set.toList()..sort()).join(',');
    if (csv.isEmpty) {
      await _prefs.remove(_key(pdfPath));
    } else {
      await _prefs.setString(_key(pdfPath), csv);
    }
  }

  bool isBookmarked(String pdfPath, int onePagePage) =>
      bookmarks(pdfPath).contains(onePagePage);

  /// Last viewed page (1-based) for resume-on-reopen. Returns null
  /// when there's no prior session for this file.
  int? lastPage(String pdfPath) => _prefs.getInt(_lastPageKey(pdfPath));

  Future<void> setLastPage(String pdfPath, int onePagePage) =>
      _prefs.setInt(_lastPageKey(pdfPath), onePagePage);

  // ── Reading-time accumulator ────────────────────────────────────
  // Stores cumulative seconds spent reading this PDF across all
  // sessions. BookViewer adds the current session's elapsed seconds
  // on dispose. Surfaced in the document detail sheet + can drive a
  // "Currently reading" row on home later.

  static String _readingTimeKey(String pdfPath) =>
      'readingtime.${bookmarkDocKey(pdfPath)}';

  /// Cumulative reading seconds. Returns 0 for fresh PDFs.
  int totalReadingSeconds(String pdfPath) =>
      _prefs.getInt(_readingTimeKey(pdfPath)) ?? 0;

  /// Add `seconds` to the running total. Idempotent under the
  /// keyed namespace.
  Future<void> addReadingSeconds(String pdfPath, int seconds) async {
    if (seconds <= 0) return;
    final cur = totalReadingSeconds(pdfPath);
    await _prefs.setInt(_readingTimeKey(pdfPath), cur + seconds);
  }

  /// Human-readable accumulated reading time for display.
  /// "12 min" / "1 h 23 min" / "Just started" for < 60s.
  String formatReadingTime(String pdfPath) {
    final total = totalReadingSeconds(pdfPath);
    if (total < 60) return 'Just started';
    final mins = total ~/ 60;
    if (mins < 60) return '$mins min';
    final hours = mins ~/ 60;
    final rem = mins % 60;
    return rem == 0 ? '$hours h' : '$hours h $rem min';
  }
}

final bookmarkStoreProvider = FutureProvider<BookmarkStore>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return BookmarkStore(prefs);
});
