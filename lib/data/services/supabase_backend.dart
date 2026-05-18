import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/entities.dart';

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
  final Set<String> _followedPlugz = {};

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
  // SESSION  (anonymous auth + matching public.users row)
  // ===================================================================
  Future<AppUser> bootstrap({
    required String pseudonym,
    required String avatarSeed,
    required int birthYear,
    required String safetyTier,
  }) async {
    final res = await _client.auth.signInAnonymously(data: {
      'pseudonym':   pseudonym,
      'avatar_seed': avatarSeed,
      'birth_year':  birthYear,
      'safety_tier': safetyTier,
    });
    final uid = res.user?.id;
    if (uid == null) {
      throw StateError('Anonymous sign-in failed: no user id');
    }
    // The auth trigger `handle_new_auth_user` will create the matching
    // public.users row; we still upsert defensively so the app keeps working
    // if the trigger ever drifts.
    await _client.from('users').upsert({
      'user_id':             uid,
      'anonymous_pseudonym': pseudonym,
      'avatar_seed':         avatarSeed,
      'current_mood':        'healing',
      'safety_tier':         safetyTier,
      'birth_year':          birthYear,
      'recovery_key_hash':   'auth-managed',
    }, onConflict: 'user_id');

    _me = AppUser(
      userId: uid,
      anonymousPseudonym: pseudonym,
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

  Future<AppUser?> restore() async {
    final uid = _uid;
    if (uid == null) return null;
    final row = await _client
        .from('users')
        .select()
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
    _followedPlugz.clear();
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
    final follows = await _client
        .from('tribes_follows')
        .select('plug_id')
        .eq('follower_id', uid);
    _followedPlugz
      ..clear()
      ..addAll(follows.map((r) => r['plug_id'] as String));
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
    String? spaceName,
    int limit = 100,
  }) async {
    var query = _client.from('feed_posts').select();
    if (category != null)  query = query.eq('category_name', category);
    if (mood != null)      query = query.eq('post_mood', mood);
    if (spaceName != null) query = query.eq('space_name', spaceName);
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
    String? spaceName,
    bool isAudio = false,
    String? audioUrl,
    int audioDurationMs = 0,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    String? spaceId;
    if (spaceName != null) {
      final s = await _client
          .from('spaces')
          .select('space_id')
          .eq('space_name', spaceName)
          .maybeSingle();
      spaceId = s?['space_id'] as String?;
    }
    final inserted = await _client.from('posts').insert({
      'author_id':         uid,
      'space_id':          spaceId,
      'category_name':     category,
      'post_type':         'user_post',
      'content':           content,
      'post_mood':         mood,
      'is_audio':          isAudio,
      'audio_url':         audioUrl,
      'audio_duration_ms': audioDurationMs,
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
  // PLUGZ / TRIBES
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

  bool isFollowing(String plugId) => _followedPlugz.contains(plugId);

  Future<void> toggleFollow(String plugId) async {
    final uid = _uid;
    if (uid == null) return;
    if (_followedPlugz.contains(plugId)) {
      await _client
          .from('tribes_follows')
          .delete()
          .eq('follower_id', uid)
          .eq('plug_id', plugId);
      _followedPlugz.remove(plugId);
    } else {
      await _client.from('tribes_follows').insert({
        'follower_id': uid,
        'plug_id':     plugId,
      });
      _followedPlugz.add(plugId);
    }
  }

  // ===================================================================
  // SPACES
  // ===================================================================
  Future<List<Space>> spaces() async {
    final rows = await _client.from('spaces').select().order('member_count',
        ascending: false);
    return rows
        .map<Space>((r) => Space(
              spaceId: r['space_id'] as String,
              spaceName: r['space_name'] as String,
              spaceType: r['space_type'] as String,
              memberCount: r['member_count'] as int,
              description: r['description'] as String?,
            ))
        .toList();
  }

  Future<Space> createSpace({
    required String name,
    required String type,
    String? description,
  }) async {
    final row = await _client
        .from('spaces')
        .insert({
          'space_name':  name,
          'space_type':  type,
          'description': description,
        })
        .select()
        .single();
    final uid = _uid;
    if (uid != null) {
      await _client.from('space_memberships').insert({
        'space_id': row['space_id'],
        'user_id':  uid,
      });
    }
    return Space(
      spaceId: row['space_id'] as String,
      spaceName: row['space_name'] as String,
      spaceType: row['space_type'] as String,
      memberCount: (row['member_count'] as int?) ?? 1,
      description: row['description'] as String?,
    );
  }

  // ===================================================================
  // CHAT  (E2EE payloads stored encrypted; this layer is the transport)
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

  Future<ChatMessage> sendMessage({
    required String roomId,
    required String encryptedPayload,
    required String nonceIv,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final row = await _client
        .from('chat_messages')
        .insert({
          'room_id':           roomId,
          'sender_id':         uid,
          'encrypted_payload': encryptedPayload,
          'nonce_iv':          nonceIv,
        })
        .select()
        .single();
    return ChatMessage(
      messageId: row['message_id'] as String,
      roomId: roomId,
      senderId: uid,
      plaintext: encryptedPayload,
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
      categoryName: r['category_name'] as String,
      postType: r['post_type'] as String,
      content: r['content'] as String,
      postMood: r['post_mood'] as String,
      isAudio: r['is_audio'] as bool,
      audioUrl: r['audio_url'] as String?,
      audioDurationMs: (r['audio_duration_ms'] as int?) ?? 0,
      likesCount: r['likes_count'] as int,
      commentsCount: r['comments_count'] as int,
      createdAt: DateTime.parse(r['created_at'] as String),
      spaceName: r['space_name'] as String?,
      likedByMe: _likedPosts.contains(r['post_id']),
      savedByMe: _savedPosts.contains(r['post_id']),
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

