import '../../../../core/utils/result.dart';

class DriveUser {
  const DriveUser({required this.email, required this.displayName, this.photoUrl});
  final String email;
  final String displayName;
  final String? photoUrl;
}

class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    required this.modifiedTime,
    required this.sizeBytes,
  });
  final String id;
  final String name;
  final DateTime modifiedTime;
  final int sizeBytes;
}

abstract class DriveRepository {
  Future<Result<DriveUser>> signIn();
  Future<Result<void>> signOut();
  Future<DriveUser?> currentUser();

  /// Uploads a local PDF; returns the new Drive file id.
  Future<Result<String>> upload(String localPath, {String? folderName});

  /// Downloads a Drive file to a local path.
  Future<Result<String>> download(String driveFileId, String saveToPath);

  /// Updates an existing Drive file's content.
  Future<Result<void>> updateContent(String driveFileId, String localPath);

  Future<Result<void>> deleteFile(String driveFileId);

  Future<Result<List<DriveFile>>> listFolder({String? folderName});
}
