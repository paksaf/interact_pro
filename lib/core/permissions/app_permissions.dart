import 'package:permission_handler/permission_handler.dart';

import '../utils/result.dart';
import '../error/failures.dart';

/// Centralised permission requests. Each call returns a `Result<void>` so
/// the UI doesn't need to interpret platform-specific statuses.
///
/// The `Result.err(PermissionFailure)` branch carries an `isPermanent`
/// hint via the message text so the caller can offer "Open Settings" when
/// the user has dismissed the prompt with "Don't ask again" / iOS denial.
class AppPermissions {
  AppPermissions._();

  /// PRD: CAMERA — scanning, signature/stamp imports.
  static Future<Result<void>> requestCamera() =>
      _request(Permission.camera, 'Camera');

  /// On Android 13+, photo access is split — `photos` covers READ_MEDIA_IMAGES.
  /// On <13, falls back to legacy storage perms.
  static Future<Result<void>> requestPhotos() =>
      _request(Permission.photos, 'Photos');

  /// Required for foreground sync notifications on Android 13+.
  static Future<Result<void>> requestNotifications() =>
      _request(Permission.notification, 'Notifications');

  /// Microphone — for STT (Pro feature) + any future audio annotations.
  static Future<Result<void>> requestMicrophone() =>
      _request(Permission.microphone, 'Microphone');

  /// iOS-only: NSSpeechRecognitionUsageDescription gate. On Android this
  /// returns OK immediately because the device's speech recognizer doesn't
  /// require a separate runtime permission — RECORD_AUDIO is sufficient.
  static Future<Result<void>> requestSpeechRecognition() =>
      _request(Permission.speech, 'Speech recognition');

  /// Convenience: open the system settings page so the user can flip a
  /// permanently-denied permission. Returns true if the OS accepted the
  /// open request (doesn't tell us whether the user actually toggled it).
  static Future<bool> openSettings() => openAppSettings();

  static Future<Result<void>> _request(Permission p, String label) async {
    final PermissionStatus status = await p.request();
    if (status.isGranted || status.isLimited) {
      return const Result<void>.ok(null);
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return Result<void>.err(
        PermissionFailure('$label permission permanently denied. '
            'Open system settings to enable it.'),
      );
    }
    return Result<void>.err(PermissionFailure('$label permission denied.'));
  }
}
