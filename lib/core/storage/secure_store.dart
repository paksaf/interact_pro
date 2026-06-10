import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// PRD: "All Drive credentials stored in Android Keystore."
/// On iOS this is backed by Keychain. Don't put refresh tokens in
/// SharedPreferences.
class SecureStore {
  SecureStore(this._storage);
  final FlutterSecureStorage _storage;

  static const String kDriveRefreshToken = 'drive_refresh_token';
  static const String kDriveAccountEmail = 'drive_account_email';
  static const String kSigningCertPath = 'signing_cert_path';

  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  Future<void> delete(String key) => _storage.delete(key: key);
  Future<void> deleteAll() => _storage.deleteAll();
}

final Provider<SecureStore> secureStoreProvider =
    Provider<SecureStore>((Ref ref) {
  return SecureStore(
    const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    ),
  );
});
