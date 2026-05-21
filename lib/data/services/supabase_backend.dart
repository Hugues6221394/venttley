import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/entities.dart';
import 'identity_service.dart';

/// Live Supabase backend.
///
/// Mirrors the surface area of [MockBackend] so [VentlyRepository] can
/// transparently swap between the two. Everything goes through
/// PostgREST / Realtime / Supabase Auth.
class SupabaseBackend {
  SupabaseBackend._(this._client) {
    _client.auth.onAuthStateChange.listen((event) {
      _refreshLikedAndSaved();
    });
  }

  factory SupabaseBackend.of(SupabaseClient client) =>
      SupabaseBackend._(client);

  final SupabaseClient _client;
  final _rng = Random.secure();

  // Local mirrors of the calling user's "personalised" state.
  final Set<String> _likedPosts = {};
  final Set<String> _savedPosts = {};
  final Set<String> _joinedTribes = {};

  AppUser? _me;
  AppUser? get me => _me;
  String? get _uid => _client.auth.currentUser?.id;

  // ----- realtime fan-out used by the repository to stream the UI -----
  final _postsController = StreamController<List<Post>>.broadcast();
  final _roomsController = StreamController<List<ChatRoom>>.broadcast();
  Stream<List<Post>> get postsStream => _postsController.stream;
  Stream<List<ChatRoom>> get roomsStream => _roomsController.stream;

  RealtimeChannel? _postsChannel;
  RealtimeChannel? _roomsChannel;

  // ===================================================================
  // SESSION  (username + password via a synthetic, zero-PII handle, plus
  //           phrase-based recovery — see migration 0004)
  // ===================================================================

  /// Create a new account. The trigger `handle_new_auth_user` materialises
  /// the matching `public.users` row from the signup metadata; we then attach
  /// the encrypted recovery blob to that row.
  Future<AppUser> signUp({
    required String username,
    required String password,
    required String avatarSeed,
    required int birthYear,
    required String safetyTier,
    required String recoveryBlob,
    required String recoverySalt,
  }) async {
    final email = IdentityService.syntheticEmail(username);
    final AuthResponse res;
    try {
      res = await _client.auth.signUp(
        email: email,
        password: password,
        data: {
          'pseudonym':   username,
          'avatar_seed': avatarSeed,
          'birth_year':  birthYear,
          'safety_tier': safetyTier,
        },
      );
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('already') || msg.contains('registered')) {
        throw UsernameTakenException();
      }
      rethrow;
    }
    final user = res.user;
    if (user == null) {
      throw StateError('Sign-up returned no user');
    }
    if (res.session == null) {
      // Supabase project still requires email confirmation. Synthetic
      // username handles cannot receive mail, so this would strand the
      // account before it ever becomes usable.
      throw const EmailConfirmationStillOnException();
    }
    await _client.from('users').update({
      'recovery_blob': recoveryBlob,
      'recovery_salt': recoverySalt,
    }).eq('user_id', user.id);

