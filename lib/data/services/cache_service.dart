import 'dart:async';
import 'dart:collection';

/// Tiny in-memory TTL + LRU cache.
///
/// This is the client-side stand-in for Redis: same patterns
/// (get-or-load, TTL, size cap), no infra. The Next.js admin app
/// will swap a real Upstash Redis client in front of these calls
/// when we land the server-side layer.
class CacheService {
  CacheService({this.maxEntries = 128});
  final int maxEntries;

  final LinkedHashMap<String, _Entry> _store =
      LinkedHashMap<String, _Entry>();
  final Map<String, Future<dynamic>> _inflight = {};

  /// Get-or-load: returns the cached value when fresh, otherwise calls
  /// [loader] (deduped per-key) and stores the result for [ttl].
  Future<T> getOrLoad<T>(
    String key,
    Future<T> Function() loader, {
    required Duration ttl,
  }) async {
    final hit = _store[key];
    if (hit != null && !hit.isExpired) {
      _store.remove(key);
      _store[key] = hit; // LRU bump
      return hit.value as T;
    }

    final pending = _inflight[key];
    if (pending != null) return await pending as T;

    final future = loader();
    _inflight[key] = future;
    try {
      final value = await future;
      _put(key, value, ttl);
      return value;
    } finally {
      _inflight.remove(key);
    }
  }

  /// Invalidate one key (or all keys matching [prefix]).
  void invalidate({String? key, String? prefix}) {
    if (key != null) _store.remove(key);
    if (prefix != null) {
      _store.removeWhere((k, _) => k.startsWith(prefix));
    }
  }

  void clear() => _store.clear();

  void _put<T>(String key, T value, Duration ttl) {
    _store.remove(key);
    _store[key] = _Entry(value, DateTime.now().add(ttl));
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }
}

class _Entry {
  _Entry(this.value, this.expiresAt);
  final dynamic value;
  final DateTime expiresAt;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
