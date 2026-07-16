import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sensitive_store.dart';

/// Crash-safe, encrypted persistence for anything the user types.
///
/// Every draft is one JSON entry under a namespaced key
/// (`vently.draft.v2.<user>.<surface>[.<id>]`) with a `savedAt` stamp so stale
/// drafts can be swept. Writes are debounced by [DraftSaver] so typing
/// costs one encrypted write every ~800ms, not one per keystroke.
class DraftStore {
  DraftStore._(this._storage, this._values, this._now, this._userId);

  static const _legacyPrefix = 'vently.draft.';
  static const _prefix = 'vently.draft.v2.';
  static const maxAge = Duration(days: 7);

  final SensitiveStore _storage;
  final Map<String, String> _values;
  final DateTime Function() _now;
  final String _userId;
  Future<void> _writeTail = Future<void>.value();

  static Future<DraftStore> open({required String userId}) async {
    final storage = DeviceSensitiveStore();
    final values = await storage.readAll();
    final prefs = await SharedPreferences.getInstance();

    // One-time migration from the former plaintext SharedPreferences store.
    for (final key in prefs.getKeys().where(
          (key) => key.startsWith(_legacyPrefix) && !key.startsWith(_prefix),
        )) {
      final value = prefs.getString(key);
      if (value == null) continue;
      final scopedKey =
          '$_prefix$userId.${key.substring(_legacyPrefix.length)}';
      if (!values.containsKey(scopedKey)) {
        await storage.write(scopedKey, value);
        values[scopedKey] = value;
      }
      await prefs.remove(key);
    }

    // Secure-storage records from the first encrypted release were not
    // account-scoped. Attribute them to the signed-in account during upgrade.
    for (final entry in List<MapEntry<String, String>>.of(values.entries)) {
      if (!entry.key.startsWith(_legacyPrefix) ||
          entry.key.startsWith(_prefix)) {
        continue;
      }
      final scopedKey =
          '$_prefix$userId.${entry.key.substring(_legacyPrefix.length)}';
      if (!values.containsKey(scopedKey)) {
        await storage.write(scopedKey, entry.value);
        values[scopedKey] = entry.value;
      }
      await storage.delete(entry.key);
      values.remove(entry.key);
    }

    final store = DraftStore._(storage, values, DateTime.now, userId);
    await store._sweep();
    return store;
  }

  /// Test/alternate-platform entry point that avoids platform preferences.
  static Future<DraftStore> openWithStore(
    SensitiveStore storage, {
    DateTime Function()? now,
    String userId = 'test-user',
  }) async {
    final store = DraftStore._(
      storage,
      await storage.readAll(),
      now ?? DateTime.now,
      userId,
    );
    await store._sweep();
    return store;
  }

  Future<void> save(String key, Map<String, dynamic> payload) {
    final stored = <String, dynamic>{
      ...payload,
      'savedAt': _now().toIso8601String(),
    };
    final storageKey = _storageKey(key);
    final encoded = jsonEncode(stored);
    return _serially(() async {
      await _storage.write(storageKey, encoded);
      _values[storageKey] = encoded;
    });
  }

  Map<String, dynamic>? load(String key) {
    final storageKey = _storageKey(key);
    final raw = _values[storageKey];
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        unawaited(clear(key));
        return null;
      }
      final savedAt = DateTime.tryParse(decoded['savedAt'] as String? ?? '');
      if (savedAt == null || _now().difference(savedAt) > maxAge) {
        unawaited(clear(key));
        return null;
      }
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      unawaited(clear(key));
      return null;
    }
  }

  String? loadText(String key) => load(key)?['text'] as String?;

  Future<void> saveText(String key, String text) {
    if (text.trim().isEmpty) return clear(key);
    return save(key, {'text': text});
  }

  Future<void> clear(String key) {
    final storageKey = _storageKey(key);
    return _serially(() async {
      await _storage.delete(storageKey);
      _values.remove(storageKey);
    });
  }

  Future<void> _sweep() async {
    final stale = <String>[];
    for (final entry in _values.entries.where(
      (entry) => entry.key.startsWith('$_prefix$_userId.'),
    )) {
      try {
        final decoded = jsonDecode(entry.value);
        final savedAt = decoded is Map<String, dynamic>
            ? DateTime.tryParse(decoded['savedAt'] as String? ?? '')
            : null;
        if (savedAt == null || _now().difference(savedAt) > maxAge) {
          stale.add(entry.key);
        }
      } catch (_) {
        stale.add(entry.key);
      }
    }
    for (final key in stale) {
      await _storage.delete(key);
      _values.remove(key);
    }
  }

  String _storageKey(String key) => '$_prefix$_userId.$key';

  Future<void> _serially(Future<void> Function() operation) {
    final next = _writeTail
        .catchError((Object _, StackTrace __) {})
        .then((_) => operation());
    _writeTail = next;
    return next;
  }
}

/// Debounced bridge between a [TextEditingController] and [DraftStore].
class DraftSaver {
  DraftSaver({
    required this.store,
    required this.draftKey,
    required this.controller,
    this.debounce = const Duration(milliseconds: 800),
  }) {
    controller.addListener(_onChanged);
  }

  final DraftStore store;
  final String draftKey;
  final TextEditingController controller;
  final Duration debounce;
  Timer? _timer;

  bool restore() {
    if (controller.text.trim().isNotEmpty) return false;
    final text = store.loadText(draftKey);
    if (text == null || text.trim().isEmpty) return false;
    controller.text = text;
    return true;
  }

  void _onChanged() {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      unawaited(store.saveText(draftKey, controller.text));
    });
  }

  Future<void> clear() async {
    _timer?.cancel();
    await store.clear(draftKey);
  }

  void dispose() {
    _timer?.cancel();
    unawaited(store.saveText(draftKey, controller.text));
    controller.removeListener(_onChanged);
  }
}
