import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
  final Map<String, String> _myReactions = {};
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
      profilePhotoUrl: null,
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
          'user_role, is_verified, account_status, safety_tier, birth_year, '
          'karma_points, home_city, home_country, home_campus, profile_photo_url',
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
    _myReactions.clear();
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
        .select('post_id, reaction_type')
        .eq('user_id', uid);
    _myReactions
      ..clear()
      ..addEntries(likes.map((r) => MapEntry(
            r['post_id'] as String,
            r['reaction_type'] as String,
          )));
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
    String? locationBucket,
    String sort = 'fresh', // fresh | hot | foryou
    int limit = 100,
  }) async {
    // "For You" is a server-side blended ranking (migration 0015).
    // The personal_score already factors in local + tribe affinity, so
    // we pass through category + mood and ignore the scope filters
    // (those would just over-constrain the candidate pool).
    if (sort == 'foryou' && tribeSlug == null) {
      final rows = await _client.rpc(
        'personal_feed',
        params: {
          'p_limit': limit,
          'p_category': category,
          'p_mood': mood,
        },
      ) as List<dynamic>;
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      return rows
          .cast<Map<String, dynamic>>()
          .map<Post>(_postFromRow)
          .where((p) => !p.isWhisper || p.createdAt.isAfter(cutoff))
          .toList();
    }

    final source = sort == 'hot' ? 'feed_hot' : 'feed_posts';
    var query = _client.from(source).select();
    if (category != null)  query = query.eq('category_name', category);
    if (mood != null)      query = query.eq('post_mood', mood);
    if (tribeSlug != null) query = query.eq('tribe_slug', tribeSlug);
    if (locationBucket != null) {
      query = query.eq('location_bucket', locationBucket);
    }
    final rows = await (sort == 'hot'
            ? query.order('hot_score', ascending: false)
            : query.order('created_at', ascending: false))
        .limit(limit);
    // Whispers vanish from the feed after 24h. We filter client-side
    // because PostgREST's `or` filter doesn't cleanly express
    // "is_whisper = false OR created_at > now() - 24h" against a view.
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    return rows
        .map<Post>(_postFromRow)
        .where((p) => !p.isWhisper || p.createdAt.isAfter(cutoff))
        .toList();
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
    String? personaId,
    bool isWhisper = false,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final inserted = await _client.from('posts').insert({
      'author_id':     uid,
      'tribe_id':      tribeId,
      'persona_id':    personaId,
      'category_name': category,
      'post_type':     'user_post',
      'content':       content,
      'post_mood':     mood,
      'is_whisper':    isWhisper,
    }).select('post_id').single();
    final post = await postById(inserted['post_id'] as String);
    _emitPosts();
    return post!;
  }

  // ===================================================================
  // PERSONAS
  // ===================================================================
  Future<List<Persona>> myPersonas() async {
    final rows = await _client
        .from('personas')
        .select('persona_id, pseudonym, avatar_seed, bio, created_at')
        .filter('deleted_at', 'is', null)
        .order('created_at');
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(_personaFromRow)
        .toList();
  }

  Future<Persona> createPersona({
    required String pseudonym,
    required String avatarSeed,
    String? bio,
  }) async {
    final row = await _client.rpc('create_persona', params: {
      'p_pseudonym':   pseudonym,
      'p_avatar_seed': avatarSeed,
      'p_bio':         bio,
    });
    return _personaFromRow(row as Map<String, dynamic>);
  }

  Future<Persona> updatePersona({
    required String personaId,
    required String pseudonym,
    required String avatarSeed,
    String? bio,
  }) async {
    final row = await _client.rpc('update_persona', params: {
      'p_persona_id':  personaId,
      'p_pseudonym':   pseudonym,
      'p_avatar_seed': avatarSeed,
      'p_bio':         bio,
    });
    return _personaFromRow(row as Map<String, dynamic>);
  }

  Future<bool> deletePersona(String personaId) async {
    final res = await _client.rpc(
      'delete_persona',
      params: {'p_persona_id': personaId},
    );
    return (res as bool?) ?? false;
  }

  Persona _personaFromRow(Map<String, dynamic> r) => Persona(
        personaId: r['persona_id'] as String,
        pseudonym: r['pseudonym'] as String,
        avatarSeed: r['avatar_seed'] as String,
        bio: r['bio'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
      );

  /// Tag a post the author just created with a crisis level so the helpline
  /// banner shows for everyone who reads it later. Author-only on the DB.
  Future<void> setPostCrisis(String postId, String level) async {
    await _client.rpc('set_post_crisis', params: {
      'p_post_id': postId,
      'p_level': level,
    });
  }

  /// Fetch active helplines. Pass `region` (ISO code) to bias the order —
  /// matching region rows come first, then `'global'` falls in behind them.
  Future<List<CrisisHelpline>> crisisResources({String? region}) async {
    final rows = await _client
        .from('crisis_resources')
        .select()
        .eq('is_active', true)
        .order('sort_order');
    final list = (rows as List)
        .cast<Map<String, dynamic>>()
        .map(_crisisFromRow)
        .toList();
    if (region == null || region.isEmpty) return list;
    list.sort((a, b) {
      int rank(CrisisHelpline c) {
        if (c.region == region) return 0;
        if (c.region == 'global') return 1;
        return 2;
      }
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.sortOrder.compareTo(b.sortOrder);
    });
    return list;
  }

  // ──────────────────── Friends graph ────────────────────

  Future<FriendStatus> friendStatus(String otherUserId) async {
    final result = await _client.rpc(
      'friend_status',
      params: {'p_target': otherUserId},
    );
    return FriendStatus.parse(result as String?);
  }

  Future<String> sendFriendRequest(String otherUserId, {String? note}) async {
    final res = await _client.rpc(
      'send_friend_request',
      params: {'p_target': otherUserId, 'p_note': note},
    );
    return res as String;
  }

  Future<void> acceptFriendRequest(String friendshipId) async {
    await _client.rpc(
      'accept_friend_request',
      params: {'p_friendship': friendshipId},
    );
  }

  Future<void> declineFriendRequest(String friendshipId) async {
    await _client.rpc(
      'decline_friend_request',
      params: {'p_friendship': friendshipId},
    );
  }

  Future<void> unfriend(String otherUserId) async {
    await _client.rpc('unfriend', params: {'p_target': otherUserId});
  }

  Future<void> blockUser(String otherUserId, {String? reason}) async {
    await _client.rpc(
      'block_user',
      params: {'p_target': otherUserId, 'p_reason': reason},
    );
  }

  Future<void> unblockUser(String otherUserId) async {
    await _client.rpc('unblock_user', params: {'p_target': otherUserId});
  }

  Future<List<FriendSummary>> myFriends() async {
    final rows = await _client
        .from('my_friends')
        .select()
        .order('accepted_at', ascending: false);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map((r) => FriendSummary(
              friendshipId: r['friendship_id'] as String,
              userId: r['friend_user_id'] as String,
              pseudonym: r['friend_pseudonym'] as String,
              avatarSeed:
                  (r['friend_avatar_seed'] as String?) ?? 'default-orb',
              karma: (r['friend_karma'] as int?) ?? 0,
              isVerified: (r['friend_is_verified'] as bool?) ?? false,
              acceptedAt: DateTime.parse(r['accepted_at'] as String),
            ))
        .toList();
  }

  Future<List<FriendRequest>> incomingFriendRequests() async {
    final rows = await _client
        .from('friend_requests_inbox')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map((r) => FriendRequest(
              friendshipId: r['friendship_id'] as String,
              otherUserId: r['from_user_id'] as String,
              otherPseudonym: r['from_pseudonym'] as String,
              otherAvatarSeed:
                  (r['from_avatar_seed'] as String?) ?? 'default-orb',
              otherKarma: (r['from_karma'] as int?) ?? 0,
              note: r['note'] as String?,
              createdAt: DateTime.parse(r['created_at'] as String),
              isOutgoing: false,
            ))
        .toList();
  }

  Future<List<FriendRequest>> outgoingFriendRequests() async {
    final rows = await _client
        .from('friend_requests_outbox')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map((r) => FriendRequest(
              friendshipId: r['friendship_id'] as String,
              otherUserId: r['to_user_id'] as String,
              otherPseudonym: r['to_pseudonym'] as String,
              otherAvatarSeed:
                  (r['to_avatar_seed'] as String?) ?? 'default-orb',
              otherKarma: (r['to_karma'] as int?) ?? 0,
              note: r['note'] as String?,
              createdAt: DateTime.parse(r['created_at'] as String),
              isOutgoing: true,
            ))
        .toList();
  }

  Future<UserProfileView?> userProfile(String otherUserId) async {
    final result = await _client.rpc(
      'user_profile_summary',
      params: {'p_target': otherUserId},
    );
    if (result == null) return null;
    return _profileFromJson(result as Map<String, dynamic>);
  }

  UserProfileView _profileFromJson(Map<String, dynamic> j) {
    final user = j['user'] as Map<String, dynamic>;
    final stats = (j['stats'] as Map<String, dynamic>?) ?? const {};
    final mutuals = (j['mutuals'] as Map<String, dynamic>?) ?? const {};
    final highlights = (j['highlights'] as Map<String, dynamic>?) ?? const {};

    List<MoodCount> moods = [];
    final rawMoods = stats['top_moods'];
    if (rawMoods is List) {
      moods = rawMoods
          .cast<Map<String, dynamic>>()
          .map((m) => MoodCount(
                mood: m['mood'] as String,
                count: (m['count'] as num).toInt(),
              ))
          .toList();
    }

    List<MutualFriend> mutualFriendSample = [];
    final rawFriends = mutuals['mutual_friend_sample'];
    if (rawFriends is List) {
      mutualFriendSample = rawFriends
          .cast<Map<String, dynamic>>()
          .map((m) => MutualFriend(
                userId: m['user_id'] as String,
                pseudonym: m['pseudonym'] as String,
                avatarSeed:
                    (m['avatar_seed'] as String?) ?? 'default-orb',
              ))
          .toList();
    }
    List<MutualTribe> mutualTribes = [];
    final rawTribes = mutuals['mutual_tribes'];
    if (rawTribes is List) {
      mutualTribes = rawTribes
          .cast<Map<String, dynamic>>()
          .map((m) => MutualTribe(
                tribeId: m['tribe_id'] as String,
                name: m['name'] as String,
                slug: m['slug'] as String,
              ))
          .toList();
    }

    ProfileHighlightPost? toPost(Map<String, dynamic>? p) {
      if (p == null) return null;
      return ProfileHighlightPost(
        postId: p['post_id'] as String,
        content: p['content'] as String? ?? '',
        likes: (p['likes'] as num?)?.toInt() ?? 0,
        comments: (p['comments'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(p['created_at'] as String),
        category: (p['category'] as String?) ?? 'confessions',
        mood: p['mood'] as String?,
        crisisLevel: p['crisis_level'] as String?,
      );
    }

    List<ProfileHighlightPost> recent = [];
    final rawRecent = highlights['recent_posts'];
    if (rawRecent is List) {
      recent = rawRecent
          .cast<Map<String, dynamic>>()
          .map((p) => toPost(p)!)
          .toList();
    }

    List<UserBadge> badges = [];
    final rawBadges = highlights['badges'];
    if (rawBadges is List) {
      badges = rawBadges
          .cast<Map<String, dynamic>>()
          .map((b) => UserBadge(
                key: b['badge_key'] as String,
                awardedAt: DateTime.parse(b['awarded_at'] as String),
              ))
          .toList();
    }

    List<ActivityHeatmapDay> heatmap = const [];
    final rawHeatmap = highlights['heatmap'];
    if (rawHeatmap is List) {
      heatmap = rawHeatmap
          .cast<Map<String, dynamic>>()
          .map((d) => ActivityHeatmapDay(
                day: DateTime.parse(d['day'] as String),
                count: (d['count'] as num?)?.toInt() ?? 0,
              ))
          .toList();
    }

    return UserProfileView(
      relation: FriendStatus.parse(j['viewer_relation'] as String?),
      userId: user['user_id'] as String,
      pseudonym: user['pseudonym'] as String,
      avatarSeed: (user['avatar_seed'] as String?) ?? 'default-orb',
      karma: (user['karma'] as num?)?.toInt() ?? 0,
      isVerified: (user['is_verified'] as bool?) ?? false,
      joinedAt: DateTime.parse(user['joined_at'] as String),
      currentMood: user['current_mood'] as String?,
      accountStatus: (user['account_status'] as String?) ?? 'active',
      safetyTier: (user['safety_tier'] as String?) ?? 'standard',
      vents: (stats['vents'] as num?)?.toInt() ?? 0,
      comments: (stats['comments'] as num?)?.toInt(),
      reactionsReceived: (stats['reactions_received'] as num?)?.toInt(),
      activeTribes: (stats['active_tribes'] as num?)?.toInt() ?? 0,
      badgesCount: (stats['badges_count'] as num?)?.toInt(),
      currentStreak: (stats['current_streak'] as num?)?.toInt(),
      bestStreak: (stats['best_streak'] as num?)?.toInt(),
      topMoods: moods,
      mutualFriendsCount:
          (mutuals['mutual_friends_count'] as num?)?.toInt() ?? 0,
      mutualFriendSample: mutualFriendSample,
      mutualTribes: mutualTribes,
      mostLiked: toPost(highlights['most_liked'] as Map<String, dynamic>?),
      mostCommented:
          toPost(highlights['most_commented'] as Map<String, dynamic>?),
      recentPosts: recent,
      badges: badges,
      heatmap: heatmap,
    );
  }

  Future<List<BlockedUser>> myBlocks() async {
    final rows = await _client
        .from('my_blocks')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map((r) => BlockedUser(
              userId: r['user_id'] as String,
              pseudonym: r['pseudonym'] as String,
              avatarSeed: (r['avatar_seed'] as String?) ?? 'default-orb',
              reason: r['reason'] as String?,
              createdAt: DateTime.parse(r['created_at'] as String),
            ))
        .toList();
  }

  Future<void> toggleLike(String postId) async => react(postId, 'like');

  /// Returns the resulting reaction (`null` when the user toggled it off).
  Future<String?> react(String postId, String reaction) async {
    final uid = _uid;
    if (uid == null) return null;
    final result = await _client.rpc('set_reaction', params: {
      'p_post_id': postId,
      'p_reaction': reaction,
    });
    if (result == null) {
      _myReactions.remove(postId);
    } else {
      _myReactions[postId] = result as String;
    }
    _emitPosts();
    return result as String?;
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

  // -------------------- Profile location (migration 0012) ---------------

  Future<AppUser> updateMyLocation({
    String? homeCity,
    String? homeCountry,
    String? homeCampus,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    await _client.from('users').update({
      'home_city':    homeCity?.trim().isEmpty == true ? null : homeCity?.trim(),
      'home_country': homeCountry?.trim().isEmpty == true ? null : homeCountry?.trim(),
      'home_campus':  homeCampus?.trim().isEmpty == true ? null : homeCampus?.trim(),
    }).eq('user_id', uid);
    final refreshed = await restore();
    return refreshed!;
  }

  /// Persist a new avatar_seed for the current user (migration 0030).
  /// The RPC validates the seed format server-side; we still re-fetch
  /// the AppUser so the session in memory reflects the new look.
  Future<AppUser> updateMyAvatar(String seed) async {
    await _client.rpc('update_user_avatar', params: {'p_seed': seed});
    final refreshed = await restore();
    return refreshed!;
  }

  Future<AppUser> uploadMyProfilePhoto({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final safeExt = extension
        .replaceAll('.', '')
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]'), '');
    final path = '$uid/profile-${const Uuid().v4()}.${safeExt.isEmpty ? 'jpg' : safeExt}';
    await _client.storage.from('profile-photos').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(
            contentType: contentType,
            upsert: false,
          ),
        );
    final url = _client.storage.from('profile-photos').getPublicUrl(path);
    final oldPath = await _client.rpc(
      'set_user_profile_photo',
      params: {
        'p_path': path,
        'p_url': url,
      },
    ) as String?;
    if (oldPath != null && oldPath.isNotEmpty && oldPath != path) {
      unawaited(_client.storage.from('profile-photos').remove([oldPath]));
    }
    final refreshed = await restore();
    return refreshed!;
  }

  Future<AppUser> removeMyProfilePhoto() async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final oldPath = await _client.rpc('clear_user_profile_photo') as String?;
    if (oldPath != null && oldPath.isNotEmpty) {
      unawaited(_client.storage.from('profile-photos').remove([oldPath]));
    }
    final refreshed = await restore();
    return refreshed!;
  }

  // -------------------- Co-mod hierarchy (migration 0012) ---------------

  /// Member roster of a tribe with role + join date. Reads through RLS so
  /// non-members of private tribes don't see this.
  Future<List<TribeMemberRow>> tribeMembers(String tribeId) async {
    final rows = await _client
        .from('tribe_members')
        .select(
          'role, joined_at, '
          'users!inner(user_id, anonymous_pseudonym, avatar_seed)',
        )
        .eq('tribe_id', tribeId)
        .order('joined_at', ascending: true);
    return rows.map<TribeMemberRow>((r) {
      final u = r['users'] as Map<String, dynamic>;
      return TribeMemberRow(
        userId: u['user_id'] as String,
        pseudonym: u['anonymous_pseudonym'] as String,
        avatarSeed: (u['avatar_seed'] as String?) ?? 'default-orb',
        role: r['role'] as String,
        joinedAt: DateTime.parse(r['joined_at'] as String),
      );
    }).toList();
  }

  Future<void> promoteToMod(
      {required String tribeId, required String userId}) async {
    await _client.rpc('promote_to_mod',
        params: {'p_tribe_id': tribeId, 'p_user_id': userId});
  }

  Future<void> demoteToMember(
      {required String tribeId, required String userId}) async {
    await _client.rpc('demote_to_member',
        params: {'p_tribe_id': tribeId, 'p_user_id': userId});
  }

  Future<void> kickMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) async {
    await _client.rpc('kick_member', params: {
      'p_tribe_id': tribeId,
      'p_user_id': userId,
      'p_reason': reason,
    });
  }

  Future<void> transferKeeper({
    required String tribeId,
    required String toUserId,
  }) async {
    await _client.rpc('transfer_keeper',
        params: {'p_tribe_id': tribeId, 'p_to_user_id': toUserId});
  }

  // -------------------- Badges + streaks --------------------------------

  Future<List<BadgeDefinition>> badgeCatalogue() async {
    final rows = await _client
        .from('badge_definitions')
        .select('badge_key, label, description, icon, tier')
        .order('tier', ascending: true);
    return rows
        .map<BadgeDefinition>((r) => BadgeDefinition(
              key: r['badge_key'] as String,
              label: r['label'] as String,
              description: r['description'] as String,
              icon: r['icon'] as String,
              tier: r['tier'] as String,
            ))
        .toList();
  }

  Future<List<UserBadge>> badgesFor(String userId) async {
    final rows = await _client
        .from('user_badges')
        .select('badge_key, awarded_at')
        .eq('user_id', userId)
        .order('awarded_at', ascending: false);
    return rows
        .map<UserBadge>((r) => UserBadge(
              key: r['badge_key'] as String,
              awardedAt: DateTime.parse(r['awarded_at'] as String),
            ))
        .toList();
  }

  Future<List<UserStreak>> myStreaks() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('user_streaks')
        .select('streak_kind, current_count, longest_count, last_event_at')
        .eq('user_id', uid);
    return rows
        .map<UserStreak>((r) => UserStreak(
              kind: r['streak_kind'] as String,
              currentCount: (r['current_count'] as int?) ?? 0,
              longestCount: (r['longest_count'] as int?) ?? 0,
              lastEventAt: DateTime.parse(r['last_event_at'] as String),
            ))
        .toList();
  }

  // -------------------- Tribe invitations (migration 0011) --------------

  /// Issue an invite to a single user. Caller must be the tribe's keeper —
  /// RLS enforces it server-side. Trigger fans a notification row to the
  /// invited user.
  Future<void> inviteToTribe({
    required String tribeId,
    required String invitedUserId,
    String? message,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    try {
      await _client.from('tribe_invites').insert({
        'tribe_id':         tribeId,
        'invited_user_id':  invitedUserId,
        'invited_by':       uid,
        'message':          message,
      });
    } on PostgrestException catch (e) {
      // Already invited — silent no-op.
      if (e.code != '23505') rethrow;
    }
  }

  /// Pending invites *to me*. Used by the inbox/notifications panel.
  Future<List<TribeInvite>> myPendingInvites() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('tribe_invites')
        .select(
          'invite_id, tribe_id, invited_user_id, status, created_at, message, '
          'tribes!inner(name, slug, avatar_url), '
          'inviter:invited_by(anonymous_pseudonym)',
        )
        .eq('invited_user_id', uid)
        .eq('status', 'pending')
        .order('created_at', ascending: false);
    return rows
        .map<TribeInvite>((r) {
          final t = r['tribes'] as Map<String, dynamic>?;
          final inv = r['inviter'] as Map<String, dynamic>?;
          return TribeInvite(
            inviteId: r['invite_id'] as String,
            tribeId: r['tribe_id'] as String,
            tribeName: (t?['name'] as String?) ?? 'a Tribe',
            tribeSlug: t?['slug'] as String?,
            tribeAvatarUrl: t?['avatar_url'] as String?,
            invitedUserId: r['invited_user_id'] as String,
            invitedByPseudonym: inv?['anonymous_pseudonym'] as String?,
            message: r['message'] as String?,
            status: r['status'] as String,
            createdAt: DateTime.parse(r['created_at'] as String),
          );
        })
        .toList();
  }

  Future<void> respondToInvite({
    required String inviteId,
    required bool accept,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    // Flip the status. RLS lets only the invitee do this.
    final row = await _client
        .from('tribe_invites')
        .update({
          'status':      accept ? 'accepted' : 'declined',
          'decided_at':  DateTime.now().toUtc().toIso8601String(),
        })
        .eq('invite_id', inviteId)
        .select('tribe_id, invited_user_id')
        .single();
    if (accept) {
      // Auto-join the tribe — UNIQUE(tribe_id, user_id) on tribe_members
      // means re-accepting an invite the user already joined manually is
      // a no-op.
      try {
        await _client.from('tribe_members').insert({
          'tribe_id': row['tribe_id'],
          'user_id':  uid,
        });
        _joinedTribes.add(row['tribe_id'] as String);
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow;
      }
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
  // ──────────────────── Plugz Creator Studio (0028) ────────────────────

  Future<TribeStudioStats?> tribeStudioStats(String tribeId) async {
    final r = await _client
        .from('tribe_studio_stats')
        .select()
        .eq('tribe_id', tribeId)
        .maybeSingle();
    if (r == null) return null;
    return TribeStudioStats(
      tribeId: r['tribe_id'] as String,
      memberCount: (r['member_count'] as int?) ?? 0,
      members7d: (r['members_7d'] as int?) ?? 0,
      members30d: (r['members_30d'] as int?) ?? 0,
      posts24h: (r['posts_24h'] as int?) ?? 0,
      posts7d: (r['posts_7d'] as int?) ?? 0,
      comments7d: (r['comments_7d'] as int?) ?? 0,
      activePosters7d: (r['active_posters_7d'] as int?) ?? 0,
      pinnedCount: (r['pinned_count'] as int?) ?? 0,
      scheduledPrompts: (r['scheduled_prompts'] as int?) ?? 0,
      openReports: (r['open_reports'] as int?) ?? 0,
    );
  }

  Future<List<Post>> pinnedPosts(String tribeId) async {
    // Pull the pinned post ids, then resolve via feed_posts (already
    // joins author + persona + tribe). Two round-trips but small lists.
    final pins = await _client
        .from('tribe_pinned_posts')
        .select('post_id, sort_idx, pinned_at')
        .eq('tribe_id', tribeId)
        .order('sort_idx', ascending: true)
        .order('pinned_at', ascending: false);
    if ((pins as List).isEmpty) return const [];
    final ids = pins.map((r) => r['post_id'] as String).toList();
    final rows = await _client
        .from('feed_posts')
        .select()
        .inFilter('post_id', ids)
        .filter('deleted_at', 'is', null);
    final byId = <String, Post>{
      for (final r in rows as List)
        ((r as Map<String, dynamic>)['post_id'] as String):
            _postFromRow(r)
    };
    // Preserve pinned order
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> pinPost(String tribeId, String postId) async {
    await _client.rpc(
      'tribe_pin_post',
      params: {'p_tribe': tribeId, 'p_post': postId},
    );
  }

  Future<void> unpinPost(String tribeId, String postId) async {
    await _client.rpc(
      'tribe_unpin_post',
      params: {'p_tribe': tribeId, 'p_post': postId},
    );
  }

  Future<List<ScheduledPrompt>> tribePrompts(String tribeId) async {
    final rows = await _client
        .from('plug_prompts')
        .select(
          'prompt_id, tribe_id, prompt_text, scheduled_for, published_at, is_active, answers_count')
        .eq('tribe_id', tribeId)
        .order('scheduled_for', ascending: true, nullsFirst: false);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map((r) => ScheduledPrompt(
              promptId: r['prompt_id'] as String,
              tribeId: r['tribe_id'] as String,
              text: r['prompt_text'] as String,
              answersCount: (r['answers_count'] as int?) ?? 0,
              isActive: (r['is_active'] as bool?) ?? true,
              scheduledFor: r['scheduled_for'] == null
                  ? null
                  : DateTime.parse(r['scheduled_for'] as String),
              publishedAt: r['published_at'] == null
                  ? null
                  : DateTime.parse(r['published_at'] as String),
            ))
        .toList();
  }

  Future<String> schedulePrompt({
    required String tribeId,
    required String text,
    DateTime? scheduledFor,
  }) async {
    final res = await _client.rpc('tribe_schedule_prompt', params: {
      'p_tribe': tribeId,
      'p_prompt_text': text,
      'p_scheduled_for': scheduledFor?.toUtc().toIso8601String(),
    });
    return res as String;
  }

  Future<void> cancelPrompt(String tribeId, String promptId) async {
    await _client.rpc('tribe_cancel_prompt', params: {
      'p_tribe': tribeId,
      'p_prompt': promptId,
    });
  }

  Future<void> setTribeBranding({
    required String tribeId,
    String? welcomeMessage,
    String? themeColor,
  }) async {
    await _client.rpc('tribe_set_branding', params: {
      'p_tribe': tribeId,
      'p_welcome_message': welcomeMessage,
      'p_theme_color': themeColor,
    });
  }

  Future<void> spotlightMember({
    required String tribeId,
    required String? userId,
    String? note,
  }) async {
    await _client.rpc('tribe_spotlight_member', params: {
      'p_tribe': tribeId,
      'p_user': userId,
      'p_note': note,
    });
  }

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
    String? avatarUrl,
    String? bannerUrl,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null)         payload['name']        = name;
    if (description != null)  payload['description'] = description;
    if (isPrivate != null)    payload['is_private']  = isPrivate;
    if (avatarUrl != null)    payload['avatar_url']  = avatarUrl;
    if (bannerUrl != null)    payload['banner_url']  = bannerUrl;
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

  // ===================================================================
  // POLLS  (post_polls + poll_options + poll_votes — see migration 0001)
  // ===================================================================

  /// Attach a poll to a freshly-created post. The caller must own the post —
  /// the RLS policy "polls insert by post author" enforces this server-side.
  Future<PostPoll> createPoll({
    required String postId,
    required String question,
    required List<String> optionTexts,
    Duration closesIn = const Duration(days: 3),
  }) async {
    if (optionTexts.length < 2) {
      throw ArgumentError('Polls need at least two options.');
    }
    final pollRow = await _client
        .from('post_polls')
        .insert({
          'post_id':    postId,
          'question':   question,
          'closes_at':  DateTime.now().add(closesIn).toIso8601String(),
        })
        .select('poll_id, post_id, question, closes_at')
        .single();
    final pollId = pollRow['poll_id'] as String;
    final optionRows = await _client
        .from('poll_options')
        .insert(optionTexts
            .map((t) => {'poll_id': pollId, 'option_text': t})
            .toList())
        .select('option_id, option_text');
    return PostPoll(
      pollId: pollId,
      postId: postId,
      question: pollRow['question'] as String,
      closesAt: DateTime.parse(pollRow['closes_at'] as String),
      options: optionRows
          .map<PollOption>((r) => PollOption(
                optionId: r['option_id'] as String,
                text: r['option_text'] as String,
              ))
          .toList(),
      optionCounts: {for (final r in optionRows) r['option_id'] as String: 0},
    );
  }

  /// Hydrate a Post's poll (or null if it has none).
  Future<PostPoll?> pollForPost(String postId) async {
    final poll = await _client
        .from('post_polls')
        .select('poll_id, post_id, question, closes_at')
        .eq('post_id', postId)
        .maybeSingle();
    if (poll == null) return null;
    final pollId = poll['poll_id'] as String;
    final options = await _client
        .from('poll_options')
        .select('option_id, option_text')
        .eq('poll_id', pollId);
    final votes = await _client
        .from('poll_votes')
        .select('option_id, user_id')
        .eq('poll_id', pollId);
    final counts = <String, int>{
      for (final o in options) o['option_id'] as String: 0,
    };
    final uid = _uid;
    String? mine;
    for (final v in votes) {
      final oid = v['option_id'] as String;
      counts[oid] = (counts[oid] ?? 0) + 1;
      if (uid != null && v['user_id'] == uid) mine = oid;
    }
    return PostPoll(
      pollId: pollId,
      postId: postId,
      question: poll['question'] as String,
      closesAt: DateTime.parse(poll['closes_at'] as String),
      options: options
          .map<PollOption>((o) => PollOption(
                optionId: o['option_id'] as String,
                text: o['option_text'] as String,
              ))
          .toList(),
      optionCounts: counts,
      myVoteOptionId: mine,
    );
  }

  Future<void> votePoll({
    required String pollId,
    required String optionId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    // UNIQUE(poll_id, user_id) — duplicate votes silently no-op.
    try {
      await _client.from('poll_votes').insert({
        'poll_id':   pollId,
        'option_id': optionId,
        'user_id':   uid,
      });
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
    }
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
        likedByMe: (r['liked_by_me'] as bool?) ?? false,
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
    String? personaId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final id = await _client.rpc('create_threaded_comment', params: {
      'p_post_id':    postId,
      'p_parent_id':  parentId,
      'p_author_id':  uid,
      'p_content':    content,
      'p_persona_id': personaId,
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

  Future<bool> toggleCommentLike(String commentId) async {
    final res = await _client.rpc(
      'toggle_comment_like',
      params: {'p_comment_id': commentId},
    );
    return (res as bool?) ?? false;
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

  Future<bool> canDm(String peerUserId) async {
    final result = await _client.rpc(
      'can_dm',
      params: {'p_target': peerUserId},
    );
    return (result as bool?) ?? false;
  }

  /// Open-or-create the chat room with a friend. Routes through the
  /// `start_chat_room` SECURITY DEFINER RPC, which gates on friendship
  /// (migration 0026). Throws [DmGatingException] when the caller is
  /// not friends with the target.
  Future<ChatRoom> sendMessageRequest({
    required String peerUserId,
    required String preview,
    String? originPostId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final List rows;
    try {
      final res = await _client.rpc(
        'start_chat_room',
        params: {
          'p_target': peerUserId,
          'p_preview': preview,
          'p_origin_post_id': originPostId,
        },
      );
      rows = res as List;
    } on PostgrestException catch (e) {
      // The RPC raises a friendly message when the caller isn't a
      // friend. Anything else bubbles untouched.
      if (e.message.contains('DM blocked')) {
        throw const DmGatingException(
          'Send a friend request first — you can only message friends.',
        );
      }
      rethrow;
    }
    if (rows.isEmpty) {
      throw StateError('start_chat_room returned no row');
    }
    final row = rows.first as Map<String, dynamic>;

    // The RPC doesn't join the peer profile — fetch it separately so the
    // returned ChatRoom has a pseudonym/avatar for immediate render.
    final peer = await _client
        .from('users')
        .select('anonymous_pseudonym, avatar_seed')
        .eq('user_id', peerUserId)
        .maybeSingle();
    return ChatRoom(
      roomId: row['room_id'] as String,
      peerPseudonym:
          peer == null ? '@anonymous' : '@${peer['anonymous_pseudonym']}',
      peerAvatarSeed: (peer?['avatar_seed'] as String?) ?? 'default-orb',
      requestPreview: (row['request_preview'] as String?) ?? '',
      roomStatus: row['room_status'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      initiatedByMe: (row['initiated_by_me'] as bool?) ?? true,
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
    final rows = await _client
        .from('chat_messages')
        .select()
        .eq('room_id', roomId)
        .order('created_at', ascending: true);
    final base = rows.map<ChatMessage>(_messageFromRow).toList();
    if (base.isEmpty) return base;

    // Reaction summary in a second small round-trip. View is keyed by
    // message_id so we filter for just this room's ids.
    final ids = base.map((m) => m.messageId).toList();
    final summary = await _client
        .from('chat_message_reactions_summary')
        .select()
        .inFilter('message_id', ids);
    final byId = <String, Map<String, dynamic>>{
      for (final r in summary as List)
        (r as Map<String, dynamic>)['message_id'] as String: r,
    };

    return [
      for (final m in base)
        () {
          final row = byId[m.messageId];
          if (row == null) return m;
          final counts =
              (row['reaction_counts'] as Map?)?.cast<String, dynamic>() ?? {};
          return m.copyWith(
            reactionCounts: {
              for (final e in counts.entries)
                e.key: (e.value as num).toInt(),
            },
            myReaction: row['my_reaction'] as String?,
          );
        }(),
    ];
  }

  /// Toggle/swap/clear semantics (mirrors post reactions). Returns the
  /// resulting reaction, or null when cleared.
  Future<String?> setMessageReaction(String messageId, String? reaction) async {
    final res = await _client.rpc('set_chat_message_reaction', params: {
      'p_message_id': messageId,
      'p_reaction_type': reaction,
    });
    return res as String?;
  }

  ChatMessage _messageFromRow(Map<String, dynamic> r) {
    final uid = _uid;
    final rawRead = r['read_at'] as String?;
    return ChatMessage(
      messageId: r['message_id'] as String,
      roomId: r['room_id'] as String,
      senderId: (r['sender_id'] as String?) ?? 'unknown',
      plaintext: (r['encrypted_payload'] as String?) ?? '',
      createdAt: DateTime.parse(r['created_at'] as String),
      sentByMe: r['sender_id'] == uid,
      attachedPostId: r['attached_post_id'] as String?,
      attachedPostSnapshot:
          SharedPostSnapshot.fromJson(r['attached_post_snapshot']),
      readAt: rawRead == null ? null : DateTime.parse(rawRead),
      attachedMediaPath: r['attached_media_path'] as String?,
      attachedMediaType: r['attached_media_type'] as String?,
    );
  }

  /// Stamp read_at on every message in [roomId] not sent by the caller.
  /// Returns the count of newly-marked messages. Safe to call on every
  /// chat-screen open + every new-message arrival — idempotent.
  Future<int> markRoomRead(String roomId) async {
    final res =
        await _client.rpc('mark_chat_room_read', params: {'p_room_id': roomId});
    return (res as int?) ?? 0;
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

  // ──────────────────── Typing indicators (broadcast) ────────────────────

  /// Per-room Realtime broadcast channel. Cached so we don't
  /// resubscribe on every keystroke. Closed when the chat screen exits.
  final Map<String, RealtimeChannel> _typingChannels = {};

  RealtimeChannel _typingChannel(String roomId) {
    return _typingChannels.putIfAbsent(roomId, () {
      final c = _client.channel('typing:room=$roomId');
      c.subscribe();
      return c;
    });
  }

  /// Tell the room you're typing. UI should debounce this to ~once per
  /// 1.5 seconds. Pure broadcast — no DB row written.
  void broadcastTyping(String roomId) {
    final uid = _uid;
    if (uid == null) return;
    _typingChannel(roomId).sendBroadcastMessage(
      event: 'typing',
      payload: {
        'user_id': uid,
        'at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  /// Stream of "is the *peer* currently typing?" for [roomId]. Emits
  /// `true` immediately on a typing broadcast from a non-self user,
  /// and `false` ~3 seconds after the most recent broadcast goes quiet.
  Stream<bool> watchTyping(String roomId) {
    final controller = StreamController<bool>();
    Timer? idle;
    void clearIdle() {
      idle?.cancel();
      idle = Timer(const Duration(seconds: 3), () {
        if (!controller.isClosed) controller.add(false);
      });
    }

    final channel = _client
        .channel('typing:room=$roomId:listen')
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            final from = payload['user_id'] as String?;
            if (from == null || from == _uid) return;
            if (!controller.isClosed) controller.add(true);
            clearIdle();
          },
        )
        .subscribe();

    controller.onCancel = () {
      idle?.cancel();
      channel.unsubscribe();
    };
    // Seed with false so consumers don't see a null in tab switches.
    controller.onListen = () => controller.add(false);
    return controller.stream;
  }

  /// Upload an image file to the room's chat-media folder. Returns the
  /// storage path (`<roomId>/<messageId>.<ext>`) ready to be passed
  /// into [sendMessage] as `attachedMediaPath`.
  ///
  /// We pre-generate the message id client-side so the storage object
  /// name is stable and the receiver can fetch it independently of
  /// the chat_messages row arriving (small race window otherwise).
  Future<({String path, String messageId})> uploadChatImage({
    required String roomId,
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) async {
    final messageId = const Uuid().v4();
    final path = '$roomId/$messageId.$extension';
    await _client.storage.from('chat-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(
            contentType: contentType,
            upsert: false,
          ),
        );
    return (path: path, messageId: messageId);
  }

  /// Short-lived signed URL for an image stored under the chat-media
  /// bucket. The path comes from `chat_messages.attached_media_path`.
  Future<String> chatImageSignedUrl(String path) async {
    return await _client.storage.from('chat-media').createSignedUrl(
          path,
          3600, // 1 hour — plenty for a chat session render
        );
  }

  /// Send a plain chat message OR attach a shared post via the
  /// `send_chat_message` RPC. The RPC enforces room participation +
  /// active status, and captures the post snapshot at send time so
  /// the receiver can still see the card if the original gets deleted.
  Future<ChatMessage> sendMessage({
    required String roomId,
    required String payload,
    String? attachedPostId,
    String? attachedMediaPath,
    String? attachedMediaType,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final res = await _client.rpc(
      'send_chat_message',
      params: {
        'p_room_id': roomId,
        'p_payload': payload,
        'p_attached_post_id': attachedPostId,
        'p_media_path': attachedMediaPath,
        'p_media_type': attachedMediaType,
      },
    );
    final rows = res as List;
    if (rows.isEmpty) {
      throw StateError('send_chat_message returned no row');
    }
    final r = (rows.first as Map).cast<String, dynamic>();
    return ChatMessage(
      messageId: r['message_id'] as String,
      roomId: r['room_id'] as String,
      senderId: uid,
      plaintext: (r['payload'] as String?) ?? payload,
      createdAt: DateTime.parse(r['created_at'] as String),
      sentByMe: true,
      attachedPostId: r['attached_post_id'] as String?,
      attachedPostSnapshot:
          SharedPostSnapshot.fromJson(r['attached_post_snapshot']),
      attachedMediaPath: r['attached_media_path'] as String?,
      attachedMediaType: r['attached_media_type'] as String?,
    );
  }

  // ===================================================================
  // PROMPTS
  // ===================================================================
  Future<List<PlugPrompt>> prompts() async {
    // Filter on published_at so scheduled-future prompts (migration 0028)
    // stay hidden until the cron fanout (migration 0034) flips them.
    // is_active still gates manual disable.
    final rows = await _client
        .from('plug_prompts')
        .select(
            'prompt_id, prompt_text, answers_count, plug_profiles(display_name, users(avatar_seed))')
        .eq('is_active', true)
        .not('published_at', 'is', null)
        .lte('published_at', DateTime.now().toUtc().toIso8601String());
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
  // PROMPT ANSWERS  (Question-of-the-Day replies)
  // ===================================================================
  Future<List<PromptAnswer>> promptAnswers(String promptId) async {
    final rows = await _client
        .from('prompt_answers')
        .select(
          'answer_id, prompt_id, answer_text, created_at, author_id, '
          'users:author_id(anonymous_pseudonym, avatar_seed)',
        )
        .eq('prompt_id', promptId)
        .order('created_at', ascending: false)
        .limit(200);
    return rows.map<PromptAnswer>((r) {
      final u = r['users'] as Map<String, dynamic>?;
      return PromptAnswer(
        answerId: r['answer_id'] as String,
        promptId: r['prompt_id'] as String,
        authorPseudonym: u?['anonymous_pseudonym'] != null
            ? '@${u!['anonymous_pseudonym']}'
            : '@anonymous',
        authorAvatarSeed: (u?['avatar_seed'] as String?) ?? 'default-orb',
        text: r['answer_text'] as String,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
    }).toList();
  }

  Future<PromptAnswer> addPromptAnswer({
    required String promptId,
    required String text,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final row = await _client
        .from('prompt_answers')
        .insert({
          'prompt_id':   promptId,
          'author_id':   uid,
          'answer_text': text,
        })
        .select('answer_id, prompt_id, answer_text, created_at')
        .single();
    // Best-effort: bump the prompt's answers_count for the home strip.
    await _client.rpc('increment_prompt_answers', params: {
      'p_prompt_id': promptId,
    }).then((_) {}, onError: (_) async {
      // RPC may not exist on older deployments; fall back to a direct update.
      // Race: another inserter may bump first, but we accept some drift.
      final p = await _client
          .from('plug_prompts')
          .select('answers_count')
          .eq('prompt_id', promptId)
          .single();
      final cur = (p['answers_count'] as int?) ?? 0;
      await _client
          .from('plug_prompts')
          .update({'answers_count': cur + 1})
          .eq('prompt_id', promptId);
    });
    final me = _me;
    return PromptAnswer(
      answerId: row['answer_id'] as String,
      promptId: row['prompt_id'] as String,
      authorPseudonym: '@${me?.anonymousPseudonym ?? 'anonymous'}',
      authorAvatarSeed: me?.avatarSeed ?? 'default-orb',
      text: row['answer_text'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  // ===================================================================
  // NOTIFICATIONS  (RLS: notifications owner — user_id = auth.uid())
  // ===================================================================
  Future<void> markNotificationRead(String notificationId) async {
    await _client
        .from('notifications')
        .update({'is_read': true})
        .eq('notification_id', notificationId);
  }

  Future<void> markAllNotificationsRead() async {
    final uid = _uid;
    if (uid == null) return;
    await _client
        .from('notifications')
        .update({'is_read': true})
        .eq('user_id', uid)
        .eq('is_read', false);
  }
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
      final payload =
          (r['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      return NotificationItem(
        id: r['notification_id'] as String,
        kind: r['kind'] as String,
        title: (payload['title'] as String?) ?? _kindLabel(r['kind'] as String),
        body: (payload['body'] as String?) ?? '',
        createdAt: DateTime.parse(r['created_at'] as String),
        isRead: r['is_read'] as bool,
        payload: payload,
      );
    }).toList();
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'tribe_prompt':    return 'New tribe prompt';
      case 'tribe_invite':    return 'Tribe invitation';
      case 'message_request': return 'Message request';
      case 'comment_reply':   return 'New reply';
      case 'post_like':       return 'Reaction on your vent';
      case 'admin_broadcast': return 'Announcement';
      default:                return kind;
    }
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
      authorId: r['author_id'] as String?,
      authorPseudonym: (r['author_pseudonym'] as String?) ?? '@anonymous',
      authorAvatarSeed: (r['author_avatar_seed'] as String?) ?? 'default-orb',
      authorProfilePhotoUrl: r['author_profile_photo_url'] as String?,
      authorIsVerified: (r['author_is_verified'] as bool?) ?? false,
      categoryName: r['category_name'] as String,
      postType: r['post_type'] as String,
      content: r['content'] as String,
      postMood: r['post_mood'] as String,
      likesCount: r['likes_count'] as int,
      commentsCount: r['comments_count'] as int,
      createdAt: DateTime.parse(r['created_at'] as String),
      authorKarma: (r['author_karma'] as int?) ?? 0,
      tribeId: r['tribe_id'] as String?,
      tribeName: r['tribe_name'] as String?,
      tribeSlug: r['tribe_slug'] as String?,
      isWhisper: (r['is_whisper'] as bool?) ?? false,
      myReaction: _myReactions[r['post_id']],
      savedByMe: _savedPosts.contains(r['post_id']),
      crisisLevel: r['crisis_level'] as String?,
    );
  }

  CrisisHelpline _crisisFromRow(Map<String, dynamic> r) {
    return CrisisHelpline(
      resourceId: r['resource_id'] as String,
      region: r['region'] as String,
      label: r['label'] as String,
      reach: r['reach'] as String,
      url: r['url'] as String?,
      hours: (r['hours'] as String?) ?? '24/7',
      sortOrder: (r['sort_order'] as int?) ?? 100,
    );
  }

  Tribe _tribeFromRow(Map<String, dynamic> r) {
    // The studio fields (welcome_message, theme_color, spotlight_*) may
    // not be present in older callers' SELECT lists. tribeBySlug fetches
    // them explicitly; the directory and feed views don't.
    final spotlightSetAtRaw = r['spotlight_set_at'] as String?;
    return Tribe(
      tribeId: r['tribe_id'] as String,
      name: r['name'] as String,
      slug: r['slug'] as String,
      description: r['description'] as String?,
      category: r['category'] as String,
      memberCount: (r['member_count'] as int?) ?? 0,
      isPrivate: (r['is_private'] as bool?) ?? false,
      avatarUrl: r['avatar_url'] as String?,
      bannerUrl: r['banner_url'] as String?,
      keeperId: r['keeper_id'] as String?,
      keeperPseudonym: r['keeper_pseudonym'] as String?,
      keeperAvatarSeed: r['keeper_avatar_seed'] as String?,
      keeperIsVerified: (r['keeper_is_verified'] as bool?) ?? false,
      createdAt: DateTime.parse(r['created_at'] as String),
      joinedByMe: _joinedTribes.contains(r['tribe_id']),
      welcomeMessage: r['welcome_message'] as String?,
      themeColor: r['theme_color'] as String?,
      spotlightUserId: r['spotlight_user_id'] as String?,
      spotlightPseudonym: r['spotlight_pseudonym'] as String?,
      spotlightAvatarSeed: r['spotlight_avatar_seed'] as String?,
      spotlightNote: r['spotlight_note'] as String?,
      spotlightSetAt:
          spotlightSetAtRaw == null ? null : DateTime.parse(spotlightSetAtRaw),
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
      karmaPoints: (r['karma_points'] as int?) ?? 0,
      homeCity: r['home_city'] as String?,
      homeCountry: r['home_country'] as String?,
      homeCampus: r['home_campus'] as String?,
      profilePhotoUrl: r['profile_photo_url'] as String?,
    );
  }

  /// Friendly, UI-facing auth failure types — see [signUp] / [signIn].
  // (defined below the class)

  /// Look up a user by pseudonym (case-insensitive). Returns enough info to
  /// show a confirmation card before sending an invite.
  Future<Map<String, dynamic>?> findUserByPseudonym(String pseudonym) async {
    final cleaned = pseudonym.trim().replaceAll('@', '');
    if (cleaned.isEmpty) return null;
    final row = await _client
        .from('users')
        .select('user_id, anonymous_pseudonym, avatar_seed, is_verified')
        .ilike('anonymous_pseudonym', cleaned)
        .maybeSingle();
    return row;
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
