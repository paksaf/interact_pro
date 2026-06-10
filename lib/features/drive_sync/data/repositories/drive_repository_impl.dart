import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/device/device_info.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/repositories/drive_repository.dart';
import '../datasources/google_drive_datasource.dart';

final driveRepositoryProvider = Provider<DriveRepository>((ref) {
  return DriveRepositoryImpl(GoogleDriveDataSource());
});

class DriveRepositoryImpl implements DriveRepository {
  DriveRepositoryImpl(this._ds);
  final GoogleDriveDataSource _ds;

  @override
  Future<Result<DriveUser>> signIn() async {
    try {
      // Try silent sign-in first. On Android TV / Google TV this is
      // the path that actually works — the system already has a Google
      // account signed in (TV Settings → Accounts), and silentSignIn
      // pulls it without ever launching the interactive Activity that
      // fails to render properly on leanback themes. Only fall back to
      // the interactive sign-in if no system account is available.
      var account = await _ds.silentSignIn();
      account ??= await _ds.signIn();

      if (account == null) {
        return const Result.err(AuthFailure(
          'Sign-in cancelled. On Android TV, sign in to your Google '
          'account in TV Settings → Accounts first, then come back here '
          'and tap Sign in again. On Fire TV, install Google Play '
          'Services or use the device-code flow at google.com/device.',
        ),);
      }
      return Result.ok(DriveUser(
        email: account.email,
        displayName: account.displayName ?? account.email,
        photoUrl: account.photoUrl,
      ),);
    } catch (e) {
      // Surface the actual exception text — silently swallowing it
      // (as we did before) hid useful diagnostics like "ApiException:
      // 10" (DEVELOPER_ERROR — wrong SHA-1 in Cloud Console) or
      // "ApiException: 12500" (sign-in cancelled).
      //
      // TV-specific note: Sony Bravia / Google TV without Chrome
      // installed surfaces "Error 400: invalid_request" because
      // google_sign_in's Custom Tabs path can't render the consent
      // screen — the fallback browser ships malformed OAuth params.
      // Same APK + same OAuth client work on phone because the phone
      // has Chrome. Detect and give the user a clear fix to try
      // before they go hunting through Google Cloud Console.
      final raw = e.toString();
      final looksLikeTvCustomTabsFailure = DeviceInfo.isAndroidTv &&
          (raw.contains('400') ||
              raw.contains('invalid_request') ||
              raw.contains('ApiException: 8') ||
              raw.contains('ApiException: 7'));
      if (looksLikeTvCustomTabsFailure) {
        return Result.err(AuthFailure(
          'Drive sign-in on this TV needs Google Chrome installed. '
          'Open the Play Store on your TV → install "Google Chrome" → '
          'come back here and tap Sign in again. '
          '(The TV\'s built-in browser does not support the secure '
          'sign-in flow Google requires.) '
          'Underlying error: $e',
          cause: e,
        ),);
      }
      return Result.err(AuthFailure('Drive sign-in failed: $e', cause: e));
    }
  }

  @override
  Future<Result<void>> signOut() async {
    try {
      await _ds.signOut();
      return const Result.ok(null);
    } catch (e) {
      return Result.err(AuthFailure('Sign-out failed', cause: e));
    }
  }

  @override
  Future<DriveUser?> currentUser() async {
    final a = _ds.currentAccount ?? await _ds.silentSignIn();
    if (a == null) return null;
    return DriveUser(
      email: a.email,
      displayName: a.displayName ?? a.email,
      photoUrl: a.photoUrl,
    );
  }

  @override
  Future<Result<String>> upload(String localPath, {String? folderName}) async {
    try {
      final id = await _ds.uploadPdf(
        localPath,
        folderName: folderName ?? AppConstants.driveBackupFolderName,
      );
      return Result.ok(id);
    } catch (e) {
      return Result.err(NetworkFailure('Upload failed', cause: e));
    }
  }

  @override
  Future<Result<String>> download(String driveFileId, String saveToPath) async {
    try {
      await _ds.downloadPdf(driveFileId, saveToPath);
      return Result.ok(saveToPath);
    } catch (e) {
      return Result.err(NetworkFailure('Download failed', cause: e));
    }
  }

  @override
  Future<Result<void>> updateContent(String driveFileId, String localPath) async {
    try {
      await _ds.updatePdfContent(driveFileId, localPath);
      return const Result.ok(null);
    } catch (e) {
      return Result.err(NetworkFailure('Update failed', cause: e));
    }
  }

  @override
  Future<Result<void>> deleteFile(String driveFileId) async {
    try {
      await _ds.deleteFile(driveFileId);
      return const Result.ok(null);
    } catch (e) {
      return Result.err(NetworkFailure('Delete failed', cause: e));
    }
  }

  @override
  Future<Result<List<DriveFile>>> listFolder({String? folderName}) async {
    try {
      final files = await _ds.listInFolder(folderName);
      return Result.ok(files
          .map((f) => DriveFile(
                id: f.id ?? '',
                name: f.name ?? '',
                modifiedTime: f.modifiedTime ?? DateTime.now(),
                sizeBytes: int.tryParse(f.size ?? '0') ?? 0,
              ),)
          .toList(),);
    } catch (e) {
      return Result.err(NetworkFailure('List failed', cause: e));
    }
  }
}