    _me = AppUser(
      userId: user.id,
      anonymousPseudonym: username,
      avatarSeed: avatarSeed,
      currentMood: 'healing',
      userRole: 'normal',
      isVerified: false,
      safetyTier: safetyTier,
      accountStatus: 'active',
      birthYear: birthYear,
    );
    await _hydrateRealtime();
    return _me!;
  }

  /// Sign in an existing account with username + password.
  Future<AppUser> signIn({
    required String username,
    required String password,
  }) async {
    final email = IdentityService.syntheticEmail(username);
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('invalid') || msg.contains('credentials')) {
        throw InvalidCredentialsException();
      }
      rethrow;
    }
    final user = await restore();
    if (user == null) {
      throw StateError('Signed in but no matching profile row');
    }
    return user;
  }

  /// Pre-auth: fetch the encrypted recovery material for [username].
  /// Returns null if no such user, or if no recovery material was stored.
  Future<({String blob, String salt})?> fetchRecoveryMaterial(
      String username) async {
    final rows = await _client.rpc(
      'fetch_recovery_material',
      params: {'p_username': username},
    ) as List<dynamic>;
    if (rows.isEmpty) return null;
    final r = rows.first as Map<String, dynamic>;
    final blob = r['recovery_blob'] as String?;
    final salt = r['recovery_salt'] as String?;
    if (blob == null || salt == null) return null;
    return (blob: blob, salt: salt);
  }

  Future<AppUser?> restore() async {
    final uid = _uid;
    if (uid == null) return null;
    // Explicit column list: migration 0003 revokes column SELECT on the
    // sensitive columns (recovery_key_hash, device_signature_hash,
    // public_key), so a bare `select()` (which expands to `*`) now fails.
    final row = await _client
        .from('users')
        .select(
          'user_id, anonymous_pseudonym, avatar_seed, current_mood, '
          'user_role, is_verified, account_status, safety_tier, birth_year',
        )
        .eq('user_id', uid)
        .maybeSingle();
    if (row == null) return null;
    _me = _userFromRow(row);
    await _hydrateRealtime();
    return _me;
  }

  Future<void> logout() async {
    await _postsChannel?.unsubscribe();
    await _roomsChannel?.unsubscribe();
    _postsChannel = null;
    _roomsChannel = null;
    await _client.auth.signOut();
    _me = null;
    _likedPosts.clear();
    _savedPosts.clear();
    _joinedTribes.clear();
  }

  Future<void> _hydrateRealtime() async {
    await _refreshLikedAndSaved();
    _subscribePostsRealtime();
    _subscribeRoomsRealtime();
    _emitPosts();
    _emitRooms();
  }

  Future<void> _refreshLikedAndSaved() async {
    final uid = _uid;
    if (uid == null) return;
    final likes = await _client
        .from('post_likes')
        .select('post_id')
        .eq('user_id', uid);
    _likedPosts
      ..clear()
      ..addAll(likes.map((r) => r['post_id'] as String));
    final saves = await _client
        .from('post_saves')
        .select('post_id')
        .eq('user_id', uid);
    _savedPosts
      ..clear()
      ..addAll(saves.map((r) => r['post_id'] as String));
    final memberships = await _client
        .from('tribe_members')
        .select('tribe_id')
        .eq('user_id', uid);
    _joinedTribes
      ..clear()
      ..addAll(memberships.map((r) => r['tribe_id'] as String));
  }

  void _subscribePostsRealtime() {
    _postsChannel?.unsubscribe();
    _postsChannel = _client
        .channel('public:posts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'posts',
          callback: (_) => _emitPosts(),
        )
        .subscribe();
  }

  void _subscribeRoomsRealtime() {
    _roomsChannel?.unsubscribe();
    _roomsChannel = _client
        .channel('public:chat_rooms')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_rooms',
          callback: (_) => _emitRooms(),
        )
        .subscribe();
  }

  // ===================================================================
  // FEED
  // ===================================================================
  Future<List<Post>> feed({
    String? category,
    String? mood,
    String? tribeSlug,
    int limit = 100,
  }) async {
    var query = _client.from('feed_posts').select();
    if (category != null)  query = query.eq('category_name', category);
    if (mood != null)      query = query.eq('post_mood', mood);
    if (tribeSlug != null) query = query.eq('tribe_slug', tribeSlug);
    final rows = await query
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map<Post>(_postFromRow).toList();
  }

  Future<Post?> postById(String postId) async {
    final row = await _client
        .from('feed_posts')
        .select()
        .eq('post_id', postId)
        .maybeSingle();
    return row == null ? null : _postFromRow(row);
  }

  Future<Post> createPost({
    required String content,
    required String category,
    required String mood,
    String? tribeId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final inserted = await _client.from('posts').insert({
      'author_id':     uid,
      'tribe_id':      tribeId,
      'category_name': category,
      'post_type':     'user_post',
      'content':       content,
      'post_mood':     mood,
    }).select('post_id').single();
    final post = await postById(inserted['post_id'] as String);
    _emitPosts();
    return post!;
  }

  Future<void> toggleLike(String postId) async {
    final uid = _uid;
    if (uid == null) return;
    if (_likedPosts.contains(postId)) {
      await _client
          .from('post_likes')
          .delete()
          .eq('post_id', postId)
          .eq('user_id', uid);
      _likedPosts.remove(postId);
    } else {
      await _client.from('post_likes').insert({
        'post_id': postId,
        'user_id': uid,
      });
      _likedPosts.add(postId);
    }
    _emitPosts();
  }

  Future<void> toggleSave(String postId) async {
    final uid = _uid;
    if (uid == null) return;
    if (_savedPosts.contains(postId)) {
      await _client
          .from('post_saves')
          .delete()
          .eq('post_id', postId)
          .eq('user_id', uid);
      _savedPosts.remove(postId);
    } else {
      await _client.from('post_saves').insert({
        'post_id': postId,
        'user_id': uid,
      });
      _savedPosts.add(postId);
    }
    _emitPosts();
  }

  Future<void> reportPost({
    required String postId,
    required String reason,
    String? note,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    try {
      await _client.from('reports').insert({
        'post_id':     postId,
        'reporter_id': uid,
        'reason':      reason,
        'note':        note,
      });
    } on PostgrestException catch (e) {
      // 23505 = unique_violation — user already reported this target. Silent
      // success so the UI doesn't surface a scary error for a no-op.
      if (e.code != '23505') rethrow;
    }
  }

  Future<void> reportChat({
    required String roomId,
    required String reason,
    String? note,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    try {
      await _client.from('reports').insert({
        'target_room_id': roomId,
        'reporter_id':    uid,
        'reason':         reason,
        'note':           note,
      });
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
    }
  }

  // -------------------- Keeper tools (migration 0008) --------------------

  /// Create a Question-of-the-Day prompt pinned to a Tribe. Caller must be
  /// the Tribe's Keeper — RLS enforces this server-side.
  Future<PlugPrompt> createPromptForTribe({
    required String tribeId,
    required String text,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final row = await _client
        .from('plug_prompts')
        .insert({
          'tribe_id':    tribeId,
          'prompt_text': text,
          'is_active':   true,
        })
        .select('prompt_id, prompt_text, answers_count')
        .single();
    final me = _me;
    return PlugPrompt(
      promptId: row['prompt_id'] as String,
      plugDisplayName: '@${me?.anonymousPseudonym ?? 'keeper'}',
      plugAvatarSeed: me?.avatarSeed ?? 'default-orb',
      promptText: row['prompt_text'] as String,
      answersCount: (row['answers_count'] as int?) ?? 0,
    );
  }

  /// Reports filed against posts in a given Tribe. Visible only to the
  /// Tribe's Keeper (and super_admins) via the migration-0008 RLS policy.
  Future<List<TribeReport>> tribeReports(String tribeId) async {
    final rows = await _client
        .from('reports')
        .select(
          'report_id, reason, note, is_resolved, created_at, post_id, '
          'posts!inner(post_id, content, tribe_id, deleted_at, author_id)',
        )
        .eq('posts.tribe_id', tribeId)
        .order('created_at', ascending: false);
    return rows
        .map<TribeReport>((r) {
          final p = r['posts'] as Map<String, dynamic>?;
          return TribeReport(
            reportId: r['report_id'] as String,
            reason: r['reason'] as String,
            note: r['note'] as String?,
            isResolved: (r['is_resolved'] as bool?) ?? false,
            createdAt: DateTime.parse(r['created_at'] as String),
            postId: r['post_id'] as String,
            postPreview:
                ((p?['content'] as String?) ?? '').substring(0, _previewLen(p)),
            postDeleted: p?['deleted_at'] != null,
          );
        })
        .toList();
  }

  static int _previewLen(Map<String, dynamic>? p) {
    final s = (p?['content'] as String?) ?? '';
    return s.length > 160 ? 160 : s.length;
  }

  Future<void> resolveReport(String reportId) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    await _client
        .from('reports')
        .update({
          'is_resolved': true,
          'resolved_by': uid,
          'resolved_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('report_id', reportId);
  }

  /// Keeper-only — RLS enforces keeper_id = auth.uid().
  Future<Tribe> updateTribe({
    required String tribeId,
    String? name,
    String? description,
    bool? isPrivate,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null)         payload['name']        = name;
    if (description != null)  payload['description'] = description;
    if (isPrivate != null)    payload['is_private']  = isPrivate;
    if (payload.isEmpty) {
      final t = await _client
          .from('tribe_directory')
          .select()
          .eq('tribe_id', tribeId)
          .single();
      return _tribeFromRow(t);
    }
    await _client.from('tribes').update(payload).eq('tribe_id', tribeId);
    final row = await _client
        .from('tribe_directory')
        .select()
        .eq('tribe_id', tribeId)
        .single();
    return _tribeFromRow(row);
  }

  Future<List<Post>> mySaved() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('post_saves')
        .select('feed_posts(*)')
        .eq('user_id', uid);
    return rows
        .map<Post?>((r) {
          final fp = r['feed_posts'];
          return fp == null ? null : _postFromRow(fp);
        })
        .whereType<Post>()
        .toList();
  }

  Future<List<Post>> myVents() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('feed_posts')
        .select()
        .eq('author_id', uid)
        .order('created_at', ascending: false);
    return rows.map<Post>(_postFromRow).toList();
  }

  // ===================================================================
  // COMMENTS  (ltree-backed, fetched via fetch_comment_tree RPC)
  // ===================================================================
  Future<List<ThreadedComment>> comments(String postId) async {
    final rows = await _client.rpc(
      'fetch_comment_tree',
      params: {'p_post_id': postId},
    ) as List<dynamic>;

    // Hydrate author info in one round trip.
    final authorIds = rows
        .map((r) => r['author_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final authors = <String, Map<String, dynamic>>{};
    if (authorIds.isNotEmpty) {
      final list = await _client
          .from('users')
          .select('user_id, anonymous_pseudonym, avatar_seed')
          .inFilter('user_id', authorIds);
      for (final r in list) {
        authors[r['user_id'] as String] = r;
      }
    }

    // Build flat list, then assemble into a nested tree.
    final flat = rows.map((r) {
      final author = authors[r['author_id']];
      return ThreadedComment(
        commentId: r['comment_id'] as String,
        parentId: r['parent_id'] as String?,
        authorPseudonym: author == null
            ? '@anonymous'
            : '@${author['anonymous_pseudonym']}',
        authorAvatarSeed:
            author == null ? 'default-orb' : author['avatar_seed'] as String,
        content: r['content'] as String,
        path: r['path'] as String,
        depth: r['depth'] as int,
        likesCount: r['likes_count'] as int,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
    }).toList();
    final byId = {for (final c in flat) c.commentId: c};
    final roots = <ThreadedComment>[];
    for (final c in flat) {
      if (c.parentId == null) {
        roots.add(c);
      } else {
        byId[c.parentId!]?.children.add(c);
      }
    }
    return roots;
  }

  Future<ThreadedComment> addComment({
    required String postId,
    String? parentId,
    required String content,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final id = await _client.rpc('create_threaded_comment', params: {
      'p_post_id':   postId,
      'p_parent_id': parentId,
      'p_author_id': uid,
      'p_content':   content,
    }) as String;
    final me = _me;
    final tree = await comments(postId);
    final created = _findInTree(tree, id);
    _emitPosts();
    return created ??
        ThreadedComment(
          commentId: id,
          parentId: parentId,
          authorPseudonym: '@${me?.anonymousPseudonym ?? 'anonymous'}',
          authorAvatarSeed: me?.avatarSeed ?? 'default-orb',
          content: content,
          path: id.replaceAll('-', ''),
          depth: parentId == null ? 0 : 1,
          likesCount: 0,
          createdAt: DateTime.now(),
        );
  }

  ThreadedComment? _findInTree(List<ThreadedComment> nodes, String id) {
    for (final n in nodes) {
      if (n.commentId == id) return n;
      final f = _findInTree(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  // ===================================================================
  // PLUGZ  (verified keeper metadata; reads only — follow/unfollow is now
  //         expressed by joining/leaving the plug's Tribes)
  // ===================================================================
  Future<List<PlugProfile>> allPlugz() async {
    final rows = await _client.from('plug_profiles').select(
        'plug_id, display_name, bio, location_label, tribe_count, users(avatar_seed)');
    return rows.map<PlugProfile>(_plugFromRow).toList()
      ..sort((a, b) => b.tribeCount.compareTo(a.tribeCount));
  }

  Future<PlugProfile?> plugByName(String displayName) async {
    final row = await _client
        .from('plug_profiles')
        .select(
            'plug_id, display_name, bio, location_label, tribe_count, users(avatar_seed)')
        .eq('display_name', displayName)
        .maybeSingle();
    return row == null ? null : _plugFromRow(row);
  }

  // ===================================================================
  // TRIBES  (hybrid community + creator ecosystem — see migration 0005)
  // ===================================================================
  bool joinedTribe(String tribeId) => _joinedTribes.contains(tribeId);

  Future<List<Tribe>> tribes({String? category, String? search}) async {
    var q = _client.from('tribe_directory').select();
    if (category != null) q = q.eq('category', category);
    if (search != null && search.trim().isNotEmpty) {
      q = q.ilike('name', '%${search.trim()}%');
    }
    final rows = await q.order('member_count', ascending: false);
    return rows.map<Tribe>(_tribeFromRow).toList();
  }

  Future<Tribe?> tribeBySlug(String slug) async {
    final row = await _client
        .from('tribe_directory')
        .select()
        .eq('slug', slug)
        .maybeSingle();
    return row == null ? null : _tribeFromRow(row);
  }

  Future<Tribe> createTribe({
    required String name,
    required String category,
    String? description,
    bool isPrivate = false,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final slug = _slugify(name);
    final row = await _client
        .from('tribes')
        .insert({
          'name':        name,
          'slug':        slug,
          'category':    category,
          'description': description,
          'is_private':  isPrivate,
          'keeper_id':   uid,
        })
        .select('tribe_id')
        .single();
    final tribeId = row['tribe_id'] as String;
    // Keeper auto-joins their own tribe.
    await _client.from('tribe_members').insert({
      'tribe_id': tribeId,
      'user_id':  uid,
    });
    _joinedTribes.add(tribeId);
    final created = await tribeBySlug(slug);
    return created!;
  }

  Future<void> joinTribe(String tribeId) async {
    final uid = _uid;
    if (uid == null) return;
    if (_joinedTribes.contains(tribeId)) return;
    await _client.from('tribe_members').insert({
      'tribe_id': tribeId,
      'user_id':  uid,
    });
    _joinedTribes.add(tribeId);
  }

  Future<void> leaveTribe(String tribeId) async {
    final uid = _uid;
    if (uid == null) return;
    await _client
        .from('tribe_members')
        .delete()
        .eq('tribe_id', tribeId)
        .eq('user_id', uid);
    _joinedTribes.remove(tribeId);
  }

  String _slugify(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  // ===================================================================
  // CHAT  (plaintext stored server-side; column names are historical —
  //        v1 does NOT advertise end-to-end encryption)
  // ===================================================================
  Future<List<ChatRoom>> inbox({required String tab}) async {
    final rows = await _client
        .from('inbox_rooms')
        .select()
        .order('created_at', ascending: false);
    return rows
        .where((r) {
          if (tab == 'requests') return r['room_status'] == 'pending_request';
          if (tab == 'active')   return r['room_status'] == 'active';
          return true;
        })
        .map<ChatRoom>((r) => ChatRoom(
              roomId: r['room_id'] as String,
              peerPseudonym: r['peer_pseudonym'] == null
                  ? '@anonymous'
                  : '@${r['peer_pseudonym']}',
              peerAvatarSeed:
                  (r['peer_avatar_seed'] as String?) ?? 'default-orb',
              requestPreview: (r['request_preview'] as String?) ?? '',
              roomStatus: r['room_status'] as String,
              createdAt: DateTime.parse(r['created_at'] as String),
              initiatedByMe: r['initiated_by_me'] as bool,
            ))
        .toList();
  }

  Future<ChatRoom> sendMessageRequest({
    required String peerUserId,
    required String preview,
    String? originPostId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final row = await _client
        .from('chat_rooms')
        .insert({
          'initiated_by':    uid,
          'received_by':     peerUserId,
          'origin_post_id':  originPostId,
          'request_preview': preview,
          'room_status':     'pending_request',
        })
        .select(
            'room_id, request_preview, room_status, created_at, peer:received_by(anonymous_pseudonym, avatar_seed)')
        .single();
    final peer = row['peer'] as Map<String, dynamic>?;
    return ChatRoom(
      roomId: row['room_id'] as String,
      peerPseudonym: peer == null ? '@anonymous' : '@${peer['anonymous_pseudonym']}',
      peerAvatarSeed: (peer?['avatar_seed'] as String?) ?? 'default-orb',
      requestPreview: (row['request_preview'] as String?) ?? '',
      roomStatus: row['room_status'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      initiatedByMe: true,
    );
  }

  Future<ChatRoom> acceptRequest(String roomId) async {
    final row = await _client
        .from('chat_rooms')
        .update({'room_status': 'active'})
        .eq('room_id', roomId)
        .select()
        .single();
    return ChatRoom(
      roomId: row['room_id'] as String,
      peerPseudonym: '@anonymous',
      peerAvatarSeed: 'default-orb',
      requestPreview: (row['request_preview'] as String?) ?? '',
      roomStatus: row['room_status'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      initiatedByMe: row['initiated_by'] == _uid,
    );
  }

  Future<void> declineRequest(String roomId) async {
    await _client
        .from('chat_rooms')
        .update({'room_status': 'declined'})
        .eq('room_id', roomId);
  }

  Future<List<ChatMessage>> messages(String roomId) async {
    final uid = _uid;
    final rows = await _client
        .from('chat_messages')
        .select()
        .eq('room_id', roomId)
        .order('created_at', ascending: true);
    return rows
        .map<ChatMessage>((r) => ChatMessage(
              messageId: r['message_id'] as String,
              roomId: r['room_id'] as String,
              senderId: (r['sender_id'] as String?) ?? 'unknown',
              plaintext: r['encrypted_payload'] as String,
              createdAt: DateTime.parse(r['created_at'] as String),
              sentByMe: r['sender_id'] == uid,
            ))
        .toList();
  }

  /// Realtime stream of messages for a single room. Re-fetches on every
  /// Postgres change so the listener sees both inserts and edits.
  Stream<List<ChatMessage>> watchMessages(String roomId) {
    final controller = StreamController<List<ChatMessage>>();
    Future<void> emit() async {
      try {
        controller.add(await messages(roomId));
      } catch (_) {/* listener retries on next event */}
    }

    final channel = _client
        .channel('public:chat_messages:room=$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (_) => emit(),
        )
        .subscribe();

    controller.onListen = emit;
    controller.onCancel = () => channel.unsubscribe();
    return controller.stream;
  }

  Future<ChatMessage> sendMessage({
    required String roomId,
    required String payload,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final row = await _client
        .from('chat_messages')
        .insert({
          'room_id':           roomId,
          'sender_id':         uid,
          // Column name is historical from the E2EE plan we cut for v1.
          'encrypted_payload': payload,
          'nonce_iv':          'v1-plaintext',
        })
        .select()
        .single();
    return ChatMessage(
      messageId: row['message_id'] as String,
      roomId: roomId,
      senderId: uid,
      plaintext: payload,
      createdAt: DateTime.parse(row['created_at'] as String),
      sentByMe: true,
    );
  }

  // ===================================================================
  // PROMPTS
  // ===================================================================
  Future<List<PlugPrompt>> prompts() async {
    final rows = await _client.from('plug_prompts').select(
        'prompt_id, prompt_text, answers_count, plug_profiles(display_name, users(avatar_seed))').eq('is_active', true);
    return rows.map<PlugPrompt>((r) {
      final pp = r['plug_profiles'] as Map<String, dynamic>?;
      final users = pp?['users'] as Map<String, dynamic>?;
      return PlugPrompt(
        promptId: r['prompt_id'] as String,
        plugDisplayName: (pp?['display_name'] as String?) ?? '@plug',
        plugAvatarSeed: (users?['avatar_seed'] as String?) ?? 'default-orb',
        promptText: r['prompt_text'] as String,
        answersCount: r['answers_count'] as int,
      );
    }).toList();
  }

  // ===================================================================
  // NOTIFICATIONS
  // ===================================================================
  Future<List<NotificationItem>> notifications() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('notifications')
        .select()
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(50);
    return rows.map<NotificationItem>((r) {
      final payload = r['payload'] as Map<String, dynamic>;
      return NotificationItem(
        id: r['notification_id'] as String,
        kind: r['kind'] as String,
        title: (payload['title'] as String?) ?? r['kind'] as String,
        body: (payload['body'] as String?) ?? '',
        createdAt: DateTime.parse(r['created_at'] as String),
        isRead: r['is_read'] as bool,
      );
    }).toList();
  }

  // ===================================================================
  // Helpers
  // ===================================================================
  void _emitPosts() async {
    try {
      final list = await feed();
      _postsController.add(list);
    } catch (_) {
      // ignore — stream listeners will retry on the next emit
    }
  }

  void _emitRooms() async {
    try {
      final list = await inbox(tab: 'all');
      _roomsController.add(list);
    } catch (_) {}
  }

  Post _postFromRow(Map<String, dynamic> r) {
    return Post(
      postId: r['post_id'] as String,
      authorPseudonym: (r['author_pseudonym'] as String?) ?? '@anonymous',
      authorAvatarSeed: (r['author_avatar_seed'] as String?) ?? 'default-orb',
      authorIsVerified: (r['author_is_verified'] as bool?) ?? false,
      categoryName: r['category_name'] as String,
      postType: r['post_type'] as String,
      content: r['content'] as String,
      postMood: r['post_mood'] as String,
      likesCount: r['likes_count'] as int,
      commentsCount: r['comments_count'] as int,
      createdAt: DateTime.parse(r['created_at'] as String),
      tribeId: r['tribe_id'] as String?,
      tribeName: r['tribe_name'] as String?,
      tribeSlug: r['tribe_slug'] as String?,
      likedByMe: _likedPosts.contains(r['post_id']),
      savedByMe: _savedPosts.contains(r['post_id']),
    );
  }

  Tribe _tribeFromRow(Map<String, dynamic> r) {
    return Tribe(
      tribeId: r['tribe_id'] as String,
      name: r['name'] as String,
      slug: r['slug'] as String,
      description: r['description'] as String?,
      category: r['category'] as String,
      memberCount: (r['member_count'] as int?) ?? 0,
      isPrivate: (r['is_private'] as bool?) ?? false,
      keeperId: r['keeper_id'] as String?,
      keeperPseudonym: r['keeper_pseudonym'] as String?,
      keeperAvatarSeed: r['keeper_avatar_seed'] as String?,
      keeperIsVerified: (r['keeper_is_verified'] as bool?) ?? false,
      createdAt: DateTime.parse(r['created_at'] as String),
      joinedByMe: _joinedTribes.contains(r['tribe_id']),
    );
  }

  PlugProfile _plugFromRow(Map<String, dynamic> r) {
    final users = r['users'] as Map<String, dynamic>?;
    return PlugProfile(
      plugId: r['plug_id'] as String,
      displayName: r['display_name'] as String,
      bio: r['bio'] as String?,
      locationLabel: r['location_label'] as String?,
      tribeCount: r['tribe_count'] as int,
      avatarSeed: (users?['avatar_seed'] as String?) ?? 'default-orb',
    );
  }

  AppUser _userFromRow(Map<String, dynamic> r) {
    return AppUser(
      userId: r['user_id'] as String,
      anonymousPseudonym: r['anonymous_pseudonym'] as String,
      avatarSeed: r['avatar_seed'] as String,
      currentMood: r['current_mood'] as String,
      userRole: r['user_role'] as String,
      isVerified: r['is_verified'] as bool,
      safetyTier: r['safety_tier'] as String,
      accountStatus: r['account_status'] as String,
      birthYear: r['birth_year'] as int?,
    );
  }

  /// Friendly, UI-facing auth failure types — see [signUp] / [signIn].
  // (defined below the class)

  /// Pick a random other user — used for the demo "find a peer" flow until
  /// a richer peer-discovery UX ships.
  Future<Map<String, dynamic>?> randomPeer() async {
    final uid = _uid;
    final rows = await _client
        .from('users')
        .select('user_id, anonymous_pseudonym, avatar_seed')
        .neq('user_id', uid ?? '00000000-0000-0000-0000-000000000000')
        .limit(20);
    if (rows.isEmpty) return null;
    return rows[_rng.nextInt(rows.length)];
  }
}

class UsernameTakenException implements Exception {
  @override
  String toString() => 'That name is already in someone\'s sanctuary — try another.';
}

class InvalidCredentialsException implements Exception {
  @override
  String toString() => 'Username or password doesn\'t match.';
}

class EmailConfirmationStillOnException implements Exception {
  const EmailConfirmationStillOnException();
  @override
  String toString() =>
      'Supabase Auth still requires email confirmation. Disable '
      '"Confirm email" in Authentication → Providers → Email so the '
      'zero-PII username handles can sign up.';
}

