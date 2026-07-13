import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../domain/entities/entities.dart';
import '../../domain/keeper/keeper_mode.dart';
import '../../domain/keeper/keeper_studio_v2.dart';
import '../../domain/tribe/tribe_chat_hub.dart';
import 'identity_service.dart';

/// Coerces JSONB `{text: "…"}` or plain strings into a nullable String.
String? _coerceJsonTextField(dynamic raw) {
  if (raw == null) return null;
  if (raw is String) return raw.isEmpty ? null : raw;
  if (raw is Map) {
    final text = raw['text'];
    if (text is String && text.isNotEmpty) return text;
    if (text != null) return '$text';
    return null;
  }
  final s = raw.toString();
  return s.isEmpty ? null : s;
}

String? _coerceString(dynamic raw) {
  if (raw == null) return null;
  if (raw is String) return raw;
  if (raw is Map || raw is List) return null;
  return raw.toString();
}

int? _coerceInt(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString());
}

/// Live Supabase backend.
///
/// Mirrors the surface area of [MockBackend] so [VentlyRepository] can
/// transparently swap between the two. Everything goes through
/// PostgREST / Realtime / Supabase Auth.
class SupabaseBackend {
  SupabaseBackend._(this._client) {
    _client.auth.onAuthStateChange.listen((event) {
      _refreshLikedAndSaved();
      // Once per session, record the coarse country the user connects from so
      // the admin geo analytics are real. Fire-and-forget; country only, the
      // IP is never stored (see the geo-capture edge function).
      if (_client.auth.currentUser != null && !_geoPinged) {
        _geoPinged = true;
        unawaited(_pingGeoCapture());
      }
    });
  }

  bool _geoPinged = false;

  Future<void> _pingGeoCapture() async {
    try {
      await _client.functions.invoke('geo-capture');
    } catch (_) {
      // Best-effort analytics signal — never surface or block on failure.
    }
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

  static const _userBaseSelect =
      'user_id, anonymous_pseudonym, avatar_seed, current_mood, '
      'user_role, is_verified, account_status, safety_tier, birth_year, '
      'karma_points, home_city, home_country, home_campus';
  static const _userSelectWithProfilePhoto =
      '$_userBaseSelect, profile_photo_url, bio, pronouns';

  // ----- realtime fan-out used by the repository to stream the UI -----
  final _postsController = StreamController<List<Post>>.broadcast();
  final _roomsController = StreamController<List<ChatRoom>>.broadcast();
  Stream<List<Post>> get postsStream => _postsController.stream;
  Stream<List<ChatRoom>> get roomsStream => _roomsController.stream;

  RealtimeChannel? _postsChannel;
  RealtimeChannel? _roomsChannel;
  RealtimeChannel? _messagesNotifyChannel;

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

  /// Email-based signup. Mirrors [signUp] but uses the caller's real
  /// email instead of the synthetic handle. When the project enforces
  /// email confirmation, the AuthResponse session will be null —
  /// callers can detect that and route to a "check your email" screen
  /// instead of throwing.
  ///
  /// Returns null when session is null (email-confirm pending). The
  /// recovery blob + salt are still stored on the user row so the
  /// account can be restored later via the existing phrase-based flow.
  Future<AppUser?> signUpWithEmail({
    required String email,
    required String password,
    required String username,
    required String avatarSeed,
    required int birthYear,
    required String safetyTier,
    required String recoveryBlob,
    required String recoverySalt,
  }) async {
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
        throw const EmailTakenException();
      }
      rethrow;
    }
    final user = res.user;
    if (user == null) {
      throw StateError('Sign-up returned no user');
    }
    // Attach recovery materials whether or not the session is created
    // (the trigger has already inserted the user row).
    try {
      await _client.from('users').update({
        'recovery_blob': recoveryBlob,
        'recovery_salt': recoverySalt,
      }).eq('user_id', user.id);
    } catch (_) {/* row may not yet exist if confirm-required */}

