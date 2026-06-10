import 'dart:io';

import '../../../core/error/failures.dart';
import '../../../core/utils/result.dart';
import '../domain/cloud_storage.dart';

/// iCloud Drive integration — STUB.
///
/// The real implementation needs the `icloud_storage` plugin (or a custom
/// Swift method channel into NSFileManager.url(forUbiquityContainerIdentifier:))
/// because there's no first-party Flutter package as of mid-2026.
///
/// Until that lands, calls return [PlatformNotSupportedFailure] so call
/// sites can fall back to Drive without try/catch noise.
///
/// Migration plan when ready:
///   1. Add `icloud_storage: ^X.Y.Z` (verify maintained) or write the
///      method channel in `ios/Runner/CloudKitChannel.swift`.
///   2. Replace each `_unsupported()` with the real call.
///   3. Wire iCloud option into Settings → Cloud sync provider.
class ICloudStorage implements CloudStorage {
  const ICloudStorage();

  @override
  CloudProvider get provider => CloudProvider.iCloud;

  @override
  Future<bool> isReady() async {
    if (!Platform.isIOS && !Platform.isMacOS) return false;
    // TODO(icloud): probe ubiquity container availability.
    return false;
  }

  @override
  Future<Result<void>> signIn() async => _unsupported();

  @override
  Future<Result<void>> signOut() async => _unsupported();

  @override
  Future<Result<List<CloudFile>>> list({String? folderId}) async =>
      _unsupported();

  @override
  Future<Result<CloudFile>> upload(File file,
          {String? folderId, String? remoteName,}) async =>
      _unsupported();

  @override
  Future<Result<File>> download(String remoteId,
          {required File destination,}) async =>
      _unsupported();

  @override
  Future<Result<void>> delete(String remoteId) async => _unsupported();

  /// Single source of the "not yet" error — keep messages consistent.
  Result<T> _unsupported<T>() => Result<T>.err(
        const PlatformNotSupportedFailure(
          'iCloud sync is coming in a later release. '
          'Use Google Drive for now.',
        ),
      );
}
