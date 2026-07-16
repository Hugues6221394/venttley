import 'package:vently_app/data/services/sensitive_store.dart';

class MemorySensitiveStore implements SensitiveStore {
  MemorySensitiveStore([Map<String, String>? seed])
      : values = Map<String, String>.from(seed ?? const {});

  final Map<String, String> values;

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll() async => Map.from(values);

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
