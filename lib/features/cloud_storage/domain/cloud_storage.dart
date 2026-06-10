import 'dart:io';

import '../../../core/utils/result.dart';

/// Where a cloud file lives. The concrete provider is hidden so call sites
/// can be backend-agnostic.
class CloudFile {
  const CloudFile({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    this.thumbnailUrl,
  });

  final String id;
  final String name;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String? thumbnailUrl;
}

/// Backends the user can sync to. Add iCloud once `cloud_kit` is wired in.
enum CloudProvider { googleDrive, iCloud }

/// Single interface for any cloud sync provider. The Drive impl is real;
/// the iCloud impl is currently a stub that throws — see
/// `iCloudStorage` in data/icloud_storage.dart.
abstract class CloudStorage {
  CloudProvider get provider;

  /// True if the user is signed in / iCloud is available on this device.
  Future<bool> isReady();

  /// Initiate sign-in (Drive) or check container availability (iCloud).
  Future<Result<void>> signIn();

  Future<Result<void>> signOut();

  Future<Result<List<CloudFile>>> list({String? folderId});

  Future<Result<CloudFile>> upload(
    File file, {
    String? folderId,
    String? remoteName,
  });

  Future<Result<File>> download(String remoteId, {required File destination});

  Future<Result<void>> delete(String remoteId);
}
