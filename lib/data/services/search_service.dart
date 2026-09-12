import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../domain/entities/entities.dart';
import 'supabase_backend.dart';

/// Cross-app search.
///
/// Two backends:
///   * [_PostgresSearchBackend]   — wraps the `search_global` RPC the
///                                  app already uses. Default + dev fallback.
///   * [_MeilisearchBackend]      — used when `MEILISEARCH_HOST` is
///                                  set. Returns the same [SearchHit]
///                                  shape so callers never branch.
///
/// Cutover plan: an Edge Function mirrors writes from posts / tribes /
/// users / whispers into Meilisearch indexes. Until that runs, the
/// Postgres backend stays authoritative.
abstract class SearchService {
  static SearchService? _instance;
  static SearchService instance({SupabaseBackend? supabase}) {
    final existing = _instance;
    if (existing != null) return existing;
    final next = VentlyConfig.isMeilisearchEnabled
        ? _MeilisearchBackend(
            host: VentlyConfig.meilisearchHost,
            apiKey: VentlyConfig.meilisearchKey,
            fallback: supabase == null
                ? null
                : _PostgresSearchBackend(supabase),
          )
        : (supabase == null
              ? _NoopSearchBackend()
              : _PostgresSearchBackend(supabase));
    _instance = next;
    return next;
  }

  /// Cross-index search (tribes + posts + topics + whispers).
  Future<List<SearchHit>> search(String query, {int limit = 24});
}

class _NoopSearchBackend implements SearchService {
  @override
  Future<List<SearchHit>> search(String query, {int limit = 24}) async =>
      const [];
}

class _PostgresSearchBackend implements SearchService {
  _PostgresSearchBackend(this._supabase);
  final SupabaseBackend _supabase;

  @override
  Future<List<SearchHit>> search(String query, {int limit = 24}) {
    return _supabase.searchGlobal(query, limit: limit);
  }
}

class _MeilisearchBackend implements SearchService {
  _MeilisearchBackend({
    required this.host,
    required this.apiKey,
    this.fallback,
  });
  final String host;
  final String apiKey;
  final SearchService? fallback;

  /// Tunable list of indexes scanned in parallel. Add to this when a
  /// new index ships (whispers_v1, plug_profiles, etc.).
  static const _indexes = <String, String>{
    'posts_v1': 'post',
    'tribes_v1': 'tribe',
    'whispers_v1': 'whisper',
    'users_v1': 'user',
  };

  @override
  Future<List<SearchHit>> search(String query, {int limit = 24}) async {
    if (query.trim().length < 2) return const [];
    try {
      final futures = _indexes.entries.map((entry) async {
        final res = await http.post(
          Uri.parse('$host/indexes/${entry.key}/search'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({'q': query, 'limit': limit}),
        );
        if (res.statusCode != 200) return <SearchHit>[];
        final body = jsonDecode(res.body) as Map<String, Object?>;
        final hits = (body['hits'] as List?) ?? const [];
        return hits
            .map((h) => _meiliToHit(entry.value, h as Map<String, Object?>))
            .whereType<SearchHit>()
            .toList();
      });
      final groups = await Future.wait(futures);
      final flat = [for (final g in groups) ...g];
      flat.sort((a, b) => b.rankScore.compareTo(a.rankScore));
      return flat.take(limit).toList();
    } catch (e) {
      log.warn('search.meilisearch_failed', error: e);
      if (fallback != null) return fallback!.search(query, limit: limit);
      return const [];
    }
  }

  SearchHit? _meiliToHit(String kind, Map<String, Object?> h) {
    try {
      return SearchHit(
        hitKind: kind,
        hitId: (h['id'] ?? h['hit_id'] ?? '').toString(),
        title: (h['title'] ?? h['name'] ?? '').toString(),
        subtitle: (h['subtitle'] ?? h['description'] ?? '').toString(),
        avatarSeed: h['avatar_seed'] as String?,
        profilePhotoUrl: h['profile_photo_url'] as String?,
        memberCount: (h['member_count'] as num?)?.toInt(),
        postCount: (h['post_count'] as num?)?.toInt(),
        likesCount: (h['likes_count'] as num?)?.toInt(),
        commentsCount: (h['comments_count'] as num?)?.toInt(),
        createdAt: h['created_at'] == null
            ? null
            : DateTime.tryParse(h['created_at'].toString()),
        rankScore: (h['rank_score'] as num?)?.toDouble() ?? 1.0,
      );
    } catch (_) {
      return null;
    }
  }
}
