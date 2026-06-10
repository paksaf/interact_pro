import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';

/// Resolves the canonical on-disk locations the app uses.
class AppPaths {
  AppPaths(this._root);
  final Directory _root;

  Directory get pdfDir => Directory(p.join(_root.path, AppConstants.localPdfFolder));
  Directory get scansDir => Directory(p.join(_root.path, AppConstants.scannedFolder));
  Directory get thumbsDir =>
      Directory(p.join(_root.path, AppConstants.thumbnailsFolder));

  /// Files received over the LAN from paired peers (image/video/text/etc.)
  /// land here. PDFs go in [pdfDir] so they appear in Recents — everything
  /// else stays here until a per-kind viewer / library is built.
  Directory get incomingDir => Directory(p.join(_root.path, 'incoming'));

  Future<void> ensureDirs() async {
    for (final Directory d in <Directory>[pdfDir, scansDir, thumbsDir, incomingDir]) {
      if (!d.existsSync()) {
        await d.create(recursive: true);
      }
    }
  }

  String pdfPathFor(String filename) => p.join(pdfDir.path, filename);
  String scanPathFor(String filename) => p.join(scansDir.path, filename);
  String incomingPathFor(String filename) => p.join(incomingDir.path, filename);
}

final FutureProvider<AppPaths> appPathsProvider =
    FutureProvider<AppPaths>((Ref ref) async {
  final Directory dir = await getApplicationDocumentsDirectory();
  final AppPaths paths = AppPaths(dir);
  await paths.ensureDirs();
  return paths;
});
