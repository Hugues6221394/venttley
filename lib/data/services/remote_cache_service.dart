import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../core/logger.dart';
import 'cache_service.dart';

/// Two-tier cache: an in-process [CacheService] in front of Upstash
/// Redis (REST). When Upstash creds aren't configured the remote tier
/// is silently skipped — the in-memory layer keeps working.
///
/// Use this for cross-process state (feed ranking, trending counters,
/// rate-limit buckets, online presence). For per-screen UI cache, the
/// pure-Dart [CacheService] is still the right choice.
class RemoteCacheService {
  RemoteCacheService._();
  static final RemoteCacheService instance = RemoteCacheService._();

  final CacheService _local = CacheService(maxEntries: 256);

  bool get _enabled => VentlyConfig.isUpstashEnabled;
  String get _baseUrl => VentlyConfig.upstashRedisRestUrl;
  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${VentlyConfig.upstashRedisRestToken}',
      };

  /// Get-or-load with a remote tier. The remote miss path also writes
  /// through to the local tier so subsequent reads hit the fast path.
  Future<T> getOrLoad<T>(
    String key,
    Future<T> Function() loader, {
    required Duration ttl,
    T Function(String raw)? decode,
    String Function(T value)? encode,
  }) async {
    // L1
    final localHit = await _local.getOrLoad<T?>(
      'mem:$key',
      () async => null, // never populate from this call — we want a fresh L2 read
      ttl: ttl,
    );
    if (localHit != null) return localHit;

    // L2
    if (_enabled && decode != null) {
      try {
        final raw = await _getRemote(key);
        if (raw != null) {
          final value = decode(raw);
          _local.set('mem:$key', value, ttl: ttl);
          return value;
        }
      } catch (e) {
        log.warn('cache.remote_get_failed', props: {'key': key}, error: e);
      }
    }

    // Loader
    final value = await loader();
    _local.set('mem:$key', value, ttl: ttl);
    if (_enabled && encode != null) {
      unawaited(_setRemote(key, encode(value), ttl: ttl));
    }
    return value;
  }

  /// Increment a counter. Returns the new value. Local-only when
  /// Upstash isn't configured.
  Future<int> increment(String key, {int by = 1, Duration? ttl}) async {
    if (!_enabled) {
      final next = ((_local.peek<int>('cnt:$key') ?? 0) + by);
      _local.set('cnt:$key', next, ttl: ttl ?? const Duration(hours: 1));
      return next;
    }
    try {
      final url = '$_baseUrl/incrby/$key/$by';
      final res = await http.post(Uri.parse(url), headers: _headers);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, Object?>;
        final n = (body['result'] as num?)?.toInt() ?? 0;
        if (ttl != null) {
          unawaited(http.post(
              Uri.parse('$_baseUrl/expire/$key/${ttl.inSeconds}'),
              headers: _headers));
        }
        return n;
      }
    } catch (e) {
      log.warn('cache.incr_failed', props: {'key': key}, error: e);
    }
    return 0;
  }

  Future<void> invalidate(String key) async {
    _local.invalidateKey('mem:$key');
    if (_enabled) {
      try {
        await http.post(Uri.parse('$_baseUrl/del/$key'), headers: _headers);
      } catch (_) {/* best-effort */}
    }
  }

  Future<String?> _getRemote(String key) async {
    final res =
        await http.get(Uri.parse('$_baseUrl/get/$key'), headers: _headers);
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return body['result'] as String?;
  }

  Future<void> _setRemote(String key, String value,
      {required Duration ttl}) async {
    try {
      await http.post(
        Uri.parse('$_baseUrl/set/$key/$value/ex/${ttl.inSeconds}'),
        headers: _headers,
      );
    } catch (e) {
      log.warn('cache.remote_set_failed', props: {'key': key}, error: e);
    }
  }
}
