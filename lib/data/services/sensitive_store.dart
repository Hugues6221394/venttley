import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal encrypted key-value boundary for user-authored local data.
///
/// Keeping this interface small makes drafts and the retry outbox testable
/// without invoking platform keychain APIs.
abstract interface class SensitiveStore {
  Future<String?> read(String key);
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSensitiveStore implements SensitiveStore {
  DeviceSensitiveStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