    if (res.session == null) {
      // Email confirmation required — caller routes to a wait state.
      return null;
    }

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
    return _me;
  }

  /// Email-based sign-in for accounts created with [signUpWithEmail].
  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      await _client.auth
          .signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('invalid') || msg.contains('credentials')) {
        throw InvalidCredentialsException();
      }
      rethrow;
    }
    await _maybeRequireMfa();
    final user = await restore();
    if (user == null) {
      throw StateError('Signed in but no matching profile row');
    }
    return user;
  }

  /// Throws [MfaChallengeRequiredException] when the freshly-signed-in
  /// session is AAL1 but the user has a verified TOTP factor.
  Future<void> _maybeRequireMfa() async {
    try {
      final factors = await _client.auth.mfa.listFactors();
      final verified = factors.totp
          .where((f) => f.status == FactorStatus.verified)
          .toList();
      if (verified.isEmpty) return;
      final aal =
          _client.auth.mfa.getAuthenticatorAssuranceLevel();
      if (aal.nextLevel == AuthenticatorAssuranceLevels.aal2 &&
          aal.currentLevel != AuthenticatorAssuranceLevels.aal2) {
        throw MfaChallengeRequiredException(verified.first.id);
      }
    } on MfaChallengeRequiredException {
      rethrow;
    } catch (_) {
      // Swallow listing errors — if we can't tell, let the user proceed
      // rather than locking them out of their account.
    }
  }

  Future<void> verifyMfa({
    required String factorId,
    required String code,
  }) async {
    final challenge =
        await _client.auth.mfa.challenge(factorId: factorId);
    await _client.auth.mfa.verify(
      factorId: factorId,
      challengeId: challenge.id,
      code: code,
    );
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
    await _maybeRequireMfa();
    final user = await restore();
    if (user == null) {
      throw StateError('Signed in but no matching profile row');
    }
    return user;
  }

  // ===================== Optional real-email verification =================
  //
  // Venttly's core flow is anonymous (synthetic @id.venttly.app handles), so
  // Supabase's global "Confirm email" toggle stays OFF. For accounts created
  // with a REAL email we verify ownership ourselves: a 6-digit code goes out
  // via the email_outbox → email-dispatcher (Resend) pipeline, and the app
  // gates sensitive actions on `users.email_verified`.

  /// Issues + emails a fresh verification code. Idempotent; server-side
  /// rate-limited to one send per 60s. Requires migration 0072.
  Future<void> sendEmailVerification() async {
    await _client.rpc('request_email_verification');
  }

  /// Confirms a 6-digit [code]. Returns true when the email is now verified.
  Future<bool> confirmEmailVerification(String code) async {
    final res = await _client
        .rpc('confirm_email_verification', params: {'p_code': code});
    final ok = res == true;
    if (ok) {
      // Refresh the cached session so `emailVerified` flips app-wide.
      _me = _me?.copyWith(emailVerified: true);
    }
    return ok;
  }

  /// Marks the current account verified without a code — used only for
  /// provider-verified signups (Google / phone), whose provider already
  /// proved email/number ownership.
  Future<void> markEmailVerified() async {
    await _client.rpc('mark_email_verified');
    _me = _me?.copyWith(emailVerified: true);
  }

  /// Best-effort read of the current account's verified flag. Returns false
  /// if the column/migration isn't present yet (never blocks the app).
  Future<bool> refreshEmailVerified() async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final row = await _client
          .from('users')
          .select('email_verified')
          .eq('user_id', uid)
          .maybeSingle();
      final v = (row?['email_verified'] as bool?) ?? false;
      _me = _me?.copyWith(emailVerified: v);
      return v;
    } catch (_) {
      return false;
    }
  }

  /// True when this account authenticates with a REAL email (not a synthetic
  /// anonymous handle). Only these accounts are ever gated on verification.
  bool get hasRealEmail {
    final email = _client.auth.currentUser?.email;
    return email != null &&
        email.isNotEmpty &&
        !email.endsWith('@id.venttly.app');
  }

  String? get currentEmail => _client.auth.currentUser?.email;

  // ===================== OAuth (Google) & phone OTP =======================
  //
  // Both are OPTIONAL entry methods. They need provider config in the
  // Supabase dashboard (Google provider + redirect URL; an SMS provider for
  // phone). The auth trigger auto-creates the profile row on first sign-in.

  /// Launches the Google OAuth flow. On success the session arrives via the
  /// redirect deep link and `onAuthStateChange` restores the profile.
  /// Requires: Google provider enabled + `redirectTo` allow-listed in
  /// Supabase → Authentication → URL Configuration.
  Future<bool> signInWithGoogle() {
    return _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: VentlyConfig.oauthRedirectUrl.isEmpty
          ? null
          : VentlyConfig.oauthRedirectUrl,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
  }

  /// Sends an SMS OTP to [phone] (E.164, e.g. +250788123456). Requires an SMS
  /// provider configured in Supabase → Authentication → Providers → Phone.
  Future<void> startPhoneOtp(String phone) async {
    await _client.auth.signInWithOtp(phone: phone);
  }

  /// Verifies the [token] texted to [phone] and returns the profile.
  Future<AppUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    await _client.auth.verifyOTP(
      phone: phone,
      token: token,
      type: OtpType.sms,
    );
    final user = await restore();
    if (user == null) {
      throw StateError('Verified phone but no matching profile row');
    }
    try {
      await markEmailVerified();
    } catch (_) {/* migration 0072 may be pending; non-fatal */}
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
    final row = await _selectUserById(uid);
    if (row == null) return null;
    _me = _userFromRow(row);
    await _hydrateRealtime();
    return _me;
  }

  Future<Map<String, dynamic>?> _selectUserById(String uid) async {
    try {
      return await _client
          .from('users')
          .select(_userSelectWithProfilePhoto)
          .eq('user_id', uid)
          .maybeSingle();
    } on PostgrestException catch (e) {
      final missingProfilePhoto = e.message.contains('profile_photo_url') &&
          (e.code == '42703' ||
              e.message.contains('42703') ||
              e.message.contains('does not exist'));
      if (!missingProfilePhoto) rethrow;
      return await _client
          .from('users')
          .select(_userBaseSelect)
          .eq('user_id', uid)
          .maybeSingle();
    }
  }

  Future<void> logout() async {
    await _postsChannel?.unsubscribe();
    await _roomsChannel?.unsubscribe();
    await _messagesNotifyChannel?.unsubscribe();
    _postsChannel = null;
    _roomsChannel = null;
    _messagesNotifyChannel = null;
    await _client.auth.signOut();
    _me = null;
    _myReactions.clear();
    _savedPosts.clear();
    _joinedTribes.clear();
  }

  // ===================== Password & security ==============================

  /// Rotate the signed-in user's password. We RE-AUTHENTICATE with the
  /// current password first: `updateUser` alone would let anyone holding an
  /// unlocked session silently change it. A wrong current password throws
  /// [AuthException] before we touch anything.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final email = _client.auth.currentUser?.email;
    if (email == null) {
      throw StateError('You are not signed in.');
    }
    await _client.auth.signInWithPassword(
      email: email,
      password: currentPassword,
    );
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  /// Attach (or change) a real recovery email on an account. Supabase emails
  /// a confirmation to the new address; the change finalises when the link is
  /// confirmed. Login-by-username keeps working either way.
  Future<void> setRecoveryEmail(String email) async {
    await _client.auth.updateUser(UserAttributes(email: email.trim()));
  }

  /// Global sign-out — revokes the refresh token on EVERY device, not just
  /// this one. Same local teardown as [logout].
  Future<void> signOutEverywhere() async {
    await _postsChannel?.unsubscribe();
    await _roomsChannel?.unsubscribe();
    await _messagesNotifyChannel?.unsubscribe();
    _postsChannel = null;
    _roomsChannel = null;
    _messagesNotifyChannel = null;
    await _client.auth.signOut(scope: SignOutScope.global);
    _me = null;
    _myReactions.clear();
    _savedPosts.clear();
    _joinedTribes.clear();
  }

  Future<void> _hydrateRealtime() async {
    await _refreshLikedAndSaved();
    _subscribePostsRealtime();
    _subscribeRoomsRealtime();
    _subscribeMessagesNotifyRealtime();
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

  /// New messages don't always touch chat_rooms — refresh inbox on INSERT
  /// so unread counts + foreground notifications stay current.
  void _subscribeMessagesNotifyRealtime() {
    _messagesNotifyChannel?.unsubscribe();
    _messagesNotifyChannel = _client
        .channel('public:chat_messages:inbox-notify')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_messages',
          callback: (payload) {
            _emitRooms();
            // The client has now received this message — stamp the
            // "delivered" tick for the sender (migration 0114). RLS
            // already scopes events to rooms we belong to.
            final roomId = payload.newRecord['room_id'] as String?;
            final senderId = payload.newRecord['sender_id'] as String?;
            if (roomId != null && senderId != null && senderId != _uid) {
              unawaited(markRoomDelivered(roomId));
            }
          },
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
    int limit = 30,
    int offset = 0,
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
          'p_offset': offset,
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
    final ordered = sort == 'hot'
        ? query.order('hot_score', ascending: false)
        : query.order('created_at', ascending: false);
    final rows = await ordered.range(offset, offset + limit - 1);
    // Whispers vanish from the feed after 24h. We filter client-side
    // because PostgREST's `or` filter doesn't cleanly express
    // "is_whisper = false OR created_at > now() - 24h" against a view.
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    return rows
        .map<Post>(_postFromRow)
        .where((p) => !p.isWhisper || p.createdAt.isAfter(cutoff))
        .toList();
  }

  Future<List<Post>> friendStories({int limit = 24}) async {
    try {
      final rows = await _client.rpc(
        'friend_stories_for_me',
        params: {'p_limit': limit},
      ) as List<dynamic>;
      return rows.cast<Map<String, dynamic>>().map<Post>(_postFromRow).toList();
    } on PostgrestException catch (e) {
      if (!_isMissingRpc(e, 'friend_stories_for_me')) rethrow;
      return _clientFilteredFriendStories(limit: limit);
    }
  }

  Future<List<Post>> _clientFilteredFriendStories({required int limit}) async {
    final uid = _uid;
    if (uid == null) return const [];
    final friends = await myFriends();
    final friendIds = friends.map((f) => f.userId).toSet();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final fallbackLimit = (limit * 4).clamp(24, 120).toInt();
    final posts = await feed(sort: 'hot', limit: fallbackLimit);
    return posts
        .where((p) =>
            p.isWhisper &&
            p.authorId != null &&
            p.createdAt.isAfter(cutoff) &&
            (p.authorId == uid || friendIds.contains(p.authorId)))
        .take(limit)
        .toList();
  }

  bool _isMissingRpc(PostgrestException e, String name) {
    return e.code == '42883' ||
        e.code == 'PGRST202' ||
        (e.message.contains(name) && e.message.contains('does not exist')) ||
        e.message.contains('Could not find the function');
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
    String? spaceId,
    String? personaId,
    bool isWhisper = false,
    String? imagePath,
    String? imageUrl,
    String? audioPath,
    String? audioUrl,
    int? audioDurationSeconds,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final inserted = await _client.from('posts').insert({
      'author_id':              uid,
      'tribe_id':               tribeId,
      if (spaceId != null) 'space_id': spaceId,
      'persona_id':             personaId,
      'category_name':          category,
      'post_type':              'user_post',
      'content':                content,
      'post_mood':              mood,
      'is_whisper':             isWhisper,
      if (imagePath != null) 'image_path':             imagePath,
      if (imageUrl  != null) 'image_url':              imageUrl,
      if (audioPath != null) 'audio_path':             audioPath,
      if (audioUrl  != null) 'audio_url':              audioUrl,
      if (audioDurationSeconds != null)
        'audio_duration_seconds': audioDurationSeconds,
      // Safe-by-default: an image starts 'pending' (veiled) until media-scan
      // clears it; text-only posts are 'clean'. (migration 0087)
      'media_status': hasImage ? 'pending' : 'clean',
    }).select('post_id').single();
    final postId = inserted['post_id'] as String;
    if (hasImage) {
      unawaited(_scanMedia(kind: 'post', id: postId, imageUrl: imageUrl));
    }
    final post = await postById(postId);
    _emitPosts();
    return post!;
  }

  /// Fire the authoritative image safety scan (nudity/gore) for just-uploaded
  /// media. Best-effort: the row stays 'pending' (veiled) if this never lands.
  Future<void> _scanMedia({
    required String kind,
    required String id,
    required String imageUrl,
  }) async {
    try {
      await _client.functions.invoke('media-scan',
          body: {'kind': kind, 'id': id, 'imageUrl': imageUrl});
    } catch (_) {
      // Safe by default — unscanned media remains veiled, never shown clean.
    }
  }

  /// Upload a JPEG/PNG/WebP into the public `post-media` bucket under
  /// `<uid>/<uuid>.<ext>` and return the storage path + public URL.
  /// The matching post row is inserted afterwards via [createPost].
  Future<({String path, String url})> uploadPostImage({
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
    final path = '$uid/${const Uuid().v4()}.${safeExt.isEmpty ? 'jpg' : safeExt}';
    await _client.storage.from('post-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    final url = _client.storage.from('post-media').getPublicUrl(path);
    return (path: path, url: url);
  }

  // ===================================================================
  // PREMIUM HOME — migration 0038
  // ===================================================================

  /// Single-roundtrip read for the 4 hero KPIs.
  Future<HomeStats> homeStats() async {
    final rows = await _client.rpc('home_stats') as List<dynamic>;
    if (rows.isEmpty) return HomeStats.empty;
    final r = (rows.first as Map).cast<String, dynamic>();
    return HomeStats(
      ventsToday:  (r['vents_today']  as int?) ?? 0,
      supporters:  (r['supporters']   as int?) ?? 0,
      dailyHugs:   (r['daily_hugs']   as int?) ?? 0,
      streakDays:  (r['streak_days']  as int?) ?? 0,
    );
  }

  /// Global Pulse hashtag chips (24h-window category leaderboard).
  Future<List<TrendingCategory>> trendingCategories({int limit = 6}) async {
    final rows = await _client.rpc(
      'trending_categories',
      params: {'p_limit': limit},
    ) as List<dynamic>;
    return rows.map((r) {
      final m = (r as Map).cast<String, dynamic>();
      return TrendingCategory(
        categoryName: m['category_name'] as String,
        postCount:    (m['post_count']   as int?) ?? 0,
        reactionSum:  (m['reaction_sum'] as int?) ?? 0,
      );
    }).toList();
  }

  /// Rising Voices for the Discover screen — top 7d engagement.
  Future<List<TrendingVoice>> trendingVoices({int limit = 6}) async {
    final rows = await _client.rpc(
      'trending_voices',
      params: {'p_limit': limit},
    ) as List<dynamic>;
    return rows.map((r) {
      final m = (r as Map).cast<String, dynamic>();
      return TrendingVoice(
        userId:           m['user_id']           as String,
        pseudonym:        m['pseudonym']         as String,
        avatarSeed:       (m['avatar_seed']      as String?) ?? 'default-orb',
        profilePhotoUrl:  m['profile_photo_url'] as String?,
        isVerified:       (m['is_verified']      as bool?)   ?? false,
        topQuote:         (m['top_quote']        as String?) ?? '',
        topCategory:      (m['top_category']     as String?) ?? 'confessions',
        topMood:          (m['top_mood']         as String?) ?? 'healing',
        engagementScore:  (m['engagement_score'] as int?)    ?? 0,
      );
    }).toList();
  }

  /// Unified search across tribes + posts + topics. Empty / very short
  /// queries return an empty list. Hit shape: [SearchHit].
  Future<List<SearchHit>> searchGlobal(String query, {int limit = 24}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final rows = await _client.rpc(
      'search_global',
      params: {'p_query': q, 'p_limit': limit},
    ) as List<dynamic>;
    return rows.map((r) {
      final m = (r as Map).cast<String, dynamic>();
      final createdAtRaw = m['created_at'] as String?;
      return SearchHit(
        hitKind:         m['hit_kind']          as String,
        hitId:           m['hit_id']            as String,
        title:           (m['title']            as String?) ?? '',
        subtitle:        (m['subtitle']         as String?) ?? '',
        avatarSeed:      m['avatar_seed']       as String?,
        profilePhotoUrl: m['profile_photo_url'] as String?,
        memberCount:     m['member_count']      as int?,
        postCount:       m['post_count']        as int?,
        likesCount:      m['likes_count']       as int?,
        commentsCount:   m['comments_count']    as int?,
        createdAt:       createdAtRaw == null ? null : DateTime.parse(createdAtRaw),
        rankScore:       (m['rank_score'] as num?)?.toDouble() ?? 0,
      );
    }).toList();
  }

  /// Idempotent — first time the caller opens a story it's counted, after
  /// that it's a no-op. Returns true when a new view row was inserted.
  Future<bool> markStoryViewed(String postId) async {
    final res = await _client.rpc(
      'mark_story_viewed',
      params: {'p_post_id': postId},
    );
    return (res as bool?) ?? false;
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

  /// Tag a just-sent tribe (chat hub) message with a crisis level so it reaches
  /// the admin Safety queue. Author-only on the DB. (0083)
  Future<void> setTribeMessageCrisis(String messageId, String level) async {
    await _client.rpc('set_tribe_message_crisis', params: {
      'p_message_id': messageId,
      'p_level': level,
    });
  }

  /// Tag a just-sent DM with a crisis level. DM bodies are encrypted, so the
  /// classifier ran client-side on the plaintext before this call. (0083)
  Future<void> setChatMessageCrisis(String messageId, String level) async {
    await _client.rpc('set_chat_message_crisis', params: {
      'p_message_id': messageId,
      'p_level': level,
    });
  }

  /// Active automod keyword rules (migration 0085). RLS returns only active
  /// rows to normal users, so this is exactly the on-device rule set.
  Future<List<AutomodRule>> automodRules() async {
    final rows = await _client
        .from('automod_rules')
        .select('pattern, match_type, category, action')
        .eq('is_active', true);
    return (rows as List).cast<Map<String, dynamic>>().map((r) {
      return AutomodRule(
        pattern: (r['pattern'] as String?) ?? '',
        matchType: (r['match_type'] as String?) ?? 'contains',
        category: (r['category'] as String?) ?? 'other',
        action: (r['action'] as String?) ?? 'block',
      );
    }).where((r) => r.pattern.isNotEmpty).toList();
  }

  /// GDPR/CCPA export — returns the caller's full data bundle (migration 0092).
  Future<Map<String, dynamic>> exportMyData() async {
    final res = await _client.rpc('export_my_data');
    if (res is Map) return Map<String, dynamic>.from(res);
    return <String, dynamic>{};
  }

  /// Server-side Tier-2 moderation via the `moderate` edge function (keeps the
  /// Groq key off-device + trusted verdict cache, migration 0091). Returns the
  /// raw verdict map {verdict, categories, reason} or null on failure.
  Future<Map<String, dynamic>?> moderateRemote(String text) async {
    try {
      final res =
          await _client.functions.invoke('moderate', body: {'text': text});
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } catch (_) {
      return null; // Fail-open — Tier-1 on-device still applies.
    }
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

  // ---------- DM room preferences (migration 0098) ----------
  Future<DmRoomPrefs> dmRoomPrefs(String roomId) async {
    final uid = _uid;
    if (uid == null) return DmRoomPrefs.empty;
    final row = await _client
        .from('dm_room_prefs')
        .select()
        .eq('room_id', roomId)
        .eq('user_id', uid)
        .maybeSingle();
    if (row == null) return DmRoomPrefs.empty;
    return DmRoomPrefs(
      muted: row['muted'] == true,
      peerNickname: row['peer_nickname'] as String?,
      disappearingSeconds: (row['disappearing_seconds'] as int?) ?? 0,
      theme: (row['theme'] as String?) ?? 'default',
    );
  }

  Future<void> setDmRoomPref({
    required String roomId,
    bool? muted,
    String? peerNickname,
    bool clearNickname = false,
    int? disappearingSeconds,
    String? theme,
  }) async {
    await _client.rpc('set_dm_room_pref', params: {
      'p_room_id': roomId,
      'p_muted': muted,
      'p_peer_nickname': peerNickname,
      'p_clear_nickname': clearNickname,
      'p_disappearing': disappearingSeconds,
      'p_theme': theme,
    });
  }

  /// Conversation-level disappearing-message TTL (migration 0099), shared by
  /// both participants. 0 = off.
  Future<int> roomDisappearingSeconds(String roomId) async {
    final row = await _client
        .from('chat_rooms')
        .select('disappearing_seconds')
        .eq('room_id', roomId)
        .maybeSingle();
    return (row?['disappearing_seconds'] as int?) ?? 0;
  }

  Future<void> setRoomDisappearing(String roomId, int seconds) async {
    await _client.rpc('set_room_disappearing',
        params: {'p_room_id': roomId, 'p_seconds': seconds});
  }

  Future<List<FriendSummary>> myFriends() async {
    final rows = await _client
        .from('my_friends')
        .select()
        .order('accepted_at', ascending: false);
    final friends = (rows as List)
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
    if (friends.isEmpty) return friends;

    // Fold in the caller's favorites (toggleable heart on the alphabetical
    // list). Defaults to none if the favourites table isn't reachable.
    try {
      final favRows = await _client
          .from('friendship_favorites')
          .select('friendship_id');
      final favored = <String>{
        for (final r in favRows as List)
          (r as Map<String, dynamic>)['friendship_id'] as String,
      };
      if (favored.isEmpty) return friends;
      return [
        for (final f in friends)
          favored.contains(f.friendshipId)
              ? f.copyWith(isFavorite: true)
              : f,
      ];
    } catch (_) {
      return friends;
    }
  }

  Future<bool> toggleFriendFavorite(String friendshipId) async {
    final res = await _client.rpc(
      'toggle_friend_favorite',
      params: {'p_friendship_id': friendshipId},
    );
    return (res as bool?) ?? false;
  }

  // ===================================================================
  // TRIBE GROUP CHAT — migration 0041
  // ===================================================================

  Future<List<TribeMessage>> tribeMessages(String tribeId,
      {int limit = 80}) async {
    final rows = await _client
        .from('tribe_messages_feed')
        .select()
        .eq('tribe_id', tribeId)
        .filter('deleted_at', 'is', null)
        .order('created_at', ascending: true)
        .limit(limit);
    final all = (rows as List)
        .cast<Map<String, dynamic>>()
        .map(_tribeMessageFromRow)
        .toList();
    if (all.isEmpty) return all;

    // Delete-for-me: drop messages the caller has hidden. RLS scopes
    // tribe_message_hides to the caller. Done client-side so realtime
    // refetches respect it too.
    final ids = all.map((m) => m.messageId).toList();
    final hideRows = await _client
        .from('tribe_message_hides')
        .select('message_id')
        .inFilter('message_id', ids);
    final hidden = <String>{
      for (final h in hideRows as List)
        (h as Map<String, dynamic>)['message_id'] as String,
    };
    if (hidden.isEmpty) return all;
    return all.where((m) => !hidden.contains(m.messageId)).toList();
  }

  TribeMessage _tribeMessageFromRow(Map<String, dynamic> r) {
    final editedRaw  = r['edited_at']  as String?;
    final deletedRaw = r['deleted_at'] as String?;
    return TribeMessage(
      messageId:          r['message_id']     as String,
      tribeId:            r['tribe_id']       as String,
      senderId:           r['sender_id']      as String?,
      senderPseudonym:    (r['sender_pseudonym'] as String?) ?? 'anonymous',
      senderAvatarSeed:   (r['sender_avatar_seed'] as String?) ?? 'default-orb',
      senderProfilePhotoUrl: r['sender_profile_photo_url'] as String?,
      senderIsVerified:   (r['sender_is_verified'] as bool?) ?? false,
      senderPersonaId:    r['sender_persona_id'] as String?,
      content:            r['content']        as String?,
      imageUrl:           r['image_url']      as String?,
      audioUrl:           r['audio_url']      as String?,
      audioDurationSeconds: r['audio_duration_seconds'] as int?,
      hugsCount:          (r['hugs_count']    as int?) ?? 0,
      createdAt:          DateTime.parse(r['created_at'] as String),
      editedAt:           editedRaw  == null ? null : DateTime.parse(editedRaw),
      deletedAt:          deletedRaw == null ? null : DateTime.parse(deletedRaw),
      sentByMe:           r['sender_id'] == _uid,
      replyToMessageId:   r['reply_to_message_id'] as String?,
      replyContent:       r['reply_content'] as String?,
      replySenderPseudonym: r['reply_sender_pseudonym'] as String?,
      huggedByMe:         r['hugged_by_me'] == true,
      isPinned:           r['is_pinned'] == true,
      metadata:           _jsonMap(r['metadata']),
      pollMyVoteOptionId: r['poll_my_vote_option_id'] as String?,
      pollOptionCounts:   _pollCountsFromRow(r['poll_option_counts']),
      myReaction:         r['my_reaction'] as String?,
      reactionCounts:     _pollCountsFromRow(r['reaction_counts']),
      questionReplyCount: (r['question_reply_count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic>? _jsonMap(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  Map<String, int>? _pollCountsFromRow(dynamic raw) {
    final map = _jsonMap(raw);
    if (map == null || map.isEmpty) return null;
    return map.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
  }

  /// Realtime fan-out of new tribe messages. Subscribes to postgres
  /// changes on `tribe_messages` filtered by tribe_id; refetches the
  /// thread on every event so reads include the joined sender row.
  Stream<List<TribeMessage>> watchTribeMessages(String tribeId) {
    final controller = StreamController<List<TribeMessage>>();
    Future<void> emit() async {
      try {
        controller.add(await tribeMessages(tribeId));
      } catch (_) {}
    }

    final channel = _client.channel('tribe_chat_$tribeId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'tribe_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'tribe_id',
          value: tribeId,
        ),
        callback: (_) => emit(),
      )
      ..subscribe((_, __) {});
    emit();

    controller.onCancel = () async {
      await channel.unsubscribe();
      await controller.close();
    };
    return controller.stream;
  }

  Future<String> sendTribeMessage({
    required String tribeId,
    String? content,
    String? personaId,
    String? imagePath,
    String? imageUrl,
    String? audioPath,
    String? audioUrl,
    int? audioDurationSeconds,
    String? replyToMessageId,
    Map<String, dynamic>? metadata,
  }) async {
    final res = await _client.rpc('send_tribe_message', params: {
      'p_tribe_id':              tribeId,
      'p_content':               content,
      'p_persona_id':            personaId,
      'p_image_url':             imageUrl,
      'p_image_path':            imagePath,
      'p_audio_url':             audioUrl,
      'p_audio_path':            audioPath,
      'p_audio_duration_seconds': audioDurationSeconds,
      'p_reply_to_message_id':   replyToMessageId,
      'p_metadata':              metadata,
    });
    return res as String;
  }

  Future<void> voteTribeChatPoll({
    required String messageId,
    required String optionId,
  }) async {
    await _client.rpc('vote_tribe_chat_poll', params: {
      'p_message_id': messageId,
      'p_option_id': optionId,
    });
  }

  Future<void> closeTribeChatPoll(String messageId) async {
    await _client.rpc('close_tribe_chat_poll', params: {
      'p_message_id': messageId,
    });
  }

  Future<void> setTribeMessageReaction({
    required String messageId,
    required String emoji,
  }) async {
    await _client.rpc('set_tribe_message_reaction', params: {
      'p_message_id': messageId,
      'p_emoji': emoji,
    });
  }

  Future<({String path, String url})> uploadTribeChatImage({
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
    final path = '$uid/${const Uuid().v4()}.${safeExt.isEmpty ? 'jpg' : safeExt}';
    await _client.storage.from('tribe-chat-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    final url = _client.storage.from('tribe-chat-media').getPublicUrl(path);
    return (path: path, url: url);
  }

  // ===================================================================
  // WHISPERS — migration 0042
  // ===================================================================

  /// Whispers scoped to a single author — drives the Whispers section
  /// on the friend profile screen.
  Future<List<Whisper>> whispersForAuthor(String authorId,
      {int limit = 12}) async {
    final rows = await _client
        .from('whispers_feed')
        .select()
        .eq('author_id', authorId)
        .filter('deleted_at', 'is', null)
        .order('created_at', ascending: false)
        .limit(limit);
    final base = (rows as List)
        .cast<Map<String, dynamic>>()
        .map(_whisperFromRow)
        .toList();
    return _whispersWithMyFlags(base);
  }

  Future<List<Whisper>> listWhispers({
    int limit = 30,
    int offset = 0,
    String? category,
  }) async {
    var q = _client
        .from('whispers_feed')
        .select()
        .filter('deleted_at', 'is', null);
    if (category != null) q = q.eq('category_name', category);
    final rows = await q
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    final base = (rows as List)
        .cast<Map<String, dynamic>>()
        .map(_whisperFromRow)
        .toList();
    if (base.isEmpty) return base;
    return _whispersWithMyFlags(base);
  }

  Future<List<Whisper>> _whispersWithMyFlags(List<Whisper> base) async {
    try {
      final ids = base.map((w) => w.whisperId).toList();
      final saves = await _client
          .from('whisper_saves')
          .select('whisper_id')
          .inFilter('whisper_id', ids);
      final saved = <String>{
        for (final r in saves as List)
          (r as Map<String, dynamic>)['whisper_id'] as String,
      };

      final summaries = await _client
          .from('whisper_reactions_summary')
          .select()
          .inFilter('whisper_id', ids);
      final byWhisper = <String, Map<String, dynamic>>{
        for (final r in summaries as List)
          (r as Map<String, dynamic>)['whisper_id'] as String: r,
      };

      return [
        for (final w in base)
          () {
            final row = byWhisper[w.whisperId];
            Map<String, int> counts = {};
            String? myReaction;
            if (row != null) {
              final raw =
                  (row['reaction_counts'] as Map?)?.cast<String, dynamic>() ??
                      {};
              counts = {
                for (final e in raw.entries)
                  e.key: (e.value as num).toInt(),
              };
              myReaction = row['my_reaction'] as String?;
            }
            return w.copyWith(
              savedByMe: saved.contains(w.whisperId),
              reactionCounts: counts,
              myReaction: myReaction,
              likedByMe: myReaction != null,
            );
          }(),
      ];
    } catch (_) {
      return base;
    }
  }

  Future<bool> toggleWhisperSave(String whisperId) async {
    final res = await _client.rpc(
      'toggle_whisper_save',
      params: {'p_whisper_id': whisperId},
    );
    return (res as bool?) ?? false;
  }

  Future<List<Whisper>> mySavedWhispers() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('whisper_saves')
        .select('whisper_id, created_at')
        .eq('user_id', uid)
        .order('created_at', ascending: false);
    final ids = (rows as List)
        .cast<Map<String, dynamic>>()
        .map((r) => r['whisper_id'] as String)
        .toList();
    if (ids.isEmpty) return const [];
    final feed = await _client
        .from('whispers_feed')
        .select()
        .inFilter('whisper_id', ids)
        .filter('deleted_at', 'is', null);
    final byId = {
      for (final r in feed as List)
        (r as Map<String, dynamic>)['whisper_id'] as String:
            _whisperFromRow(r),
    };
    final ordered = [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
    return _whispersWithMyFlags(ordered);
  }

  Whisper _whisperFromRow(Map<String, dynamic> r) {
    final rawEdited  = r['edited_at']  as String?;
    final rawDeleted = r['deleted_at'] as String?;
    return Whisper(
      whisperId:              r['whisper_id']            as String,
      authorId:               r['author_id']             as String?,
      authorPseudonym:        (r['author_pseudonym']     as String?) ?? 'anonymous',
      authorAvatarSeed:       (r['author_avatar_seed']   as String?) ?? 'default-orb',
      authorProfilePhotoUrl:  r['author_profile_photo_url'] as String?,
      authorIsVerified:       (r['author_is_verified']   as bool?)   ?? false,
      audioUrl:               r['audio_url']             as String,
      audioDurationSeconds:   (r['audio_duration_seconds'] as int?) ?? 0,
      backgroundImageUrl:     r['background_image_url']  as String?,
      voiceFilter:            (r['voice_filter']         as String?) ?? 'none',
      category:               r['category_name']         as String,
      title:                  r['title']                 as String?,
      description:            r['description']           as String?,
      playsCount:             (r['plays_count']          as int?)    ?? 0,
      likesCount:             (r['likes_count']          as int?)    ?? 0,
      commentsCount:          (r['comments_count']       as int?)    ?? 0,
      crisisLevel:            r['crisis_level']          as String?,
      mediaStatus:            (r['media_status'] as String?) ?? 'clean',
      createdAt:              DateTime.parse(r['created_at'] as String),
      editedAt:               rawEdited  == null ? null : DateTime.parse(rawEdited),
      deletedAt:              rawDeleted == null ? null : DateTime.parse(rawDeleted),
    );
  }

  Future<String> createWhisper({
    required String audioPath,
    required String audioUrl,
    required int audioDurationSeconds,
    required String category,
    String? backgroundImageUrl,
    String voiceFilter = 'none',
    String? title,
    String? description,
    String? personaId,
  }) async {
    final res = await _client.rpc('create_whisper', params: {
      'p_audio_path':             audioPath,
      'p_audio_url':              audioUrl,
      'p_audio_duration_seconds': audioDurationSeconds,
      'p_category_name':          category,
      'p_background_image_url':   backgroundImageUrl,
      'p_voice_filter':           voiceFilter,
      'p_title':                  title,
      'p_description':            description,
      'p_persona_id':             personaId,
    });
    final whisperId = res as String;
    // Background image starts 'pending' (veiled) via create_whisper; kick off
    // the authoritative safety scan. Best-effort — stays veiled if it fails.
    if (backgroundImageUrl != null && backgroundImageUrl.isNotEmpty) {
      unawaited(_scanMedia(
          kind: 'whisper', id: whisperId, imageUrl: backgroundImageUrl));
    }
    return whisperId;
  }

  Future<bool> toggleWhisperLike(String whisperId) async {
    final res = await _client.rpc(
      'toggle_whisper_like',
      params: {'p_whisper_id': whisperId},
    );
    return (res as bool?) ?? false;
  }

  /// Full reaction palette — returns resulting reaction or null when cleared.
  Future<String?> reactToWhisper(String whisperId, String reaction) async {
    final res = await _client.rpc(
      'set_whisper_reaction',
      params: {
        'p_whisper_id': whisperId,
        'p_reaction': reaction,
      },
    );
    return res as String?;
  }

  Future<void> bumpWhisperPlays(String whisperId) async {
    await _client.rpc(
      'bump_whisper_plays',
      params: {'p_whisper_id': whisperId},
    );
  }

  Future<List<WhisperComment>> listWhisperComments(
    String whisperId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await _client.rpc(
      'list_whisper_comments',
      params: {
        'p_whisper_id': whisperId,
        'p_limit': limit,
        'p_offset': offset,
      },
    ) as List<dynamic>;
    return rows
        .cast<Map<String, dynamic>>()
        .map(
          (r) => WhisperComment(
            commentId: r['comment_id'] as String,
            whisperId: r['whisper_id'] as String,
            authorId: r['author_id'] as String?,
            authorPseudonym:
                (r['author_pseudonym'] as String?) ?? 'anonymous',
            authorAvatarSeed:
                (r['author_avatar_seed'] as String?) ?? 'default-orb',
            content: r['content'] as String,
            createdAt: DateTime.parse(r['created_at'] as String),
            parentId: r['parent_id'] as String?,
            likesCount: (r['likes_count'] as int?) ?? 0,
            likedByMe: (r['liked_by_me'] as bool?) ?? false,
            canDelete: (r['can_delete'] as bool?) ?? false,
          ),
        )
        .toList();
  }

  /// Realtime stream of comments on a whisper — re-fetches through the
  /// list RPC on every Postgres change so joins (pseudonym/avatar) stay
  /// correct. Mirrors [watchMessages].
  Stream<List<WhisperComment>> watchWhisperComments(String whisperId) {
    final controller = StreamController<List<WhisperComment>>();
    Future<void> emit() async {
      try {
        controller.add(await listWhisperComments(whisperId));
      } catch (_) {/* listener retries on next event */}
    }

    final channel = _client
        .channel('whisper_comments:$whisperId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'whisper_comments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'whisper_id',
            value: whisperId,
          ),
          callback: (_) => emit(),
        )
        .subscribe();

    controller.onListen = emit;
    controller.onCancel = () => channel.unsubscribe();
    return controller.stream;
  }

  Future<String> addWhisperComment(
    String whisperId,
    String content, {
    String? personaId,
    String? parentId,
  }) async {
    final res = await _client.rpc(
      'add_whisper_comment',
      params: {
        'p_whisper_id': whisperId,
        'p_content': content,
        'p_persona_id': personaId,
        'p_parent_id': parentId,
      },
    );
    return res as String;
  }

  /// Resolve an @handle to a user or tribe (users win — migration 0116).
  Future<ResolvedTag?> resolveTag(String handle) async {
    final rows = await _client.rpc(
      'resolve_tag',
      params: {'p_handle': handle},
    ) as List<dynamic>;
    if (rows.isEmpty) return null;
    final r = rows.first as Map<String, dynamic>;
    return ResolvedTag(
      kind: r['kind'] as String,
      id: r['id'] as String,
      slug: r['slug'] as String?,
      display: (r['display'] as String?) ?? '',
    );
  }

  /// @-autocomplete candidates: friends first, then users, then tribes.
  Future<List<TagCandidate>> searchTagCandidates(String prefix) async {
    final rows = await _client.rpc(
      'search_tag_candidates',
      params: {'p_prefix': prefix, 'p_limit': 8},
    ) as List<dynamic>;
    return rows.cast<Map<String, dynamic>>().map((r) => TagCandidate(
          kind: r['kind'] as String,
          id: r['id'] as String,
          handle: r['handle'] as String,
          display: (r['display'] as String?) ?? (r['handle'] as String),
          avatarSeed: r['avatar_seed'] as String?,
          isFriend: (r['is_friend'] as bool?) ?? false,
        )).toList();
  }

  /// Soft-delete a whisper comment — permitted for the comment author or
  /// the whisper owner (migration 0115). Returns true when deleted.
  Future<bool> deleteWhisperComment(String commentId) async {
    final res = await _client.rpc(
      'delete_whisper_comment',
      params: {'p_comment_id': commentId},
    );
    return (res as bool?) ?? false;
  }

  /// Toggle a like on a whisper comment; returns the resulting state.
  Future<bool> toggleWhisperCommentLike(String commentId) async {
    final res = await _client.rpc(
      'toggle_whisper_comment_like',
      params: {'p_comment_id': commentId},
    );
    return (res as bool?) ?? false;
  }

  Future<({String path, String url})> uploadWhisperAudio({
    required List<int> bytes,
    required String extension,
    String contentType = 'audio/mp4',
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final safeExt = extension
        .replaceAll('.', '')
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]'), '');
    final path = '$uid/${const Uuid().v4()}.${safeExt.isEmpty ? 'm4a' : safeExt}';
    await _client.storage.from('whispers-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    final url = _client.storage.from('whispers-media').getPublicUrl(path);
    return (path: path, url: url);
  }

  // ===================================================================
  // PLUGZ V2 MODERATION — migration 0045
  // ===================================================================

  Future<List<TribeKeywordFilter>> tribeKeywordFilters(String tribeId) async {
    final rows = await _client
        .from('tribe_keyword_filters')
        .select()
        .eq('tribe_id', tribeId)
        .order('created_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>().map((r) {
      return TribeKeywordFilter(
        filterId: r['filter_id'] as String,
        tribeId:  r['tribe_id']  as String,
        keyword:  r['keyword']   as String,
        severity: (r['severity'] as String?) ?? 'soft',
        createdAt: DateTime.parse(r['created_at'] as String),
      );
    }).toList();
  }

  Future<String> addKeywordFilter({
    required String tribeId,
    required String keyword,
    String severity = 'soft',
  }) async {
    final res = await _client.rpc('add_keyword_filter', params: {
      'p_tribe_id': tribeId,
      'p_keyword':  keyword,
      'p_severity': severity,
    });
    return res as String;
  }

  Future<void> removeKeywordFilter(String filterId) async {
    await _client.rpc('remove_keyword_filter', params: {
      'p_filter_id': filterId,
    });
  }

  Future<List<TribeMemberWarning>> tribeMemberWarnings(String tribeId) async {
    final rows = await _client
        .from('tribe_member_warnings')
        .select(
          'warning_id, tribe_id, member_id, reason, severity, created_at, '
          'acknowledged_at, users:member_id(anonymous_pseudonym, avatar_seed)',
        )
        .eq('tribe_id', tribeId)
        .order('created_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>().map((r) {
      final u = r['users'] as Map<String, dynamic>?;
      final ack = r['acknowledged_at'] as String?;
      return TribeMemberWarning(
        warningId: r['warning_id'] as String,
        tribeId:   r['tribe_id']   as String,
        memberId:  r['member_id']  as String,
        memberPseudonym:
            (u?['anonymous_pseudonym'] as String?) ?? 'anonymous',
        memberAvatarSeed:
            (u?['avatar_seed']        as String?) ?? 'default-orb',
        reason:    r['reason']     as String,
        severity:  (r['severity']  as String?) ?? 'warning',
        createdAt: DateTime.parse(r['created_at'] as String),
        acknowledgedAt: ack == null ? null : DateTime.parse(ack),
      );
    }).toList();
  }

  Future<String> warnMember({
    required String tribeId,
    required String memberId,
    required String reason,
    String severity = 'warning',
  }) async {
    final res = await _client.rpc('warn_member', params: {
      'p_tribe_id':  tribeId,
      'p_member_id': memberId,
      'p_reason':    reason,
      'p_severity':  severity,
    });
    return res as String;
  }

  Future<void> setTribeRules({
    required String tribeId,
    required Map<String, dynamic> rules,
  }) async {
    await _client.rpc('set_tribe_rules', params: {
      'p_tribe_id': tribeId,
      'p_rules':    rules,
    });
  }

  Future<int> tribeChatPresence(String tribeId) async {
    final res = await _client.rpc(
      'tribe_chat_presence',
      params: {'p_tribe_id': tribeId},
    );
    return _coerceInt(res) ?? 0;
  }

  Future<void> tribeChatHeartbeat(String tribeId) async {
    await _client.rpc('tribe_chat_heartbeat', params: {'p_tribe_id': tribeId});
  }

  Future<List<TribeOnlineMember>> tribeOnlineMembers(String tribeId) async {
    final res = await _client.rpc(
      'tribe_online_members',
      params: {'p_tribe_id': tribeId},
    );
    if (res == null) return const [];
    if (res is! List) return const [];
    return res
        .map((e) =>
            TribeOnlineMember.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> setTribeAvatar({
    required String tribeId,
    required String avatarUrl,
  }) async {
    await _client.rpc('tribe_set_avatar', params: {
      'p_tribe_id': tribeId,
      'p_avatar_url': avatarUrl,
    });
  }

  Future<({String path, String url})> uploadTribeAvatar({
    required String tribeId,
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
    final path =
        'tribes/$tribeId/${const Uuid().v4()}.${safeExt.isEmpty ? 'jpg' : safeExt}';
    await _client.storage.from('post-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    final url = _client.storage.from('post-media').getPublicUrl(path);
    return (path: path, url: url);
  }

  Future<({String path, String url})> uploadTribeChatAudio({
    required List<int> bytes,
    String extension = 'm4a',
    String contentType = 'audio/mp4',
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final path = '$uid/${const Uuid().v4()}.$extension';
    await _client.storage.from('tribe-chat-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    final url = _client.storage.from('tribe-chat-media').getPublicUrl(path);
    return (path: path, url: url);
  }

  Future<void> setTribeChatSettings({
    required String tribeId,
    required Map<String, dynamic> patch,
  }) async {
    await _client.rpc('tribe_set_chat_settings', params: {
      'p_tribe_id': tribeId,
      'p_settings': patch,
    });
  }

  Future<void> markTribeChatRead(String tribeId) async {
    await _client.rpc('mark_tribe_chat_read', params: {'p_tribe_id': tribeId});
  }

  Future<List<TribeChatInboxSummary>> tribeChatInbox() async {
    final res = await _client.rpc('tribe_chat_inbox');
    if (res == null) return const [];
    final list = res is List
        ? res
        : (res is Map && res['data'] is List)
            ? res['data'] as List
            : const [];
    return list
        .map((e) => TribeChatInboxSummary.fromJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<List<TribeChatMediaItem>> tribeChatMedia(String tribeId,
      {int limit = 60}) async {
    final rows = await _client
        .from('tribe_chat_media')
        .select()
        .eq('tribe_id', tribeId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(TribeChatMediaItem.fromJson)
        .toList();
  }

  Future<void> pinTribeMessage({
    required String tribeId,
    required String messageId,
  }) async {
    await _client.rpc('pin_tribe_message', params: {
      'p_tribe_id': tribeId,
      'p_message_id': messageId,
    });
  }

  Future<void> unpinTribeMessage(String tribeId) async {
    await _client.rpc('unpin_tribe_message', params: {'p_tribe_id': tribeId});
  }

  Future<({bool hugged, int hugsCount})> toggleTribeMessageHug(
      String messageId) async {
    final res = await _client.rpc(
      'toggle_tribe_message_hug',
      params: {'p_message_id': messageId},
    );
    final map = Map<String, dynamic>.from(res as Map);
    return (
      hugged: map['hugged'] == true,
      hugsCount: _coerceInt(map['hugs_count']) ?? 0,
    );
  }

  Future<void> updatePrompt({
    required String tribeId,
    required String promptId,
    required String text,
    DateTime? scheduledFor,
  }) async {
    await _client.rpc('tribe_update_prompt', params: {
      'p_tribe_id': tribeId,
      'p_prompt_id': promptId,
      'p_prompt_text': text,
      if (scheduledFor != null)
        'p_scheduled_for': scheduledFor.toUtc().toIso8601String(),
    });
  }

  Future<void> deletePrompt(String tribeId, String promptId) async {
    await _client.rpc('tribe_delete_prompt', params: {
      'p_tribe_id': tribeId,
      'p_prompt_id': promptId,
    });
  }

  void broadcastTribeTyping(String tribeId, {required String pseudonym}) {
    final uid = _uid;
    if (uid == null) return;
    _typingChannel('tribe:$tribeId').sendBroadcastMessage(
      event: 'typing',
      payload: {
        'user_id': uid,
        'pseudonym': pseudonym,
        'at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  Stream<List<TribeTypingUser>> watchTribeTyping(String tribeId) {
    final controller = StreamController<List<TribeTypingUser>>();
    final active = <String, ({String pseudonym, Timer timer})>{};
    void emit() {
      if (controller.isClosed) return;
      controller.add([
        for (final e in active.entries)
          TribeTypingUser(userId: e.key, pseudonym: e.value.pseudonym),
      ]);
    }

    final channel = _client
        .channel('typing:tribe=$tribeId:listen')
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            final from = payload['user_id'] as String?;
            if (from == null || from == _uid) return;
            final pseudonym =
                (payload['pseudonym'] as String?) ?? 'someone';
            active[from]?.timer.cancel();
            active[from] = (
              pseudonym: pseudonym,
              timer: Timer(const Duration(seconds: 3), () {
                active.remove(from);
                emit();
              }),
            );
            emit();
          },
        )
        .subscribe();

    controller.onListen = () => controller.add(const []);
    controller.onCancel = () {
      for (final e in active.values) {
        e.timer.cancel();
      }
      active.clear();
      channel.unsubscribe();
    };
    return controller.stream;
  }

  Future<List<FriendSuggestion>> friendSuggestions({int limit = 6}) async {
    final rows = await _client.rpc(
      'friend_suggestions',
      params: {'p_limit': limit},
    ) as List<dynamic>;
    return rows.map((r) {
      final m = (r as Map).cast<String, dynamic>();
      return FriendSuggestion(
        userId:           m['user_id']           as String,
        pseudonym:        m['pseudonym']         as String,
        avatarSeed:       (m['avatar_seed']      as String?) ?? 'default-orb',
        profilePhotoUrl:  m['profile_photo_url'] as String?,
        isVerified:       (m['is_verified']      as bool?)   ?? false,
        sharedTribes:     (m['shared_tribes']    as int?)    ?? 0,
        rationale:        (m['rationale']        as String?) ?? '',
      );
    }).toList();
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

  /// Apply for the verified check (migration 0109). Throws if already verified
  /// or a request is already pending.
  Future<String> requestVerification({String? note}) async {
    final res = await _client.rpc('request_verification', params: {'p_note': note});
    return res as String;
  }

  /// Caller's verification standing: 'verified' | 'pending' | 'denied' | 'none'.
  Future<String> myVerificationStatus() async {
    try {
      final res = await _client.rpc('my_verification_status');
      return (res as String?) ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  /// 🫂 'hug' reactions received across the user's posts (migration 0107).
  /// Used by the own-profile stats banner.
  Future<int> hugsReceivedFor(String userId) async {
    try {
      final rows = await _client.rpc(
        'user_profile_extra_stats',
        params: {'p_target': userId},
      ) as List<dynamic>;
      if (rows.isEmpty) return 0;
      return ((rows.first as Map)['hugs_received'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<UserProfileView?> userProfile(String otherUserId) async {
    final result = await _client.rpc(
      'user_profile_summary',
      params: {'p_target': otherUserId},
    );
    // A null payload means the RPC gated us out (blocked / missing / signed
    // out). Log the target so an "opens blank" report is diagnosable — the UI
    // still shows the friendly "isn't available" card, never a blank frame.
    if (result == null) {
      log.warn('profile.summary_null', props: {'target': otherUserId});
      return null;
    }
    late final UserProfileView view;
    try {
      view = _profileFromJson(result as Map<String, dynamic>);
    } catch (e, st) {
      // A malformed / partial payload must surface as the visible error state,
      // not throw past `async.when` into an empty frame.
      log.error('profile.summary_parse_failed',
          props: {'target': otherUserId}, error: e, stack: st);
      rethrow;
    }
    // Connections count lives on the denormalized users.connections_count
    // column (migration 0054). Cheap indexed single-row read, kept out
    // of user_profile_summary so we don't have to rebuild that long RPC.
    int connections = 0;
    String? bio;
    String? pronouns;
    try {
      final row = await _client
          .from('users')
          .select('connections_count, bio, pronouns, deactivated_at')
          .eq('user_id', otherUserId)
          .maybeSingle();
      // A deactivated (or pending-deletion) account is hidden from everyone
      // else until it is reactivated on next login — treat it as unavailable.
      if (row?['deactivated_at'] != null) return null;
      connections = (row?['connections_count'] as int?) ?? 0;
      bio = row?['bio'] as String?;
      pronouns = row?['pronouns'] as String?;
    } catch (_) {
      // RLS or transient — leave at defaults rather than failing the open.
    }
    // Banner stats: total posts (vents + whispers) + total hugs received.
    int postsTotal = 0;
    int hugsReceived = 0;
    try {
      final rows = await _client.rpc(
        'user_profile_extra_stats',
        params: {'p_target': otherUserId},
      ) as List<dynamic>;
      if (rows.isNotEmpty) {
        final r = (rows.first as Map).cast<String, dynamic>();
        postsTotal = (r['posts_total'] as int?) ?? 0;
        hugsReceived = (r['hugs_received'] as int?) ?? 0;
        if (connections == 0) {
          connections = (r['connections'] as int?) ?? 0;
        }
      }
    } catch (_) {/* migration 0107 pending — leave at 0 */}
    return view.copyWithConnections(
      connections,
      bio: bio,
      pronouns: pronouns,
      postsTotal: postsTotal,
      hugsReceived: hugsReceived,
    );
  }

  // --- Account lifecycle ---------------------------------------------------

  /// Reversible: the account instantly disappears from the app. Signs the
  /// user out; logging back in reactivates it.
  Future<void> deactivateMyAccount() async {
    await _client.rpc('deactivate_my_account');
  }

  /// Starts the 30-day deletion clock and deactivates immediately. Logging
  /// back in within the window cancels the deletion.
  Future<void> requestAccountDeletion() async {
    await _client.rpc('request_account_deletion');
  }

  /// Called on every successful session restore — restores a deactivated
  /// account and cancels any pending deletion still inside its grace window.
  Future<void> reactivateMyAccount() async {
    try {
      await _client.rpc('reactivate_my_account');
    } catch (_) {
      // Best-effort: a failure here must never block sign-in.
    }
  }

  /// Public tribes a user belongs to (private tribes only shown to fellow
  /// members). Powers the Tribes section on a public profile.
  Future<List<Tribe>> userPublicTribes(String userId) async {
    final rows = await _client
        .rpc('user_public_tribes', params: {'p_target': userId}) as List;
    return rows
        .map<Tribe>((r) => _tribeFromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
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
      profilePhotoUrl: user['profile_photo_url'] as String?,
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

  /// Flag a single tribe (chat hub) message for moderator review. (0081)
  Future<void> reportTribeMessage({
    required String messageId,
    required String reason,
    String? note,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    try {
      await _client.from('reports').insert({
        'target_tribe_message_id': messageId,
        'reporter_id':             uid,
        'reason':                  reason,
        'note':                    note,
      });
    } on PostgrestException catch (e) {
      // 23505 = already reported this message — silent no-op.
      if (e.code != '23505') rethrow;
    }
  }

  /// Flag a single DM message for moderator review. (0081)
  Future<void> reportChatMessage({
    required String messageId,
    required String reason,
    String? note,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    try {
      await _client.from('reports').insert({
        'target_chat_message_id': messageId,
        'reporter_id':            uid,
        'reason':                 reason,
        'note':                   note,
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
          'users!inner(user_id, anonymous_pseudonym, avatar_seed, profile_photo_url)',
        )
        .eq('tribe_id', tribeId)
        .order('joined_at', ascending: true);
    return rows.map<TribeMemberRow>((r) {
      final u = r['users'] as Map<String, dynamic>;
      return TribeMemberRow(
        userId: u['user_id'] as String,
        pseudonym: u['anonymous_pseudonym'] as String,
        avatarSeed: (u['avatar_seed'] as String?) ?? 'default-orb',
        profilePhotoUrl: u['profile_photo_url'] as String?,
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

  /// Rule enforcement (migration 0071): removes the member AND blocks
  /// rejoining. The member gets a moderation notification with the reason.
  Future<void> banMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) async {
    await _client.rpc('ban_tribe_member', params: {
      'p_tribe_id': tribeId,
      'p_user_id': userId,
      'p_reason': reason,
    });
  }

  Future<void> unbanMember({
    required String tribeId,
    required String userId,
  }) async {
    await _client.rpc('unban_tribe_member', params: {
      'p_tribe_id': tribeId,
      'p_user_id': userId,
    });
  }

  /// Keeper-only ban list with pseudonyms for the enforcement panel.
  Future<List<Map<String, dynamic>>> tribeBans(String tribeId) async {
    final rows = await _client
        .from('tribe_bans')
        .select('user_id, reason, created_at, users:user_id(anonymous_pseudonym, avatar_seed)')
        .eq('tribe_id', tribeId)
        .order('created_at', ascending: false);
    return rows
        .map<Map<String, dynamic>>((r) => {
              'userId': r['user_id'],
              'reason': r['reason'],
              'createdAt': r['created_at'],
              'pseudonym':
                  (r['users'] as Map<String, dynamic>?)?['anonymous_pseudonym'] ??
                      'member',
              'avatarSeed':
                  (r['users'] as Map<String, dynamic>?)?['avatar_seed'] ??
                      'default-orb',
            })
        .toList();
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
      memberCount: _coerceInt(r['member_count']) ?? 0,
      members7d: _coerceInt(r['members_7d']) ?? 0,
      members30d: _coerceInt(r['members_30d']) ?? 0,
      posts24h: _coerceInt(r['posts_24h']) ?? 0,
      posts7d: _coerceInt(r['posts_7d']) ?? 0,
      comments7d: _coerceInt(r['comments_7d']) ?? 0,
      activePosters7d: _coerceInt(r['active_posters_7d']) ?? 0,
      pinnedCount: _coerceInt(r['pinned_count']) ?? 0,
      scheduledPrompts: _coerceInt(r['scheduled_prompts']) ?? 0,
      openReports: _coerceInt(r['open_reports']) ?? 0,
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
    return postsByAuthor(uid);
  }

  Future<List<Post>> postsByAuthor(
    String authorId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final rows = await _client
        .from('feed_posts')
        .select()
        .eq('author_id', authorId)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    return rows
        .map<Post>(_postFromRow)
        .where((p) => !p.isWhisper || p.createdAt.isAfter(cutoff))
        .toList();
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
          .select(
              'user_id, anonymous_pseudonym, avatar_seed, profile_photo_url, is_verified')
          .inFilter('user_id', authorIds);
      for (final r in list) {
        authors[r['user_id'] as String] = r;
      }
    }

    // Build flat list, then assemble into a nested tree.
    final flat = rows.map((r) {
      final author = authors[r['author_id']];
      final rawEdited  = r['edited_at']  as String?;
      final rawDeleted = r['deleted_at'] as String?;
      final rawPinned  = r['pinned_at']  as String?;
      return ThreadedComment(
        commentId: r['comment_id'] as String,
        parentId: r['parent_id'] as String?,
        authorId: r['author_id'] as String?,
        authorPseudonym: author == null
            ? '@anonymous'
            : '@${author['anonymous_pseudonym']}',
        authorAvatarSeed:
            author == null ? 'default-orb' : author['avatar_seed'] as String,
        authorProfilePhotoUrl: author?['profile_photo_url'] as String?,
        authorIsVerified: (author?['is_verified'] as bool?) ?? false,
        content: r['content'] as String,
        imageUrl: r['image_url'] as String?,
        path: r['path'] as String,
        depth: r['depth'] as int,
        likesCount: r['likes_count'] as int,
        likedByMe: (r['liked_by_me'] as bool?) ?? false,
        createdAt: DateTime.parse(r['created_at'] as String),
        editedAt:  rawEdited  == null ? null : DateTime.parse(rawEdited),
        deletedAt: rawDeleted == null ? null : DateTime.parse(rawDeleted),
        pinnedAt:  rawPinned  == null ? null : DateTime.parse(rawPinned),
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
    String? imageUrl,
    String? imagePath,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final id = await _client.rpc('create_threaded_comment', params: {
      'p_post_id':    postId,
      'p_parent_id':  parentId,
      'p_author_id':  uid,
      'p_content':    content,
      'p_persona_id': personaId,
      'p_image_url':  imageUrl,
      'p_image_path': imagePath,
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
          authorIsVerified: me?.isVerified ?? false,
          content: content,
          imageUrl: imageUrl,
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

  Future<List<Tribe>> tribesByKeeper(String keeperId) async {
    final rows = await _client
        .from('tribe_directory')
        .select()
        .eq('keeper_id', keeperId)
        .order('member_count', ascending: false);
    return rows.map<Tribe>(_tribeFromRow).toList();
  }

  Future<List<Post>> postsByKeeper(
    String keeperId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final tribeRows = await _client
        .from('tribes')
        .select('tribe_id')
        .eq('keeper_id', keeperId);
    final tribeIds = tribeRows
        .map<String>((r) => r['tribe_id'] as String)
        .toList();
    if (tribeIds.isEmpty) return const [];
    final rows = await _client
        .from('feed_posts')
        .select()
        .inFilter('tribe_id', tribeIds)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    return rows
        .map<Post>(_postFromRow)
        .where((p) => !p.isWhisper || p.createdAt.isAfter(cutoff))
        .toList();
  }

  // ===================================================================
  // SPACES (Tribe → Space → Vent — migration 0050)
  // ===================================================================

  Space _spaceFromRow(Map<String, dynamic> r) {
    final archivedAtRaw = r['archived_at'] as String?;
    final lastVentRaw   = r['last_vent_at'] as String?;
    return Space(
      spaceId:     r['space_id']    as String,
      tribeId:     r['tribe_id']    as String,
      tribeSlug:   r['tribe_slug']  as String,
      tribeName:   r['tribe_name']  as String,
      slug:        r['slug']        as String,
      name:        r['name']        as String,
      description: r['description'] as String?,
      weeklyTheme: r['weekly_theme'] as String?,
      themeColor:  r['theme_color'] as String?,
      isDefault:   (r['is_default'] as bool?) ?? false,
      archivedAt:
          archivedAtRaw == null ? null : DateTime.parse(archivedAtRaw),
      createdAt: DateTime.parse(r['created_at'] as String),
      updatedAt: DateTime.parse(r['updated_at'] as String),
      ventCount:  (r['vent_count']  as int?) ?? 0,
      ventsToday: (r['vents_today'] as int?) ?? 0,
      lastVentAt:
          lastVentRaw == null ? null : DateTime.parse(lastVentRaw),
    );
  }

  /// All Spaces inside a tribe (active first, then archived).
  Future<List<Space>> spacesByTribe(String tribeId) async {
    final rows = await _client
        .from('space_directory')
        .select()
        .eq('tribe_id', tribeId)
        .order('archived_at', ascending: true, nullsFirst: true)
        .order('is_default', ascending: false)
        .order('created_at', ascending: true);
    return rows.map<Space>(_spaceFromRow).toList();
  }

  Future<Space?> spaceById(String spaceId) async {
    final row = await _client
        .from('space_directory')
        .select()
        .eq('space_id', spaceId)
        .maybeSingle();
    return row == null ? null : _spaceFromRow(row);
  }

  /// Vents posted inside a specific Space, with optional smart sort.
  Future<List<Post>> postsInSpace({
    required String spaceId,
    String sort = 'fresh', // fresh | trending | helpful | unanswered
    int limit = 60,
  }) async {
    // Keep the filter chain narrow so it stays a FilterBuilder; only
    // transition to a transform via `.order(...)` at the very end.
    var filter = _client
        .from('feed_posts')
        .select()
        .eq('space_id', spaceId);
    if (sort == 'unanswered') {
      filter = filter.eq('comments_count', 0);
    } else if (sort == 'keeper') {
      filter = filter.eq('is_keeper_pick', true);
    }
    final dynamic ordered;
    switch (sort) {
      case 'trending':
        ordered = filter
            .order('likes_count', ascending: false)
            .order('created_at', ascending: false);
        break;
      case 'helpful':
        ordered = filter
            .order('comments_count', ascending: false)
            .order('created_at', ascending: false);
        break;
      case 'keeper':
        ordered = filter
            .order('keeper_pick_at', ascending: false)
            .order('created_at', ascending: false);
        break;
      case 'unanswered':
      case 'fresh':
      default:
        ordered = filter.order('created_at', ascending: false);
        break;
    }
    final rows = await ordered.limit(limit) as List<dynamic>;
    return rows
        .map<Post>((r) => _postFromRow(r as Map<String, dynamic>))
        .toList();
  }

  Future<String> createSpace({
    required String tribeId,
    required String name,
    String? description,
  }) async {
    final res = await _client.rpc('create_space', params: {
      'p_tribe_id': tribeId,
      'p_name': name,
      if (description != null) 'p_description': description,
    });
    return res as String;
  }

  Future<bool> renameSpace({
    required String spaceId,
    required String name,
  }) async {
    final res = await _client.rpc('rename_space', params: {
      'p_space_id': spaceId,
      'p_name': name,
    });
    return res == true;
  }

  Future<bool> archiveSpace(String spaceId) async {
    final res = await _client.rpc('archive_space', params: {
      'p_space_id': spaceId,
    });
    return res == true;
  }

  /// Latest AI summary for a Space, or null if none has been
  /// generated yet. Reads from the denormalized `latest_space_summary`
  /// view — single round trip, indexed by space_id.
  Future<SpaceSummary?> latestSpaceSummary(String spaceId) async {
    final row = await _client
        .from('latest_space_summary')
        .select()
        .eq('space_id', spaceId)
        .maybeSingle();
    if (row == null) return null;
    final topics = (row['top_topics'] as List<dynamic>?) ?? const [];
    return SpaceSummary(
      summaryId: row['summary_id'] as String,
      spaceId: row['space_id'] as String,
      forDate: DateTime.parse(row['for_date'] as String),
      summary: (row['summary'] as String?) ?? '',
      topTopics: topics.map((e) => e.toString()).toList(),
      suggestedPrompt: (row['suggested_prompt'] as String?) ?? '',
      ventsAnalyzed: (row['vents_analyzed'] as int?) ?? 0,
      model: row['model'] as String?,
      generatedAt: row['generated_at'] == null
          ? null
          : DateTime.parse(row['generated_at'] as String),
    );
  }

  Future<bool> updateSpaceTheme({
    required String spaceId,
    String? weeklyTheme,
    String? themeColor,
    String? description,
  }) async {
    final res = await _client.rpc('update_space_theme', params: {
      'p_space_id': spaceId,
      if (weeklyTheme != null) 'p_weekly_theme': weeklyTheme,
      if (themeColor != null) 'p_theme_color': themeColor,
      if (description != null) 'p_description': description,
    });
    return res == true;
  }

  Future<List<Tribe>> tribesIKeep() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('tribe_directory')
        .select()
        .eq('keeper_id', uid)
        .order('member_count', ascending: false);
    return rows.map<Tribe>(_tribeFromRow).toList();
  }

  // ──────────────────── Keeper Studio V2 (0062) ────────────────────

  Future<KeeperMode> keeperMode() async {
    if (_uid == null) return KeeperMode.guest();
    final res = await _client.rpc('is_keeper_mode');
    final map = res is Map<String, dynamic>
        ? res
        : Map<String, dynamic>.from(res as Map);
    return KeeperMode(
      isKeeper: map['is_keeper'] == true,
      displayRole: _coerceString(map['display_role']) ?? 'member',
      userRole: _coerceString(map['user_role']),
      tribesKept: _coerceInt(map['tribes_kept']) ?? 0,
    );
  }

  Future<KeeperModerationQueue> keeperModerationQueue(
    String tribeId, {
    int limit = 30,
    int offset = 0,
  }) async {
    final res = await _client.rpc('keeper_moderation_queue', params: {
      'p_tribe_id': tribeId,
      'p_limit': limit,
      'p_offset': offset,
    });
    final map = res is Map<String, dynamic>
        ? res
        : Map<String, dynamic>.from(res as Map);
    return KeeperModerationQueue.fromJson(map);
  }

  Future<KeeperEngagementCalendar> keeperEngagementCalendar(
      String tribeId) async {
    final res =
        await _client.rpc('keeper_engagement_calendar', params: {
      'p_tribe_id': tribeId,
    });
    final map = res is Map<String, dynamic>
        ? res
        : Map<String, dynamic>.from(res as Map);
    return KeeperEngagementCalendar.fromJson(map);
  }

  Future<KeeperAiInsights> keeperAiInsights(String tribeId) async {
    final res = await _client.rpc('keeper_ai_insights', params: {
      'p_tribe_id': tribeId,
    });
    final map = res is Map<String, dynamic>
        ? res
        : Map<String, dynamic>.from(res as Map);
    return KeeperAiInsights.fromJson(map);
  }

  Future<KeeperComodMatrix> keeperComodMatrix(String tribeId) async {
    final res = await _client.rpc('keeper_comod_matrix', params: {
      'p_tribe_id': tribeId,
    });
    final map = res is Map<String, dynamic>
        ? res
        : Map<String, dynamic>.from(res as Map);
    return KeeperComodMatrix.fromJson(map);
  }

  Future<KeeperExportReport> keeperExportReport(
    String tribeId, {
    String format = 'markdown',
  }) async {
    final res = await _client.rpc('keeper_export_report', params: {
      'p_tribe_id': tribeId,
      'p_format': format,
    });
    final map = res is Map<String, dynamic>
        ? res
        : Map<String, dynamic>.from(res as Map);
    return KeeperExportReport.fromJson(map);
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
        .order('sort_activity_at', ascending: false);
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
              peerUserId: r['peer_id'] as String?,
              requestPreview: (r['request_preview'] as String?) ?? '',
              roomStatus: r['room_status'] as String,
              createdAt: DateTime.parse(r['created_at'] as String),
              initiatedByMe: r['initiated_by_me'] as bool,
              unreadCount: (r['unread_count'] as int?) ?? 0,
              lastMessagePreview: r['last_message_preview'] as String?,
              lastMessageAt: r['last_message_at'] == null
                  ? null
                  : DateTime.parse(r['last_message_at'] as String),
              lastOwnMessageRead:
                  (r['last_own_message_read'] as bool?) ?? false,
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

    // Delete-for-me: drop any messages the caller has hidden from their own
    // view. RLS on chat_message_hides scopes rows to the caller, so a bare
    // select returns only my hides. Filtering here (rather than server-side)
    // also covers the realtime path, which re-runs this method.
    final allIds = base.map((m) => m.messageId).toList();
    final hideRows = await _client
        .from('chat_message_hides')
        .select('message_id')
        .inFilter('message_id', allIds);
    final hidden = <String>{
      for (final h in hideRows as List)
        (h as Map<String, dynamic>)['message_id'] as String,
    };
    final visible = hidden.isEmpty
        ? base
        : base.where((m) => !hidden.contains(m.messageId)).toList();
    if (visible.isEmpty) return visible;

    // Reaction summary in a second small round-trip. View is keyed by
    // message_id so we filter for just this room's ids.
    final ids = visible.map((m) => m.messageId).toList();
    final summary = await _client
        .from('chat_message_reactions_summary')
        .select()
        .inFilter('message_id', ids);
    final byId = <String, Map<String, dynamic>>{
      for (final r in summary as List)
        (r as Map<String, dynamic>)['message_id'] as String: r,
    };

    // Build a quick lookup of in-room messages so parent previews can
    // be folded onto replies without an extra round-trip.
    final byMessageId = {for (final m in visible) m.messageId: m};

    // Peer pseudonym for parent-sender labels. Cached at room level
    // since DMs only have two participants.
    String? peerPseudonym;
    String? mePseudonym = _me?.anonymousPseudonym;
    try {
      final room = await _client
          .from('inbox_rooms')
          .select('peer_pseudonym')
          .eq('room_id', roomId)
          .maybeSingle();
      peerPseudonym = room?['peer_pseudonym'] as String?;
    } catch (_) {/* best-effort */}

    return [
      for (final m in visible)
        () {
          var out = m;
          final row = byId[m.messageId];
          if (row != null) {
            final counts =
                (row['reaction_counts'] as Map?)?.cast<String, dynamic>() ?? {};
            out = out.copyWith(
              reactionCounts: {
                for (final e in counts.entries)
                  e.key: (e.value as num).toInt(),
              },
              myReaction: row['my_reaction'] as String?,
            );
          }
          final parentId = m.parentMessageId;
          if (parentId != null) {
            final parent = byMessageId[parentId];
            if (parent != null) {
              final preview = parent.isDeleted
                  ? 'Original message was deleted'
                  : (parent.plaintext.length > 120
                      ? '${parent.plaintext.substring(0, 117)}…'
                      : parent.plaintext);
              out = out.copyWith(
                parentPreview: preview,
                parentSenderPseudonym: parent.sentByMe
                    ? (mePseudonym ?? 'you')
                    : (peerPseudonym ?? 'them'),
              );
            }
          }
          return out;
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
    final rawDelivered = r['delivered_at'] as String?;
    final rawEdited = r['edited_at'] as String?;
    final rawDeleted = r['deleted_at'] as String?;
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
      deliveredAt:
          rawDelivered == null ? null : DateTime.parse(rawDelivered),
      attachedMediaPath: r['attached_media_path'] as String?,
      attachedMediaType: r['attached_media_type'] as String?,
      parentMessageId: r['parent_message_id'] as String?,
      editedAt: rawEdited == null ? null : DateTime.parse(rawEdited),
      deletedAt: rawDeleted == null ? null : DateTime.parse(rawDeleted),
    );
  }

  /// Register the device's FCM / APNs token against the signed-in user
  /// so the Edge Function fan-out can target it on new messages. Safe
  /// to call repeatedly — RPC upserts on (user_id, token).
  Future<void> registerPushToken({
    required String token,
    required String platform, // 'android' | 'ios' | 'web'
    String? locale,
    String? appVersion,
  }) async {
    await _client.rpc('register_push_token', params: {
      'p_token':       token,
      'p_platform':    platform,
      'p_locale':      locale,
      'p_app_version': appVersion,
    });
  }

  Future<void> unregisterPushToken(String token) async {
    await _client.rpc('unregister_push_token', params: {
      'p_token': token,
    });
  }

  /// Chat V2 — author edits their own message in-place. RPC enforces
  /// the 30-minute edit window + ownership.
  Future<bool> editChatMessage({
    required String messageId,
    required String newPlaintext,
  }) async {
    final res = await _client.rpc('edit_chat_message', params: {
      'p_message_id': messageId,
      'p_plaintext':  newPlaintext,
    });
    return (res as bool?) ?? false;
  }

  /// Delete for everyone — author-only tombstone, capped at 24h by the RPC.
  Future<bool> deleteChatMessage(String messageId) async {
    final res = await _client.rpc('delete_chat_message', params: {
      'p_message_id': messageId,
    });
    return (res as bool?) ?? false;
  }

  /// Delete for me — hide a message from the caller's own view only. Works
  /// on any message (yours or the peer's), at any age.
  Future<bool> hideChatMessage(String messageId) async {
    final res = await _client.rpc('hide_chat_message', params: {
      'p_message_id': messageId,
    });
    return (res as bool?) ?? false;
  }

  // ===================================================================
  // AUTHOR CRUD (migration 0047) — vents / comments / whispers /
  // tribe-chat messages all expose the same edit + delete shape,
  // bounded by the per-surface windows enforced in the RPC.
  // ===================================================================

  Future<bool> editPost({
    required String postId,
    required String newContent,
  }) async {
    final res = await _client.rpc('edit_post', params: {
      'p_post_id': postId,
      'p_content': newContent,
    });
    return (res as bool?) ?? false;
  }

  Future<bool> deletePost(String postId) async {
    final res = await _client.rpc('delete_post', params: {'p_post_id': postId});
    return (res as bool?) ?? false;
  }

  Future<bool> editComment({
    required String commentId,
    required String newContent,
  }) async {
    final res = await _client.rpc('edit_comment', params: {
      'p_comment_id': commentId,
      'p_content':    newContent,
    });
    return (res as bool?) ?? false;
  }

  Future<bool> deleteComment(String commentId) async {
    final res = await _client.rpc('delete_comment',
        params: {'p_comment_id': commentId});
    return (res as bool?) ?? false;
  }

  // Phase 2 — comment moderation (migration 0051).
  Future<bool> pinComment(String commentId) async {
    final res = await _client
        .rpc('pin_comment', params: {'p_comment_id': commentId});
    return (res as bool?) ?? false;
  }

  Future<bool> unpinComment(String commentId) async {
    final res = await _client
        .rpc('unpin_comment', params: {'p_comment_id': commentId});
    return (res as bool?) ?? false;
  }

  Future<bool> setPostCommentsLock({
    required String postId,
    required bool locked,
  }) async {
    final res = await _client.rpc('set_post_comments_lock', params: {
      'p_post_id': postId,
      'p_locked': locked,
    });
    return (res as bool?) ?? false;
  }

  Future<bool> toggleKeeperPick(String postId) async {
    final res = await _client
        .rpc('toggle_keeper_pick', params: {'p_post_id': postId});
    return (res as bool?) ?? false;
  }

  Future<bool> editWhisper({
    required String whisperId,
    String? title,
    String? description,
  }) async {
    final res = await _client.rpc('edit_whisper', params: {
      'p_whisper_id':  whisperId,
      'p_title':       title,
      'p_description': description,
    });
    return (res as bool?) ?? false;
  }

  Future<bool> deleteWhisper(String whisperId) async {
    final res = await _client.rpc('delete_whisper',
        params: {'p_whisper_id': whisperId});
    return (res as bool?) ?? false;
  }

  Future<bool> editTribeMessage({
    required String messageId,
    required String newContent,
  }) async {
    final res = await _client.rpc('edit_tribe_message', params: {
      'p_message_id': messageId,
      'p_content':    newContent,
    });
    return (res as bool?) ?? false;
  }

  Future<bool> deleteTribeMessage(String messageId) async {
    final res = await _client.rpc('delete_tribe_message',
        params: {'p_message_id': messageId});
    return (res as bool?) ?? false;
  }

  /// Delete for me — hide a tribe message from the caller's own view only.
  Future<bool> hideTribeMessage(String messageId) async {
    final res = await _client.rpc('hide_tribe_message',
        params: {'p_message_id': messageId});
    return (res as bool?) ?? false;
  }

  /// Stamp read_at on every message in [roomId] not sent by the caller.
  /// Returns the count of newly-marked messages. Safe to call on every
  /// chat-screen open + every new-message arrival — idempotent.
  Future<int> markRoomRead(String roomId) async {
    final res =
        await _client.rpc('mark_chat_room_read', params: {'p_room_id': roomId});
    return (res as int?) ?? 0;
  }

  /// Tick stream that fires on any friendships change visible to the
  /// caller (RLS scopes events to rows where auth.uid() participates).
  /// Drives live friend-request badges + accept flows.
  Stream<int> watchFriendshipEvents() {
    final controller = StreamController<int>();
    var tick = 0;
    final channel = _client
        .channel('friendships:events')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'friendships',
          callback: (_) => controller.add(++tick),
        )
        .subscribe();
    controller.onListen = () => controller.add(0);
    controller.onCancel = () => channel.unsubscribe();
    return controller.stream;
  }

  /// Stamp delivered_at on peer messages in [roomId] — called when the
  /// client actually receives them (chat open / realtime arrival).
  Future<int> markRoomDelivered(String roomId) async {
    final res = await _client
        .rpc('mark_room_delivered', params: {'p_room_id': roomId});
    return (res as int?) ?? 0;
  }

  /// Presence heartbeat — call on resume + every ~60s while foregrounded.
  Future<void> touchLastSeen() async {
    await _client.rpc('touch_last_seen');
  }

  /// Peer presence tier: online | recent | offline | hidden (+ last_seen).
  Future<({String state, DateTime? lastSeen})> peerPresence(
      String userId) async {
    final rows = await _client
        .rpc('peer_presence', params: {'p_user_id': userId}) as List<dynamic>;
    if (rows.isEmpty) return (state: 'hidden', lastSeen: null);
    final r = rows.first as Map<String, dynamic>;
    final raw = r['last_seen'] as String?;
    return (
      state: (r['state'] as String?) ?? 'hidden',
      lastSeen: raw == null ? null : DateTime.parse(raw),
    );
  }

  /// Unread peer messages across all active DM rooms — powers the Inbox badge.
  Future<int> unreadChatMessageCount() async {
    if (_uid == null) return 0;
    final res = await _client.rpc('unread_chat_message_count');
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
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_message_reactions',
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

  /// Upload a DM voice note into the private `chat-media` bucket. Mirrors
  /// [uploadChatImage]; the duration is encoded into the object name
  /// (`voice-<id>-d<seconds>s.m4a`) so playback UIs can show it without a
  /// chat_messages schema change. (Bucket audio mimes: migration 0097.)
  Future<({String path, String messageId})> uploadChatAudio({
    required String roomId,
    required List<int> bytes,
    required int durationSeconds,
  }) async {
    final messageId = const Uuid().v4();
    final path = '$roomId/voice-$messageId-d${durationSeconds}s.m4a';
    await _client.storage.from('chat-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(
            contentType: 'audio/mp4',
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
  /// When [parentMessageId] is set, routes through the v2 RPC which
  /// validates the quoted message belongs to the same room.
  Future<ChatMessage> sendMessage({
    required String roomId,
    required String payload,
    String? attachedPostId,
    String? attachedMediaPath,
    String? attachedMediaType,
    String? parentMessageId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');

    if (parentMessageId != null) {
      // V2 path — RPC returns just the new message_id, so we re-read
      // the messages() list to surface the persisted row with snapshot
      // joins. Lightweight: one extra round-trip on reply-send only.
      await _client.rpc('send_chat_message_v2', params: {
        'p_room_id':           roomId,
        'p_plaintext':         payload,
        'p_attached_post_id':  attachedPostId,
        'p_media_path':        attachedMediaPath,
        'p_media_type':        attachedMediaType,
        'p_parent_message_id': parentMessageId,
      });
      final list = await messages(roomId);
      // Find the freshest message from me referencing the same parent.
      for (var i = list.length - 1; i >= 0; i--) {
        final m = list[i];
        if (m.sentByMe && m.parentMessageId == parentMessageId) return m;
      }
      return list.isNotEmpty ? list.last : ChatMessage(
        messageId: 'unknown',
        roomId: roomId,
        senderId: uid,
        plaintext: payload,
        createdAt: DateTime.now(),
        sentByMe: true,
      );
    }

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
    // is_active still gates manual disable. Member questions (migration
    // 0069) join users via author_id instead of plug_profiles.
    final rows = await _client
        .from('plug_prompts')
        .select(
            'prompt_id, prompt_text, answers_count, '
            'plug_profiles(display_name, users(avatar_seed)), '
            'author:users!plug_prompts_author_id_fkey(anonymous_pseudonym, avatar_seed)')
        .eq('is_active', true)
        .not('published_at', 'is', null)
        .lte('published_at', DateTime.now().toUtc().toIso8601String());
    return rows.map<PlugPrompt>((r) {
      final pp = r['plug_profiles'] as Map<String, dynamic>?;
      final users = pp?['users'] as Map<String, dynamic>?;
      final author = r['author'] as Map<String, dynamic>?;
      final displayName = (pp?['display_name'] as String?) ??
          (author?['anonymous_pseudonym'] != null
              ? '@${author!['anonymous_pseudonym']}'
              : '@plug');
      return PlugPrompt(
        promptId: r['prompt_id'] as String,
        plugDisplayName: displayName,
        plugAvatarSeed: (users?['avatar_seed'] as String?) ??
            (author?['avatar_seed'] as String?) ??
            'default-orb',
        promptText: r['prompt_text'] as String,
        answersCount: r['answers_count'] as int,
      );
    }).toList();
  }

  /// Member-authored question (migration 0069). [audience] is 'everyone'
  /// or 'friends' — friends-only questions are RLS-visible exclusively to
  /// the author's accepted connections.
  Future<PlugPrompt> createUserQuestion({
    required String text,
    String audience = 'everyone',
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    final row = await _client
        .from('plug_prompts')
        .insert({
          'author_id': uid,
          'prompt_text': text,
          'audience': audience,
          'is_active': true,
          'published_at': DateTime.now().toUtc().toIso8601String(),
        })
        .select('prompt_id, prompt_text, answers_count')
        .single();
    final me = _me;
    return PlugPrompt(
      promptId: row['prompt_id'] as String,
      plugDisplayName: '@${me?.anonymousPseudonym ?? 'anonymous'}',
      plugAvatarSeed: me?.avatarSeed ?? 'default-orb',
      promptText: row['prompt_text'] as String,
      answersCount: (row['answers_count'] as int?) ?? 0,
    );
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
  /// Realtime stream of the caller's notifications — the bell list + badge
  /// update the instant a row lands (publication: migration 0113).
  Stream<List<NotificationItem>> watchNotifications() {
    final controller = StreamController<List<NotificationItem>>();
    Future<void> emit() async {
      try {
        controller.add(await notifications());
      } catch (_) {/* listener retries on next event */}
    }

    final uid = _uid;
    RealtimeChannel? channel;
    if (uid != null) {
      channel = _client
          .channel('notifications:$uid')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'notifications',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: uid,
            ),
            callback: (_) => emit(),
          )
          .subscribe();
    }

    controller.onListen = emit;
    controller.onCancel = () => channel?.unsubscribe();
    return controller.stream;
  }

  Future<List<NotificationItem>> notifications() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('notifications')
        .select()
        .eq('user_id', uid)
        // Grouped rows bump updated_at on every collapse — float them.
        .order('updated_at', ascending: false)
        .limit(50);
    return rows.map<NotificationItem>((r) {
      final payload =
          (r['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      return NotificationItem(
        id: r['notification_id'] as String,
        kind: r['kind'] as String,
        title: (payload['title'] as String?) ?? _kindLabel(r['kind'] as String),
        body: (payload['body'] as String?) ?? '',
        createdAt: DateTime.parse(
            (r['updated_at'] ?? r['created_at']) as String),
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
    final rawEdited  = r['edited_at']  as String?;
    final rawDeleted = r['deleted_at'] as String?;
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
      viewCount: (r['view_count'] as int?) ?? 0,
      imageUrl: r['image_url'] as String?,
      audioUrl: r['audio_url'] as String?,
      audioDurationSeconds: r['audio_duration_seconds'] as int?,
      createdAt: DateTime.parse(r['created_at'] as String),
      editedAt:  rawEdited  == null ? null : DateTime.parse(rawEdited),
      deletedAt: rawDeleted == null ? null : DateTime.parse(rawDeleted),
      lockedAt: r['locked_at'] == null
          ? null
          : DateTime.parse(r['locked_at'] as String),
      isKeeperPick: (r['is_keeper_pick'] as bool?) ?? false,
      keeperPickAt: r['keeper_pick_at'] == null
          ? null
          : DateTime.parse(r['keeper_pick_at'] as String),
      authorKarma: (r['author_karma'] as int?) ?? 0,
      tribeId: r['tribe_id'] as String?,
      tribeName: r['tribe_name'] as String?,
      tribeSlug: r['tribe_slug'] as String?,
      spaceId: r['space_id'] as String?,
      isWhisper: (r['is_whisper'] as bool?) ?? false,
      myReaction: _myReactions[r['post_id']],
      savedByMe: _savedPosts.contains(r['post_id']),
      crisisLevel: r['crisis_level'] as String?,
      mediaStatus: (r['media_status'] as String?) ?? 'clean',
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
      rules: _coerceJsonTextField(r['rules']),
      isPremium: (r['is_premium'] as bool?) ?? false,
      chatSettings: TribeChatSettings.fromJson(
        r['chat_settings'] is Map
            ? Map<String, dynamic>.from(r['chat_settings'] as Map)
            : null,
      ),
      pinnedMessageId: r['pinned_message_id'] as String?,
    );
  }

  Future<bool> updateTribeManagement({
    required String tribeId,
    String? name,
    String? rules,
    bool? isPremium,
    String? avatarUrl,
    Map<String, dynamic>? settings,
  }) async {
    final res = await _client.rpc('update_tribe_management', params: {
      'p_tribe_id': tribeId,
      if (name != null) 'p_name': name,
      if (rules != null) 'p_rules': rules,
      if (isPremium != null) 'p_is_premium': isPremium,
      if (avatarUrl != null) 'p_avatar_url': avatarUrl,
      if (settings != null) 'p_settings': settings,
    });
    return res == true;
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
      // Present only in the richer profile select; null in the base select.
      bio: r['bio'] as String?,
      pronouns: r['pronouns'] as String?,
      // Present only when the caller selected it (see refreshEmailVerified);
      // absent in the base select, so default to false.
      emailVerified: (r['email_verified'] as bool?) ?? false,
    );
  }

  /// Persist edits to the caller's public profile. NULL args mean "unchanged";
  /// pass the matching `clear*` flag to explicitly wipe bio/pronouns/photo.
  /// Returns the refreshed [AppUser].
  Future<AppUser> updateMyProfile({
    String? pseudonym,
    String? bio,
    String? pronouns,
    String? profilePhotoUrl,
    String? homeCity,
    bool clearPhoto = false,
    bool clearBio = false,
    bool clearPronouns = false,
  }) async {
    await _client.rpc('update_my_profile', params: {
      'p_pseudonym': pseudonym,
      'p_bio': bio,
      'p_pronouns': pronouns,
      'p_profile_photo_url': profilePhotoUrl,
      'p_home_city': homeCity,
      'p_clear_photo': clearPhoto,
      'p_clear_bio': clearBio,
      'p_clear_pronouns': clearPronouns,
    });
    final row = await _client
        .from('users')
        .select(_userSelectWithProfilePhoto)
        .eq('user_id', _uid as Object)
        .single();
    _me = _userFromRow(row);
    return _me!;
  }

  /// Capture that the current user listened to a whisper (dedup per user;
  /// first listen bumps the public plays_count).
  Future<void> recordWhisperListen(String whisperId) async {
    await _client.rpc('record_whisper_listen',
        params: {'p_whisper_id': whisperId});
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

/// Raised after a successful password sign-in when the account has
/// 2FA enrolled but the current session is still AAL1. The signin
/// screen catches this and prompts for the 6-digit TOTP code, then
/// calls [SupabaseBackend.verifyMfa] with the same factorId.
class MfaChallengeRequiredException implements Exception {
  const MfaChallengeRequiredException(this.factorId);
  final String factorId;
  @override
  String toString() => 'MFA required (factor $factorId)';
}

class EmailConfirmationStillOnException implements Exception {
  const EmailConfirmationStillOnException();
  @override
  String toString() =>
      'Supabase Auth still requires email confirmation. Disable '
      '"Confirm email" in Authentication → Providers → Email so the '
      'zero-PII username handles can sign up.';
}

class EmailTakenException implements Exception {
  const EmailTakenException();
  @override
  String toString() =>
      'That email already has an account. Sign in or use a different address.';
}
