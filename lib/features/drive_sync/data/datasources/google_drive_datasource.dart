import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../../../../core/constants/app_constants.dart';
import '../../../../core/device/device_info.dart';
import 'google_device_flow.dart';

/// Thin wrapper over the googleapis Drive v3 SDK + google_sign_in.
///
/// Two auth paths feed the same [api]:
///   • Phone — GoogleSignIn (interactive / silent), driveScopes.
///   • Android TV — OAuth Device Flow tokens persisted by
///     [DriveDeviceFlowScreen]; see [ensureDeviceFlowSession]. FIXED
///     2026-06-11: previously NOTHING consumed those tokens, so the TV
///     paired successfully ("Device connected") and then bounced straight
///     back to the sign-in screen — currentUser() only knew GoogleSignIn.
class GoogleDriveDataSource {
  GoogleDriveDataSource()
      : _signIn = GoogleSignIn(scopes: AppConstants.driveScopes);

  final GoogleSignIn _signIn;

  GoogleSignInAccount? _account;
  drive.DriveApi? _api;

  GoogleSignInAccount? get currentAccount => _account;

  GoogleDeviceFlowAuth? _deviceFlowAuth;
  GoogleDeviceFlowAuth get _deviceFlow =>
      _deviceFlowAuth ??= GoogleDeviceFlowAuth(
        clientId: AppConstants.driveTvClientId,
        clientSecret: AppConstants.driveTvClientSecret,
        scopes: AppConstants.driveTvScopes,
      );

  /// TV path: (re)build the Drive API client from the persisted Device
  /// Flow tokens (auto-refreshing via the stored refresh_token). Returns
  /// true when a live session exists. Cheap to call on every screen
  /// refresh — it mints a fresh client so token expiry never strands a
  /// long-running browser session.
  Future<bool> ensureDeviceFlowSession() async {
    if (!DeviceInfo.isAndroidTv || !AppConstants.driveTvConfigured) {
      return false;
    }
    final client = await _deviceFlow.authenticatedClient();
    if (client == null) return false;
    _api = drive.DriveApi(client);
    return true;
  }

  /// Drop the TV device-flow tokens (Drive "disconnect" on TV).
  Future<void> signOutDeviceFlow() async {
    await _deviceFlow.signOut();
    _api = null;
  }

  /// One-line TV auth diagnostic for the signed-out screen — release
  /// builds log nothing to logcat, so field debugging needs eyes-on-UI.
  Future<String> tvAuthDebug() async {
    final tv = DeviceInfo.isAndroidTv;
    final cfg = AppConstants.driveTvConfigured;
    var token = 'MISSING';
    var err = '';
    var refresh = '';
    try {
      if (await _deviceFlow.hasRefreshToken()) {
        token = 'present';
        // Token exists yet we're on the signed-out screen — ask Google
        // WHY the refresh fails and show its verdict verbatim.
        refresh = ' ${await _deviceFlow.refreshDebug()}';
      }
    } catch (e) {
      err = ' storageErr:$e';
    }
    return 'tv:$tv cfg:$cfg refreshToken:$token$refresh$err';
  }

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

  /// Phone-side "Show on TV": files.copy creates an APP-OWNED copy inside
  /// the Interact Pro folder. drive.file visibility is per-creating-app,
  /// so the copy becomes listable on the TV's device-flow session — the
  /// original (uploaded via drive.google.com) never will be. 2026-06-11.
  Future<void> copyToAppFolder(String fileId, String name) async {
    final folderId = await ensureFolder(AppConstants.driveBackupFolderName);
    await api.files.copy(
      drive.File()
        ..name = name
        ..parents = [folderId],
      fileId,
    );
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
