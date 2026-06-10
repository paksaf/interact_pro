import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../../../../core/constants/app_constants.dart';

/// Thin wrapper over the googleapis Drive v3 SDK + google_sign_in.
///
/// PRD GDR-01: only request the `drive.file` scope so we touch nothing the
/// app didn't create. Reduces OAuth consent friction and risk.
class GoogleDriveDataSource {
  GoogleDriveDataSource()
      : _signIn = GoogleSignIn(scopes: AppConstants.driveScopes);

  final GoogleSignIn _signIn;

  GoogleSignInAccount? _account;
  drive.DriveApi? _api;

  GoogleSignInAccount? get currentAccount => _account;

  Future<GoogleSignInAccount?> signIn() async {
    _account = await _signIn.signIn();
    await _refreshApi();
    return _account;
  }

  Future<GoogleSignInAccount?> silentSignIn() async {
    _account = await _signIn.signInSilently();
    await _refreshApi();
    return _account;
  }

  Future<void> signOut() async {
    await _signIn.signOut();
    _account = null;
    _api = null;
  }

  Future<void> _refreshApi() async {
    if (_account == null) return;
    final client = await _signIn.authenticatedClient();
    if (client != null) _api = drive.DriveApi(client);
  }

  drive.DriveApi get api {
    final a = _api;
    if (a == null) {
      throw StateError('Drive API not initialised — sign in first.');
    }
    return a;
  }

  Future<String> ensureFolder(String name) async {
    final query =
        "mimeType = 'application/vnd.google-apps.folder' and name = '$name' and trashed = false";
    final list = await api.files.list(q: query, $fields: 'files(id,name)');
    final existing = (list.files ?? const <drive.File>[])
        .where((f) => f.name == name && f.id != null)
        .firstOrNull;
    if (existing?.id != null) return existing!.id!;

    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    return created.id!;
  }

  Future<String> uploadPdf(String path, {String? folderName}) async {
    final file = File(path);
    final media = drive.Media(file.openRead(), await file.length());
    final metadata = drive.File()..name = path.split('/').last;
    if (folderName != null) {
      metadata.parents = [await ensureFolder(folderName)];
    }
    final created = await api.files.create(metadata, uploadMedia: media);
    return created.id!;
  }

  Future<void> updatePdfContent(String driveFileId, String path) async {
    final file = File(path);
    final media = drive.Media(file.openRead(), await file.length());
    await api.files.update(drive.File(), driveFileId, uploadMedia: media);
  }

  Future<void> downloadPdf(String driveFileId, String saveToPath) async {
    final media = await api.files.get(
      driveFileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final out = File(saveToPath);
    final sink = out.openWrite();
    await media.stream.pipe(sink);
    await sink.close();
  }

  Future<void> deleteFile(String driveFileId) async {
    await api.files.delete(driveFileId);
  }

  Future<List<drive.File>> listInFolder(String? folderName) async {
    String? folderId;
    if (folderName != null) folderId = await ensureFolder(folderName);
    final q = folderId != null
        ? "'$folderId' in parents and trashed = false"
        : "trashed = false and mimeType = 'application/pdf'";
    final result = await api.files.list(
      q: q,
      $fields: 'files(id,name,modifiedTime,size,mimeType)',
    );
    return result.files ?? const [];
  }
}
