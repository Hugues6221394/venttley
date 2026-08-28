import 'dart:async';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../domain/entities/entities.dart';
import '../../domain/keeper/keeper_mode.dart';
import '../../domain/keeper/keeper_studio_v2.dart';
import '../../domain/tribe/tribe_chat_hub.dart';
import '../../domain/tribe/tribe_management.dart';
import 'supabase_backend.dart'
    show UsernameTakenException, InvalidCredentialsException;

/// In-memory backend used when [VentlyConfig.useMockBackend] is true.
///
/// Mirrors a subset of `supabase/seed/seed_demo.sql` so the Flutter app
/// boots with rich content even without a live Supabase project.
class MockBackend {
  MockBackend._() {
    _seed();
  }
  static final MockBackend instance = MockBackend._();

  final _uuid = const Uuid();
  final _rng = Random();

  AppUser? _me;
  final List<AppUser> _users = [];
  final Map<String, String> _passwords = {}; // lowercased username → password
  final Map<String, ({String blob, String salt})> _recovery = {};
  final List<PlugProfile> _plugz = [];
  final List<Tribe> _tribes = [];
  final List<Space> _spaces = [];
  final List<Post> _posts = [];
  final Map<String, List<ThreadedComment>> _commentsByPost = {};
  final Map<String, String> _myReactions = {};
  final Map<String, List<Persona>> _personasByUser = {};
  final Set<String> _savedPosts = {};
  final Set<String> _savedWhispers = {};
  final Map<String, String> _whisperReactions = {};
  final Set<String> _joinedTribes = {};
  final List<ChatRoom> _rooms = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, List<GroupChatMember>> _groupMembers = {};
  final List<PlugPrompt> _prompts = [];
  final List<NotificationItem> _notifications = [];
  final Map<String, int> _musicUsage = {};
  final Map<String, List<TribeRuleItem>> _managementRules = {};
  final List<TribeJoinRequest> _managementJoinRequests = [];
  final List<TribeAuditEvent> _managementAudit = [];

  /// Friend graph. Each tuple is (a, b, status, requestedBy, createdAt,
  /// note) with a < b lexically. Mirrors migration 0024's `friendships`.
  final List<_MockFriendship> _friendships = [];
  final List<_MockBlock> _blocks = [];

  // Stream controllers for live UI updates.
  final _postsController = StreamController<List<Post>>.broadcast();
  final _roomsController = StreamController<List<ChatRoom>>.broadcast();
  final _notificationsController =
      StreamController<List<NotificationItem>>.broadcast();

  Stream<List<Post>> get postsStream => _postsController.stream;
  Stream<List<ChatRoom>> get roomsStream => _roomsController.stream;
  Stream<List<NotificationItem>> get notificationsStream =>
      _notificationsController.stream;

  AppUser? get me => _me;

  static const List<MusicTrack> _authorizedMusicTracks = [
    MusicTrack(
      trackId: 'a7100000-0000-4000-8000-000000000001',
      provider: 'venttly_original',
      providerTrackId: 'afterglow-v1',
      title: 'Afterglow',
      artist: 'Venttly Originals',
      album: 'Quiet Rooms',
      previewUrl: 'asset:///assets/audio/afterglow.wav',
      previewDurationMs: 30000,
      genre: 'ambient',
      moodTags: ['healing', 'late_night', 'peaceful', 'heartbreak'],
      licenseCode: 'VENTTLY_ORIGINAL',
      attributionText: 'Afterglow — Venttly Originals',
      cacheAllowed: true,
    ),
  ];

  void registerSession(AppUser user) {
    _me = user;
    if (!_users.any((u) => u.userId == user.userId)) {
      _users.add(user);
    }
    _emitAll();
  }

  /// Mock counterpart of [SupabaseBackend.signUp].
  AppUser signUp({
    required String username,
    required String password,
    required String avatarSeed,
    required int birthYear,
    required String safetyTier,
    required String recoveryBlob,
    required String recoverySalt,
  }) {
    final key = username.toLowerCase();
    if (_passwords.containsKey(key)) {
      throw UsernameTakenException();
    }
    final user = AppUser(
      userId: _uuid.v4(),
      anonymousPseudonym: username,
      avatarSeed: avatarSeed,
      currentMood: 'healing',
      userRole: 'normal',
      isVerified: false,
      safetyTier: safetyTier,
      accountStatus: 'active',
      birthYear: birthYear,
    );
    _users.add(user);
    _passwords[key] = password;
    _recovery[key] = (blob: recoveryBlob, salt: recoverySalt);
    _me = user;
    _emitAll();
    return user;
  }

  /// Mock counterpart of [SupabaseBackend.signIn].
  AppUser signIn({required String username, required String password}) {
    final key = username.toLowerCase();
    final stored = _passwords[key];
    if (stored == null || stored != password) {
      throw InvalidCredentialsException();
    }
    final user = _users.firstWhere(
      (u) => u.anonymousPseudonym.toLowerCase() == key,
    );
    _me = user;
    _emitAll();
    return user;
  }

  ({String blob, String salt})? fetchRecoveryMaterial(String username) =>
      _recovery[username.toLowerCase()];

  /// Test-only helper: look up the in-memory password so the repository can
  /// re-sign-in after a hot restart in mock mode. Lives on the mock backend
  /// only — the live backend uses Supabase's persisted auth session.
  String? passwordOf(String username) => _passwords[username.toLowerCase()];

  bool verifyCurrentPassword(String password) {
    final me = _me;
    if (me == null || password.isEmpty) return false;
    final stored = _passwords[me.anonymousPseudonym.toLowerCase()];
    return stored == null ? true : stored == password;
  }

  /// Update the password for [username] — used by the recover-with-phrase
  /// flow when the user sets a new password after restoring their account.
  void resetPassword({required String username, required String newPassword}) {
    _passwords[username.toLowerCase()] = newPassword;
  }

  void logout() {
    _me = null;
    _emitAll();
  }

  // -------------------- Feed --------------------
  List<Post> feed({
    String? category,
    String? mood,
    String? tribeSlug,
    String? locationBucket,
    String sort = 'fresh',
    int limit = 30,
    int offset = 0,
  }) {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final filtered = _posts.where((p) {
      final byCategory = category == null || p.categoryName == category;
      final byMood = mood == null || p.postMood == mood;
      final byTribe = tribeSlug == null || p.tribeSlug == tribeSlug;
      final byWhisper = !p.isWhisper || p.createdAt.isAfter(cutoff);
      // Mock posts don't carry a location_bucket. When the caller asks for
      // a local feed, return empty so the UI exercises the fallback path.
      final byLocation = locationBucket == null;
      return byCategory && byMood && byTribe && byWhisper && byLocation;
    }).toList();

    if (sort == 'hot' || sort == 'foryou') {
      final myTribeSlugs = _tribes
          .where((t) => t.joinedByMe)
          .map((t) => t.slug)
          .toSet();
      double score(Post p) {
        final base = (p.likesCount + p.commentsCount) + 1;
        final ageHours =
            DateTime.now().difference(p.createdAt).inMinutes / 60.0;
        var s = base / ((ageHours + 2) * (ageHours + 2)).clamp(1, 1e9);
        if (sort == 'foryou') {
          if (p.tribeSlug != null && myTribeSlugs.contains(p.tribeSlug)) {
            s += 1.5;
          }
          if (p.commentsCount < 3 && ageHours < 12) s += 0.4;
        }
        return s;
      }

      filtered.sort((a, b) => score(b).compareTo(score(a)));
    } else {
      filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    final slice = filtered.skip(offset).take(limit).toList();
    return [
      for (final p in slice)
        p.copyWith(
          myReaction: _myReactions[p.postId],
          savedByMe: _savedPosts.contains(p.postId),
        ),
    ];
  }

  Post? postById(String postId) {
    final p = _posts.firstWhereOrNull((p) => p.postId == postId);
    if (p == null) return null;
    return p.copyWith(
      myReaction: _myReactions[postId],
      savedByMe: _savedPosts.contains(postId),
    );
  }

  Future<Post> createPost({
    required String content,
    required String category,
    required String mood,
    String? tribeId,
    String? spaceId,
    String? personaId,
    bool isWhisper = false,
    bool isStory = false,
    String storyAudience = 'everyone',
    String? imageUrl,
    String? audioUrl,
    int? audioDurationSeconds,
    String? pollQuestion,
    List<String>? pollOptions,
    String? cardBackgroundColor,
    String? cardTextColor,
    MusicTrack? musicTrack,
    int musicStartMs = 0,
    int musicDurationMs = 15000,
    double musicVolume = 0.75,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final tribe = tribeId == null
        ? null
        : _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    final persona = personaId == null
        ? null
        : _personasByUser[me.userId]?.firstWhereOrNull(
            (p) => p.personaId == personaId,
          );
    final canonicalTrack = musicTrack == null
        ? null
        : _authorizedMusicTracks.firstWhereOrNull(
            (track) => track.trackId == musicTrack.trackId,
          );
    if (musicTrack != null && canonicalTrack == null) {
      throw StateError('music_track_unavailable');
    }
    if (canonicalTrack != null &&
        (musicStartMs < 0 ||
            musicDurationMs < 5000 ||
            musicDurationMs > 30000 ||
            musicStartMs + musicDurationMs > canonicalTrack.previewDurationMs ||
            musicVolume < 0 ||
            musicVolume > 1)) {
      throw StateError('invalid_music_window');
    }
    final post = Post(
      postId: _uuid.v4(),
      authorId: me.userId,
      authorPseudonym: persona == null
          ? '@${me.anonymousPseudonym}'
          : '@${persona.pseudonym}',
      authorDisplayName: persona == null ? me.displayName : null,
      authorAvatarSeed: persona?.avatarSeed ?? me.avatarSeed,
      authorProfilePhotoUrl: persona == null ? me.profilePhotoUrl : null,
      authorIsVerified: me.isVerified,
      categoryName: category,
      postType: 'user_post',
      content: content,
      postMood: mood,
      isWhisper: isWhisper,
      isStory: isStory,
      storyAudience: isStory ? storyAudience : 'everyone',
      cardBackgroundColor: cardBackgroundColor,
      cardTextColor: cardTextColor,
      likesCount: 0,
      commentsCount: 0,
      createdAt: DateTime.now(),
      tribeId: tribe?.tribeId,
      tribeName: tribe?.name,
      tribeSlug: tribe?.slug,
      spaceId: spaceId,
      imageUrl: imageUrl,
      audioUrl: audioUrl,
      audioDurationSeconds: audioDurationSeconds,
      musicTrackId: canonicalTrack?.trackId,
      musicTrack: canonicalTrack,
      musicStartMs: canonicalTrack == null ? null : musicStartMs,
      musicDurationMs: canonicalTrack == null ? null : musicDurationMs,
      musicVolume: canonicalTrack == null ? null : musicVolume,
    );
    if (canonicalTrack != null) {
      _musicUsage.update(
        canonicalTrack.trackId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    _posts.insert(0, post);
    if (pollQuestion != null && pollOptions != null) {
      createPoll(
        postId: post.postId,
        question: pollQuestion,
        optionTexts: pollOptions,
      );
    }
    _emitPosts();
    return post;
  }

  List<MusicTrack> searchMusic({
    String query = '',
    String? mood,
    int limit = 24,
    int offset = 0,
  }) {
    final normalized = query.trim().toLowerCase();
    final filtered = _authorizedMusicTracks
        .where((track) {
          final matchesMood = mood == null || track.moodTags.contains(mood);
          final haystack = [
            track.title,
            track.artist,
            track.album ?? '',
            track.genre ?? '',
            ...track.moodTags,
          ].join(' ').toLowerCase();
          return matchesMood &&
              (normalized.isEmpty || haystack.contains(normalized));
        })
        .toList(growable: false);
    final safeOffset = offset.clamp(0, filtered.length);
    final end = (safeOffset + limit.clamp(1, 50)).clamp(
      safeOffset,
      filtered.length,
    );
    return filtered.sublist(safeOffset, end);
  }

  List<MusicTrack> musicCatalogSection(String section, {int limit = 12}) {
    if (!const {'recent', 'for_you', 'trending'}.contains(section)) {
      throw StateError('unsupported catalog section');
    }
    final tracks = List<MusicTrack>.from(_authorizedMusicTracks);
    if (section == 'recent') {
      tracks.sort(
        (a, b) => (_musicUsage[b.trackId] ?? 0).compareTo(
          _musicUsage[a.trackId] ?? 0,
        ),
      );
      tracks.removeWhere((track) => !_musicUsage.containsKey(track.trackId));
    } else if (section == 'for_you' && _me != null) {
      final mood = _me!.currentMood;
      tracks.sort(
        (a, b) => (b.moodTags.contains(mood) ? 1 : 0).compareTo(
          a.moodTags.contains(mood) ? 1 : 0,
        ),
      );
    } else {
      tracks.sort(
        (a, b) => (_musicUsage[b.trackId] ?? 0).compareTo(
          _musicUsage[a.trackId] ?? 0,
        ),
      );
    }
    return tracks.take(limit.clamp(1, 50)).toList(growable: false);
  }

  void setPostMusic(
    String postId, {
    MusicTrack? track,
    int startMs = 0,
    int durationMs = 15000,
    double volume = 0.75,
  }) {
    final index = _posts.indexWhere((post) => post.postId == postId);
    if (index < 0) throw StateError('post not found');
    if (!_posts[index].ownedBy(_me?.userId)) {
      throw StateError('not your post');
    }
    final canonical = track == null
        ? null
        : _authorizedMusicTracks.firstWhereOrNull(
            (item) => item.trackId == track.trackId,
          );
    if (track != null && canonical == null) {
      throw StateError('music_track_unavailable');
    }
    if (canonical != null &&
        (startMs < 0 ||
            durationMs < 5000 ||
            durationMs > 30000 ||
            startMs + durationMs > canonical.previewDurationMs ||
            volume < 0 ||
            volume > 1)) {
      throw StateError('invalid_music_window');
    }
    final current = _posts[index];
    final sameTrack = current.musicTrackId == canonical?.trackId;
    _posts[index] = current.copyWith(
      musicTrackId: canonical?.trackId,
      musicTrack: canonical,
      musicStartMs: canonical == null ? null : startMs,
      musicDurationMs: canonical == null ? null : durationMs,
      musicVolume: canonical == null ? null : volume,
    );
    if (canonical != null && !sameTrack) {
      _musicUsage.update(
        canonical.trackId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    _emitPosts();
  }

  bool editPost({required String postId, required String newContent}) {
    final index = _posts.indexWhere((post) => post.postId == postId);
    if (index == -1) throw StateError('post not found');
    final post = _posts[index];
    if (!post.ownedBy(_me?.userId)) throw StateError('not your post');
    if (newContent.trim().isEmpty && !post.hasImage && !post.hasAudio) {
      throw StateError('post content or media required');
    }
    _posts[index] = post.copyWith(
      content: newContent,
      editedAt: DateTime.now(),
    );
    _postsController.add(List.unmodifiable(_posts));
    return true;
  }

  bool deletePost(String postId) {
    final index = _posts.indexWhere((post) => post.postId == postId);
    if (index == -1) throw StateError('post not found');
    final post = _posts[index];
    if (!post.ownedBy(_me?.userId)) throw StateError('not your post');
    _posts[index] = post.copyWith(deletedAt: DateTime.now());
    _postsController.add(List.unmodifiable(_posts));
    return true;
  }

  void toggleLike(String postId) => react(postId, 'hug');

  /// Mock parity for set_reaction: toggle off when same, switch when
  /// different, insert when none. Returns the new reaction (or null
  /// when toggled off).
  String? react(String postId, String reaction) {
    final i = _posts.indexWhere((p) => p.postId == postId);
    if (i == -1) return null;
    if (_posts[i].ownedBy(_me?.userId)) {
      throw StateError('self_interaction_not_allowed');
    }
    final current = _myReactions[postId];
    String? result;
    if (current == null) {
      _myReactions[postId] = reaction;
      _posts[i] = _posts[i].copyWith(likesCount: _posts[i].likesCount + 1);
      result = reaction;
    } else if (current == reaction) {
      _myReactions.remove(postId);
      _posts[i] = _posts[i].copyWith(
        likesCount: max(_posts[i].likesCount - 1, 0),
      );
      result = null;
    } else {
      _myReactions[postId] = reaction;
      result = reaction;
    }
    _emitPosts();
    return result;
  }

  void toggleSave(String postId) {
    if (_savedPosts.contains(postId)) {
      _savedPosts.remove(postId);
    } else {
      _savedPosts.add(postId);
    }
    _emitPosts();
  }

  bool toggleWhisperSave(String whisperId) {
    if (_savedWhispers.contains(whisperId)) {
      _savedWhispers.remove(whisperId);
      return false;
    }
    _savedWhispers.add(whisperId);
    return true;
  }

  List<Whisper> mySavedWhispers() => const [];

  bool toggleWhisperLike(String whisperId) {
    if (_whisperReactions.containsKey(whisperId)) {
      _whisperReactions.remove(whisperId);
      return false;
    }
    _whisperReactions[whisperId] = 'love';
    return true;
  }

  String? reactToWhisper(String whisperId, String reaction) {
    final current = _whisperReactions[whisperId];
    if (current == reaction) {
      _whisperReactions.remove(whisperId);
      return null;
    }
    _whisperReactions[whisperId] = reaction;
    return reaction;
  }

  final Set<String> _reportedPosts = {};
  final Set<String> _reportedRooms = {};
  void reportPost({
    required String postId,
    required String reason,
    String? note,
  }) {
    _reportedPosts.add(postId);
  }

  void reportChat({
    required String roomId,
    required String reason,
    String? note,
  }) {
    _reportedRooms.add(roomId);
  }

  // -------------------- Keeper tools --------------------

  final List<TribeReport> _tribeReports = [];

  PlugPrompt createPromptForTribe({
    required String tribeId,
    required String text,
  }) {
    final me = _me;
    final prompt = PlugPrompt(
      promptId: _uuid.v4(),
      plugDisplayName: '@${me?.anonymousPseudonym ?? 'keeper'}',
      plugAvatarSeed: me?.avatarSeed ?? 'default-orb',
      promptText: text,
      answersCount: 0,
    );
    _prompts.insert(0, prompt);
    return prompt;
  }

  PlugPrompt createUserQuestion({
    required String text,
    String audience = 'everyone',
  }) {
    final me = _me;
    final prompt = PlugPrompt(
      promptId: _uuid.v4(),
      plugDisplayName: '@${me?.anonymousPseudonym ?? 'anonymous'}',
      plugAvatarSeed: me?.avatarSeed ?? 'default-orb',
      promptText: text,
      answersCount: 0,
      authorId: me?.userId,
      audience: audience,
    );
    _prompts.insert(0, prompt);
    return prompt;
  }

  List<PlugPrompt> questionsByAuthor(String userId) =>
      _prompts.where((p) => p.authorId == userId).toList();

  void updateUserQuestion({
    required String promptId,
    String? text,
    String? audience,
  }) {
    final i = _prompts.indexWhere((p) => p.promptId == promptId);
    if (i < 0) return;
    _prompts[i] = _prompts[i].copyWith(promptText: text, audience: audience);
  }

  void deleteUserQuestion(String promptId) {
    _prompts.removeWhere((p) => p.promptId == promptId);
  }

  void likeQuestion(String promptId) {
    final i = _prompts.indexWhere((p) => p.promptId == promptId);
    if (i < 0 || _prompts[i].likedByMe) return;
    _prompts[i] = _prompts[i].copyWith(
      likedByMe: true,
      likeCount: _prompts[i].likeCount + 1,
    );
  }

  void unlikeQuestion(String promptId) {
    final i = _prompts.indexWhere((p) => p.promptId == promptId);
    if (i < 0 || !_prompts[i].likedByMe) return;
    _prompts[i] = _prompts[i].copyWith(
      likedByMe: false,
      likeCount: (_prompts[i].likeCount - 1).clamp(0, 1 << 30),
    );
  }

  List<TribeReport> tribeReports(String tribeId) {
    // Mock only — keep the demo seed posts visible to the keeper as if
    // they'd been reported, so the queue isn't empty in dev mode.
    if (_tribeReports.isEmpty) {
      final tribePosts = _posts
          .where((p) => p.tribeId == tribeId)
          .take(2)
          .toList();
      for (final p in tribePosts) {
        _tribeReports.add(
          TribeReport(
            reportId: _uuid.v4(),
            reason: 'harassment',
            isResolved: false,
            createdAt: DateTime.now().subtract(const Duration(hours: 4)),
            postId: p.postId,
            postPreview: p.content.length > 160
                ? p.content.substring(0, 160)
                : p.content,
            postDeleted: false,
          ),
        );
      }
    }
    return List.unmodifiable(_tribeReports);
  }

  void resolveReport(String reportId) {
    final i = _tribeReports.indexWhere((r) => r.reportId == reportId);
    if (i == -1) return;
    final r = _tribeReports[i];
    _tribeReports[i] = TribeReport(
      reportId: r.reportId,
      reason: r.reason,
      note: r.note,
      isResolved: true,
      createdAt: r.createdAt,
      postId: r.postId,
      postPreview: r.postPreview,
      postDeleted: r.postDeleted,
    );
  }

  Tribe updateTribe({
    required String tribeId,
    String? name,
    String? description,
    bool? isPrivate,
    String? avatarUrl,
    String? bannerUrl,
  }) {
    final i = _tribes.indexWhere((t) => t.tribeId == tribeId);
    if (i == -1) throw StateError('Tribe not found');
    final current = _tribes[i];
    // Slug stays stable across name changes — keeps deep links + reports
    // valid. Server-side migration 0005 only sets the slug at INSERT time
    // for the same reason.
    final updated = Tribe(
      tribeId: current.tribeId,
      name: name ?? current.name,
      slug: current.slug,
      description: description ?? current.description,
      category: current.category,
      memberCount: current.memberCount,
      isPrivate: isPrivate ?? current.isPrivate,
      avatarUrl: avatarUrl ?? current.avatarUrl,
      bannerUrl: bannerUrl ?? current.bannerUrl,
      keeperId: current.keeperId,
      keeperPseudonym: current.keeperPseudonym,
      keeperAvatarSeed: current.keeperAvatarSeed,
      keeperIsVerified: current.keeperIsVerified,
      createdAt: current.createdAt,
      joinedByMe: current.joinedByMe,
    );
    _tribes[i] = updated;
    return updated;
  }

  TribeManagementOverview tribeManagementOverview(String tribeId) {
    final tribe = _tribes.firstWhere(
      (item) => item.tribeId == tribeId,
      orElse: () => throw StateError('Tribe not found'),
    );
    if (_me?.userId != tribe.keeperId) {
      throw StateError('Only the Plug can manage this Tribe');
    }
    final settings = TribeGovernanceSettings.fromJson(tribe.managementSettings);
    return TribeManagementOverview(
      tribeId: tribe.tribeId,
      name: tribe.name,
      slug: tribe.slug,
      description: tribe.description,
      category: tribe.category,
      tags: tribe.tags,
      visibility: tribe.visibility,
      lifecycleStatus: tribe.lifecycleStatus,
      lifecycleReason: tribe.lifecycleReason,
      avatarUrl: tribe.avatarUrl,
      bannerUrl: tribe.bannerUrl,
      welcomeMessage: tribe.welcomeMessage,
      deletionRequestedAt: tribe.deletionRequestedAt,
      deletionPurgeAt: tribe.deletionPurgeAt,
      memberCount: tribe.memberCount,
      postCount: _posts
          .where((post) => post.tribeId == tribeId && !post.isDeleted)
          .length,
      spaceCount: _spaces
          .where(
            (space) => space.tribeId == tribeId && space.archivedAt == null,
          )
          .length,
      pendingJoinRequests: _managementJoinRequests
          .where((request) => request.requestId.startsWith('$tribeId:'))
          .length,
      pendingInvitations: _invites
          .where((invite) => invite.tribeId == tribeId && invite.isPending)
          .length,
      openReports: tribeReports(
        tribeId,
      ).where((report) => !report.isResolved).length,
      settings: settings,
      rules: List.unmodifiable(_managementRules[tribeId] ?? const []),
    );
  }

  TribeManagementOverview updateTribeConfiguration({
    required String tribeId,
    String? name,
    String? description,
    String? category,
    List<String>? tags,
    String? visibility,
    String? avatarUrl,
    String? bannerUrl,
    String? welcomeMessage,
    TribeGovernanceSettings? settings,
  }) {
    final i = _tribes.indexWhere((tribe) => tribe.tribeId == tribeId);
    if (i == -1) throw StateError('Tribe not found');
    final current = _tribes[i];
    if (_me?.userId != current.keeperId) {
      throw StateError('Only the Plug can manage this Tribe');
    }
    _tribes[i] = current.copyWith(
      name: name,
      description: description,
      category: category,
      isPrivate: visibility == null ? null : visibility != 'public',
      avatarUrl: avatarUrl,
      bannerUrl: bannerUrl,
      welcomeMessage: welcomeMessage,
      visibility: visibility,
      tags: tags,
      managementSettings: settings?.toJson(),
    );
    _addManagementAudit(tribeId, 'TRIBE_CONFIGURATION_UPDATED');
    return tribeManagementOverview(tribeId);
  }

  TribeManagementOverview replaceTribeRules(
    String tribeId,
    List<TribeRuleItem> rules,
  ) {
    tribeManagementOverview(tribeId);
    _managementRules[tribeId] = [
      for (var i = 0; i < rules.length; i++) rules[i].copyWith(position: i),
    ];
    _addManagementAudit(tribeId, 'TRIBE_RULES_REPLACED');
    return tribeManagementOverview(tribeId);
  }

  List<TribeJoinRequest> tribeJoinRequests(String tribeId) =>
      _managementJoinRequests
          .where((request) => request.requestId.startsWith('$tribeId:'))
          .toList(growable: false);

  String requestTribeMembership(String tribeId, {String? note}) {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final tribe = _tribes.firstWhere((item) => item.tribeId == tribeId);
    if (!tribe.acceptsNewActivity) {
      throw StateError('This Tribe is not accepting members');
    }
    final settings = TribeGovernanceSettings.fromJson(tribe.managementSettings);
    if (tribe.visibility != 'public' || settings.joinApprovalRequired) {
      _managementJoinRequests.removeWhere(
        (request) => request.requestId == '$tribeId:${me.userId}',
      );
      _managementJoinRequests.add(
        TribeJoinRequest(
          requestId: '$tribeId:${me.userId}',
          userId: me.userId,
          pseudonym: me.anonymousPseudonym,
          avatarSeed: me.avatarSeed,
          profilePhotoUrl: me.profilePhotoUrl,
          note: note,
          createdAt: DateTime.now(),
        ),
      );
      return 'pending';
    }
    joinTribe(tribeId);
    return 'joined';
  }

  void respondTribeJoinRequest(String requestId, {required bool approve}) {
    final request = _managementJoinRequests.firstWhere(
      (item) => item.requestId == requestId,
    );
    final tribeId = requestId.split(':').first;
    tribeManagementOverview(tribeId);
    if (approve) _joinedTribes.add(tribeId);
    _managementJoinRequests.remove(request);
    _addManagementAudit(
      tribeId,
      approve ? 'JOIN_REQUEST_APPROVED' : 'JOIN_REQUEST_REJECTED',
    );
  }

  void manageTribeMember({
    required String tribeId,
    required String userId,
    required String action,
    String? reason,
    DateTime? muteUntil,
  }) {
    switch (action) {
      case 'promote':
        promoteToMod(tribeId: tribeId, userId: userId);
        break;
      case 'demote':
        demoteToMember(tribeId: tribeId, userId: userId);
        break;
      case 'remove':
      case 'ban':
        kickMember(tribeId: tribeId, userId: userId, reason: reason);
        break;
      case 'warn':
      case 'mute':
      case 'unmute':
        break;
      default:
        throw ArgumentError.value(action, 'action');
    }
    _addManagementAudit(tribeId, 'MEMBER_${action.toUpperCase()}');
  }

  String initiateTribeTransfer({
    required String tribeId,
    required String toUserId,
    bool keepPreviousOwnerAsMod = true,
  }) {
    tribeManagementOverview(tribeId);
    final transferId = _uuid.v4();
    _addManagementAudit(tribeId, 'OWNERSHIP_TRANSFER_INITIATED');
    return transferId;
  }

  void respondTribeTransfer(String transferId, {required bool accept}) {
    if (transferId.isEmpty) throw StateError('Transfer not found');
  }

  TribeManagementOverview setTribeLifecycle({
    required String tribeId,
    required String action,
    String? reason,
    String? confirmedName,
  }) {
    final i = _tribes.indexWhere((tribe) => tribe.tribeId == tribeId);
    if (i == -1) throw StateError('Tribe not found');
    final current = _tribes[i];
    if (_me?.userId != current.keeperId) throw StateError('Not the owner');
    if (action == 'request_delete' && confirmedName != current.name) {
      throw const FormatException('Type the Tribe name exactly.');
    }
    final status = switch (action) {
      'pause' => 'paused',
      'archive' => 'archived',
      'request_delete' => 'pending_deletion',
      'activate' || 'cancel_delete' => 'active',
      _ => throw ArgumentError.value(action, 'action'),
    };
    _tribes[i] = current.copyWith(lifecycleStatus: status);
    _addManagementAudit(tribeId, 'TRIBE_${action.toUpperCase()}');
    return tribeManagementOverview(tribeId);
  }

  List<TribeAuditEvent> tribeAuditLog(String tribeId, {int limit = 100}) =>
      _managementAudit
          .where((event) => event.targetId == tribeId)
          .take(limit)
          .toList(growable: false);

  List<TribeManagedPost> managedTribePosts(String tribeId, {int limit = 100}) {
    tribeManagementOverview(tribeId);
    return _posts
        .where((post) => post.tribeId == tribeId && !post.isDeleted)
        .take(limit)
        .map(
          (post) => TribeManagedPost(
            postId: post.postId,
            authorId: post.authorId,
            authorPseudonym: post.authorPseudonym,
            authorAvatarSeed: post.authorAvatarSeed,
            authorProfilePhotoUrl: post.authorProfilePhotoUrl,
            content: post.content,
            categoryName: post.categoryName,
            postMood: post.postMood,
            spaceId: post.spaceId,
            likesCount: post.likesCount,
            commentsCount: post.commentsCount,
            createdAt: post.createdAt,
            isApproved: true,
            isPinned: (_pinnedByTribe[tribeId] ?? const []).contains(
              post.postId,
            ),
            lockedAt: post.lockedAt,
          ),
        )
        .toList(growable: false);
  }

  String manageTribeSpace({
    required String tribeId,
    required String action,
    String? spaceId,
    String? name,
    String? description,
    String? iconName,
    String? weeklyTheme,
    String? postingPermission,
    bool? isPinned,
    DateTime? activatesAt,
    DateTime? deactivatesAt,
    String? reason,
  }) {
    tribeManagementOverview(tribeId);
    final tribe = _tribes.firstWhere((item) => item.tribeId == tribeId);
    final now = DateTime.now();

    if (action == 'create') {
      final trimmedName = name?.trim() ?? '';
      if (trimmedName.length < 2 || trimmedName.length > 60) {
        throw const FormatException('Space names must be 2-60 characters.');
      }
      var slug = trimmedName
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      if (slug.isEmpty) slug = 'space';
      final baseSlug = slug;
      var suffix = 2;
      while (_spaces.any(
        (space) => space.tribeId == tribeId && space.slug == slug,
      )) {
        slug = '$baseSlug-${suffix++}';
      }
      final id = _uuid.v4();
      _spaces.add(
        Space(
          spaceId: id,
          tribeId: tribeId,
          tribeSlug: tribe.slug,
          tribeName: tribe.name,
          slug: slug,
          name: trimmedName,
          description: _emptyToNull(description),
          weeklyTheme: _emptyToNull(weeklyTheme),
          iconName: _emptyToNull(iconName),
          isDefault: false,
          isPinned: isPinned ?? false,
          postingPermission: postingPermission ?? 'members',
          activatesAt: activatesAt,
          deactivatesAt: deactivatesAt,
          createdAt: now,
          updatedAt: now,
          ventCount: 0,
          ventsToday: 0,
        ),
      );
      _addManagementAudit(tribeId, 'SPACE_CREATE');
      return id;
    }

    final index = _spaces.indexWhere(
      (space) => space.spaceId == spaceId && space.tribeId == tribeId,
    );
    if (index == -1) throw StateError('Space not found');
    final current = _spaces[index];
    switch (action) {
      case 'update':
        final trimmedName = name?.trim();
        if (trimmedName != null &&
            (trimmedName.length < 2 || trimmedName.length > 60)) {
          throw const FormatException('Space names must be 2-60 characters.');
        }
        _spaces[index] = _copySpace(
          current,
          name: trimmedName,
          description: description,
          iconName: iconName,
          weeklyTheme: weeklyTheme,
          postingPermission: postingPermission,
          isPinned: isPinned,
          activatesAt: activatesAt,
          deactivatesAt: deactivatesAt,
          updatedAt: now,
        );
        break;
      case 'archive':
        if (current.isDefault) {
          throw StateError('The General Space cannot be archived');
        }
        _spaces[index] = _copySpace(current, archivedAt: now, updatedAt: now);
        break;
      case 'restore':
        _spaces[index] = _copySpace(
          current,
          clearArchivedAt: true,
          updatedAt: now,
        );
        break;
      case 'delete':
        if (current.isDefault) {
          throw StateError('The General Space cannot be deleted');
        }
        final defaultSpace = _spaces.firstWhereOrNull(
          (space) => space.tribeId == tribeId && space.isDefault,
        );
        if (defaultSpace == null) throw StateError('General Space not found');
        for (var i = 0; i < _posts.length; i++) {
          if (_posts[i].spaceId == current.spaceId) {
            _posts[i] = _posts[i].copyWith(spaceId: defaultSpace.spaceId);
          }
        }
        _spaces.removeAt(index);
        break;
      default:
        throw ArgumentError.value(action, 'action');
    }
    _addManagementAudit(tribeId, 'SPACE_${action.toUpperCase()}');
    return current.spaceId;
  }

  List<Space> spacesByTribe(String tribeId) {
    final items = _spaces.where((space) => space.tribeId == tribeId).map((
      space,
    ) {
      final posts = _posts.where(
        (post) => post.spaceId == space.spaceId && post.deletedAt == null,
      );
      final today = DateTime.now().subtract(const Duration(hours: 24));
      return _copySpace(
        space,
        ventCount: posts.length,
        ventsToday: posts.where((post) => post.createdAt.isAfter(today)).length,
      );
    }).toList();
    items.sort((a, b) {
      if (a.isArchived != b.isArchived) return a.isArchived ? 1 : -1;
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return a.createdAt.compareTo(b.createdAt);
    });
    return List.unmodifiable(items);
  }

  Space? spaceById(String spaceId) =>
      _spaces.firstWhereOrNull((space) => space.spaceId == spaceId);

  List<Post> postsInSpace({
    required String spaceId,
    String sort = 'fresh',
    int limit = 60,
  }) {
    final items = _posts
        .where((post) => post.spaceId == spaceId && !post.isDeleted)
        .toList();
    if (sort == 'unanswered') {
      items.removeWhere((post) => post.commentsCount != 0);
    }
    items.sort(
      (a, b) => switch (sort) {
        'trending' => b.likesCount.compareTo(a.likesCount),
        'helpful' => b.commentsCount.compareTo(a.commentsCount),
        _ => b.createdAt.compareTo(a.createdAt),
      },
    );
    return List.unmodifiable(items.take(limit));
  }

  void _ensureDefaultSpace(Tribe tribe, {DateTime? createdAt}) {
    if (_spaces.any(
      (space) => space.tribeId == tribe.tribeId && space.isDefault,
    )) {
      return;
    }
    final now = createdAt ?? DateTime.now();
    _spaces.add(
      Space(
        spaceId: _uuid.v4(),
        tribeId: tribe.tribeId,
        tribeSlug: tribe.slug,
        tribeName: tribe.name,
        slug: 'general',
        name: 'General',
        description: 'The main room - everything goes here.',
        iconName: 'home',
        isDefault: true,
        createdAt: now,
        updatedAt: now,
        ventCount: 0,
        ventsToday: 0,
      ),
    );
  }

  Space _copySpace(
    Space space, {
    String? name,
    String? description,
    String? iconName,
    String? weeklyTheme,
    String? postingPermission,
    bool? isPinned,
    DateTime? activatesAt,
    DateTime? deactivatesAt,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    DateTime? updatedAt,
    int? ventCount,
    int? ventsToday,
  }) {
    return Space(
      spaceId: space.spaceId,
      tribeId: space.tribeId,
      tribeSlug: space.tribeSlug,
      tribeName: space.tribeName,
      slug: space.slug,
      name: name ?? space.name,
      description: description == null
          ? space.description
          : _emptyToNull(description),
      weeklyTheme: weeklyTheme == null
          ? space.weeklyTheme
          : _emptyToNull(weeklyTheme),
      themeColor: space.themeColor,
      isDefault: space.isDefault,
      archivedAt: clearArchivedAt ? null : (archivedAt ?? space.archivedAt),
      createdAt: space.createdAt,
      updatedAt: updatedAt ?? space.updatedAt,
      ventCount: ventCount ?? space.ventCount,
      ventsToday: ventsToday ?? space.ventsToday,
      lastVentAt: space.lastVentAt,
      iconName: iconName == null ? space.iconName : _emptyToNull(iconName),
      isPinned: isPinned ?? space.isPinned,
      postingPermission: postingPermission ?? space.postingPermission,
      activatesAt: activatesAt ?? space.activatesAt,
      deactivatesAt: deactivatesAt ?? space.deactivatesAt,
    );
  }

  String? _emptyToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void manageTribePost({
    required String tribeId,
    required String postId,
    required String action,
    String? targetSpaceId,
  }) {
    tribeManagementOverview(tribeId);
    _addManagementAudit(tribeId, 'POST_${action.toUpperCase()}');
  }

  void _addManagementAudit(String tribeId, String action) {
    _managementAudit.insert(
      0,
      TribeAuditEvent(
        auditId: _uuid.v4(),
        action: action,
        actorPseudonym: _me?.anonymousPseudonym,
        targetType: 'tribe',
        targetId: tribeId,
        createdAt: DateTime.now(),
      ),
    );
  }

  // -------------------- Profile location --------------------
  AppUser updateMyAvatar(String seed) {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final updated = me.copyWith(avatarSeed: seed);
    _me = updated;
    final i = _users.indexWhere((u) => u.userId == me.userId);
    if (i != -1) _users[i] = updated;
    _emitAll();
    return updated;
  }

  AppUser uploadMyProfilePhoto({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final safeExt = extension.replaceAll('.', '').toLowerCase();
    final updated = me.copyWith(
      profilePhotoUrl:
          'mock://profile-photos/${me.userId}-${bytes.length}.${safeExt.isEmpty ? 'jpg' : safeExt}',
    );
    _me = updated;
    final i = _users.indexWhere((u) => u.userId == me.userId);
    if (i != -1) _users[i] = updated;
    _emitAll();
    return updated;
  }

  ({String path, String url}) uploadPostImage({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final safeExt = extension.replaceAll('.', '').toLowerCase();
    final path =
        '${me.userId}/mock-${bytes.length}.${safeExt.isEmpty ? 'jpg' : safeExt}';
    return (path: path, url: 'mock://post-media/$path');
  }

  HomeStats homeStats() {
    final me = _me;
    if (me == null) return HomeStats.empty;
    final myVents = _posts.where((p) => p.authorId == me.userId).length;
    final hugs = _posts
        .where((p) => p.authorId == me.userId)
        .fold<int>(0, (sum, p) => sum + p.likesCount);
    return HomeStats(
      ventsToday: _posts
          .where(
            (p) =>
                DateTime.now().difference(p.createdAt) <
                const Duration(hours: 24),
          )
          .length,
      supporters: 0,
      dailyHugs: hugs,
      streakDays: myVents.clamp(0, 30),
    );
  }

  List<TrendingCategory> trendingCategories({int limit = 6}) {
    final counts = <String, int>{};
    final reactions = <String, int>{};
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    for (final p in _posts) {
      if (p.createdAt.isBefore(cutoff)) continue;
      counts[p.categoryName] = (counts[p.categoryName] ?? 0) + 1;
      reactions[p.categoryName] =
          (reactions[p.categoryName] ?? 0) + p.likesCount;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) {
      return TrendingCategory(
        categoryName: e.key,
        postCount: e.value,
        reactionSum: reactions[e.key] ?? 0,
      );
    }).toList();
  }

  List<TrendingVoice> trendingVoices({int limit = 6}) => const [];

  /// Mock search — falls back to client-side substring matching over the
  /// in-memory dataset so offline / unit-test mode still surfaces
  /// recognisable results.
  List<SearchHit> searchGlobal(String query, {int limit = 24}) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) return const [];
    final hits = <SearchHit>[];
    for (final t in _tribes) {
      if (t.name.toLowerCase().contains(q) ||
          (t.description ?? '').toLowerCase().contains(q)) {
        hits.add(
          SearchHit(
            hitKind: 'tribe',
            hitId: t.slug,
            title: t.name,
            subtitle: t.description ?? '',
            memberCount: t.memberCount,
            createdAt: t.createdAt,
            rankScore: 3,
          ),
        );
      }
    }
    for (final p in _posts) {
      if (p.content.toLowerCase().contains(q)) {
        hits.add(
          SearchHit(
            hitKind: 'post',
            hitId: p.postId,
            title: p.content.length > 220
                ? p.content.substring(0, 220)
                : p.content,
            subtitle: p.authorPseudonym,
            avatarSeed: p.authorAvatarSeed,
            profilePhotoUrl: p.authorProfilePhotoUrl,
            likesCount: p.likesCount,
            commentsCount: p.commentsCount,
            createdAt: p.createdAt,
            rankScore: 2,
          ),
        );
      }
    }
    return hits.take(limit).toList();
  }

  bool markStoryViewed(String postId) => true;

  AppUser removeMyProfilePhoto() {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final updated = me.copyWith(profilePhotoUrl: null);
    _me = updated;
    final i = _users.indexWhere((u) => u.userId == me.userId);
    if (i != -1) _users[i] = updated;
    _emitAll();
    return updated;
  }

  AppUser updateMyLocation({
    String? homeCity,
    String? homeCountry,
    String? homeCampus,
  }) {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final updated = me.copyWith(
      homeCity: homeCity?.trim().isEmpty == true ? null : homeCity?.trim(),
      homeCountry: homeCountry?.trim().isEmpty == true
          ? null
          : homeCountry?.trim(),
      homeCampus: homeCampus?.trim().isEmpty == true
          ? null
          : homeCampus?.trim(),
    );
    _me = updated;
    final i = _users.indexWhere((u) => u.userId == me.userId);
    if (i != -1) _users[i] = updated;
    _emitAll();
    return updated;
  }

  // -------------------- Co-mod hierarchy --------------------
  final Map<String, Map<String, String>> _tribeRoles =
      {}; // tribeId -> userId -> role

  String _roleFor(String tribeId, String userId) {
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    if (tribe?.keeperId == userId) return 'keeper';
    return _tribeRoles[tribeId]?[userId] ?? 'member';
  }

  List<TribeMemberRow> tribeMembers(String tribeId) {
    // Mock: derive from the seeded user list — only the keeper + me are
    // realistic members. Returning the keeper-as-keeper is enough for the
    // manage UI smoke test.
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    if (tribe == null) return const [];
    final out = <TribeMemberRow>[];
    if (tribe.keeperId != null) {
      final keeper = _users.firstWhereOrNull((u) => u.userId == tribe.keeperId);
      if (keeper != null) {
        out.add(
          TribeMemberRow(
            userId: keeper.userId,
            pseudonym: keeper.anonymousPseudonym,
            avatarSeed: keeper.avatarSeed,
            profilePhotoUrl: keeper.profilePhotoUrl,
            role: 'keeper',
            joinedAt: tribe.createdAt,
          ),
        );
      }
    }
    final me = _me;
    if (me != null &&
        me.userId != tribe.keeperId &&
        _joinedTribes.contains(tribeId)) {
      out.add(
        TribeMemberRow(
          userId: me.userId,
          pseudonym: me.anonymousPseudonym,
          avatarSeed: me.avatarSeed,
          profilePhotoUrl: me.profilePhotoUrl,
          role: _roleFor(tribeId, me.userId),
          joinedAt: DateTime.now(),
        ),
      );
    }
    return out;
  }

  void promoteToMod({required String tribeId, required String userId}) {
    _tribeRoles.putIfAbsent(tribeId, () => {})[userId] = 'mod';
  }

  void demoteToMember({required String tribeId, required String userId}) {
    _tribeRoles.putIfAbsent(tribeId, () => {})[userId] = 'member';
  }

  void kickMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) {
    _joinedTribes.remove(tribeId);
    _tribeRoles[tribeId]?.remove(userId);
  }

  void transferKeeper({required String tribeId, required String toUserId}) {
    final i = _tribes.indexWhere((t) => t.tribeId == tribeId);
    if (i == -1) return;
    _tribes[i] = _tribes[i].copyWith();
    // Mock doesn't have full keeperId reassignment plumbing — left as a
    // smoke shim; live path is the one we ship against.
  }

  // -------------------- Badges + streaks --------------------
  final List<BadgeDefinition> _badgeCatalogue = const [
    BadgeDefinition(
      key: 'first_vent',
      label: 'First Vent',
      description: 'Your first confession.',
      icon: '⭐',
      tier: 'bronze',
    ),
    BadgeDefinition(
      key: 'seven_day_venter',
      label: '7-Day Venter',
      description: 'Seven consecutive days posting.',
      icon: '🌙',
      tier: 'silver',
    ),
    BadgeDefinition(
      key: 'keeper',
      label: 'Plug',
      description: 'Started your own Tribe.',
      icon: '🌿',
      tier: 'silver',
    ),
    BadgeDefinition(
      key: 'whisper_keeper',
      label: 'Whisper Plug',
      description: 'Posted ten Whispers.',
      icon: '🌒',
      tier: 'bronze',
    ),
  ];
  final Map<String, List<UserBadge>> _userBadges = {};

  List<BadgeDefinition> badgeCatalogue() => _badgeCatalogue;
  List<UserBadge> badgesFor(String userId) => _userBadges[userId] ?? const [];
  List<UserStreak> myStreaks() => const [];

  // -------------------- User lookup --------------------
  AppUser? findUserByPseudonym(String pseudonym) {
    final q = pseudonym.trim().replaceAll('@', '').toLowerCase();
    if (q.isEmpty) return null;
    return _users.firstWhereOrNull(
      (u) => u.anonymousPseudonym.toLowerCase() == q,
    );
  }

  // -------------------- Tribe invitations --------------------
  final List<TribeInvite> _invites = [];

  void inviteToTribe({
    required String tribeId,
    required String invitedUserId,
    String? message,
  }) {
    if (_invites.any(
      (i) =>
          i.tribeId == tribeId &&
          i.invitedUserId == invitedUserId &&
          i.isPending,
    ))
      return;
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    _invites.add(
      TribeInvite(
        inviteId: _uuid.v4(),
        tribeId: tribeId,
        tribeName: tribe?.name ?? 'a Tribe',
        tribeSlug: tribe?.slug,
        tribeAvatarUrl: tribe?.avatarUrl,
        invitedUserId: invitedUserId,
        invitedByPseudonym: _me?.anonymousPseudonym,
        message: message,
        status: 'pending',
        createdAt: DateTime.now(),
      ),
    );
  }

  List<TribeInvite> myPendingInvites() {
    final me = _me;
    if (me == null) return const [];
    return _invites
        .where((i) => i.invitedUserId == me.userId && i.isPending)
        .toList();
  }

  void respondToInvite({required String inviteId, required bool accept}) {
    final i = _invites.indexWhere((x) => x.inviteId == inviteId);
    if (i == -1) return;
    final cur = _invites[i];
    _invites[i] = TribeInvite(
      inviteId: cur.inviteId,
      tribeId: cur.tribeId,
      tribeName: cur.tribeName,
      tribeSlug: cur.tribeSlug,
      tribeAvatarUrl: cur.tribeAvatarUrl,
      invitedUserId: cur.invitedUserId,
      invitedByPseudonym: cur.invitedByPseudonym,
      message: cur.message,
      status: accept ? 'accepted' : 'declined',
      createdAt: cur.createdAt,
    );
    if (accept) joinTribe(cur.tribeId);
  }

  // -------------------- Polls --------------------
  final Map<String, PostPoll> _polls = {}; // keyed by postId

  PostPoll createPoll({
    required String postId,
    required String question,
    required List<String> optionTexts,
    Duration closesIn = const Duration(days: 3),
  }) {
    final options = [
      for (final t in optionTexts) PollOption(optionId: _uuid.v4(), text: t),
    ];
    final poll = PostPoll(
      pollId: _uuid.v4(),
      postId: postId,
      question: question,
      closesAt: DateTime.now().add(closesIn),
      options: options,
      optionCounts: {for (final o in options) o.optionId: 0},
    );
    _polls[postId] = poll;
    return poll;
  }

  PostPoll? pollForPost(String postId) => _polls[postId];

  void votePoll({required String pollId, required String optionId}) {
    final entry = _polls.entries.firstWhereOrNull(
      (e) => e.value.pollId == pollId,
    );
    if (entry == null) return;
    final poll = entry.value;
    final post = _posts.firstWhereOrNull((p) => p.postId == poll.postId);
    if (post?.ownedBy(_me?.userId) ?? false) {
      throw StateError('self_interaction_not_allowed');
    }
    if (poll.myVoteOptionId != null) return; // one vote per user
    final next = Map<String, int>.from(poll.optionCounts);
    next[optionId] = (next[optionId] ?? 0) + 1;
    _polls[entry.key] = PostPoll(
      pollId: poll.pollId,
      postId: poll.postId,
      question: poll.question,
      closesAt: poll.closesAt,
      options: poll.options,
      optionCounts: next,
      myVoteOptionId: optionId,
    );
  }

  List<Post> mySaved() => _posts
      .where((p) => _savedPosts.contains(p.postId))
      .map(
        (p) => p.copyWith(savedByMe: true, myReaction: _myReactions[p.postId]),
      )
      .toList();

  List<Post> myVents() {
    final me = _me;
    if (me == null) return [];
    return postsByAuthor(me.userId);
  }

  List<Post> postsByAuthor(String authorId, {int limit = 20, int offset = 0}) {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final filtered =
        _posts
            .where(
              (p) =>
                  p.authorId == authorId &&
                  ((!p.isWhisper && !p.isStory) || p.createdAt.isAfter(cutoff)),
            )
            .map(
              (p) => p.copyWith(
                myReaction: _myReactions[p.postId],
                savedByMe: _savedPosts.contains(p.postId),
              ),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered.skip(offset).take(limit).toList();
  }

  // -------------------- Comments --------------------
  List<ThreadedComment> comments(String postId) {
    return _commentsByPost[postId] ?? const [];
  }

  Future<ThreadedComment> addComment({
    required String postId,
    String? parentId,
    required String content,
    String? personaId,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final persona = personaId == null
        ? null
        : _personasByUser[me.userId]?.firstWhereOrNull(
            (p) => p.personaId == personaId,
          );
    final tree = _commentsByPost.putIfAbsent(postId, () => []);
    final parent = parentId == null ? null : _findInTree(tree, parentId);
    final depth = parent == null ? 0 : parent.depth + 1;
    final path = parent == null
        ? _uuid.v4().replaceAll('-', '')
        : '${parent.path}.${_uuid.v4().replaceAll('-', '')}';
    final comment = ThreadedComment(
      commentId: _uuid.v4(),
      parentId: parentId,
      authorPseudonym: persona == null
          ? '@${me.anonymousPseudonym}'
          : '@${persona.pseudonym}',
      authorAvatarSeed: persona?.avatarSeed ?? me.avatarSeed,
      content: content,
      path: path,
      depth: depth,
      likesCount: 0,
      createdAt: DateTime.now(),
    );
    if (parent == null) {
      tree.add(comment);
    } else {
      parent.children.add(comment);
    }
    final i = _posts.indexWhere((p) => p.postId == postId);
    if (i != -1) {
      _posts[i] = _posts[i].copyWith(
        commentsCount: _posts[i].commentsCount + 1,
      );
      _emitPosts();
    }
    return comment;
  }

  ThreadedComment? _findInTree(List<ThreadedComment> nodes, String id) {
    for (final n in nodes) {
      if (n.commentId == id) return n;
      final found = _findInTree(n.children, id);
      if (found != null) return found;
    }
    return null;
  }

  // -------------------- Personas --------------------
  List<Persona> myPersonas() {
    final me = _me;
    if (me == null) return const [];
    return List.unmodifiable(_personasByUser[me.userId] ?? const []);
  }

  Future<Persona> createPersona({
    required String pseudonym,
    required String avatarSeed,
    String? bio,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final list = _personasByUser.putIfAbsent(me.userId, () => []);
    if (list.length >= 5) throw StateError('max 5 personas per user');
    final exists = list.any(
      (p) => p.pseudonym.toLowerCase() == pseudonym.toLowerCase(),
    );
    if (exists) throw StateError('pseudonym already in use');
    final persona = Persona(
      personaId: _uuid.v4(),
      pseudonym: pseudonym.trim(),
      avatarSeed: avatarSeed,
      bio: bio,
      createdAt: DateTime.now(),
    );
    list.add(persona);
    return persona;
  }

  Future<Persona> updatePersona({
    required String personaId,
    required String pseudonym,
    required String avatarSeed,
    String? bio,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final list = _personasByUser[me.userId];
    if (list == null) throw StateError('persona not found');
    final i = list.indexWhere((p) => p.personaId == personaId);
    if (i == -1) throw StateError('persona not found');
    final updated = Persona(
      personaId: personaId,
      pseudonym: pseudonym.trim(),
      avatarSeed: avatarSeed,
      bio: bio,
      createdAt: list[i].createdAt,
    );
    list[i] = updated;
    return updated;
  }

  Future<bool> deletePersona(String personaId) async {
    final me = _me;
    if (me == null) return false;
    final list = _personasByUser[me.userId];
    if (list == null) return false;
    final before = list.length;
    list.removeWhere((p) => p.personaId == personaId);
    return list.length < before;
  }

  Future<void> setPostCrisis(String postId, String level) async {
    final i = _posts.indexWhere((p) => p.postId == postId);
    if (i == -1) return;
    _posts[i] = _posts[i].copyWith(crisisLevel: level);
  }

  Future<List<CrisisHelpline>> crisisResources({String? region}) async {
    final base = <CrisisHelpline>[
      const CrisisHelpline(
        resourceId: 'mock-rw-kigali-mental-health',
        region: 'RW',
        label: 'Kigali Mental Health Referral Centre',
        reach: 'Call 0793902059 or 0736440666',
        url: 'https://www.kmentalhealth.gov.rw/',
        hours: 'Contact centre',
        sortOrder: 10,
      ),
      const CrisisHelpline(
        resourceId: 'mock-rw-emergency',
        region: 'RW',
        label: 'Rwanda health emergency',
        reach: 'Call 114 or 912',
        url: 'https://www.moh.gov.rw/contact',
        hours: 'Emergency',
        sortOrder: 20,
      ),
      const CrisisHelpline(
        resourceId: 'mock-rw-isange-3029',
        region: 'RW',
        label: 'Isange One Stop Centre (GBV and child abuse)',
        reach: 'Call 3029',
        url: 'https://police.gov.rw/',
        hours: 'Toll-free line',
        sortOrder: 30,
      ),
      const CrisisHelpline(
        resourceId: 'mock-befrienders',
        region: 'global',
        label: 'International Befrienders',
        reach: 'Find a local line',
        url: 'https://befrienders.org',
        hours: '24/7',
        sortOrder: 40,
      ),
    ];
    if (region == null || region.isEmpty) return base;
    base.sort((a, b) {
      int rank(CrisisHelpline c) {
        if (c.region == region) return 0;
        if (c.region == 'global') return 1;
        return 2;
      }

      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.sortOrder.compareTo(b.sortOrder);
    });
    return base;
  }

  // ──────────────────── Friends graph ────────────────────

  ({String a, String b}) _pair(String u1, String u2) {
    return u1.compareTo(u2) < 0 ? (a: u1, b: u2) : (a: u2, b: u1);
  }

  bool _isBlocked(String u1, String u2) => _blocks.any(
    (b) =>
        (b.blockerId == u1 && b.blockedId == u2) ||
        (b.blockerId == u2 && b.blockedId == u1),
  );

  AppUser? _findUser(String id) {
    for (final u in _users) {
      if (u.userId == id) return u;
    }
    return null;
  }

  Future<FriendStatus> friendStatus(String otherUserId) async {
    final me = _me;
    if (me == null) return FriendStatus.none;
    if (me.userId == otherUserId) return FriendStatus.self;
    final blockedByMe = _blocks.any(
      (b) => b.blockerId == me.userId && b.blockedId == otherUserId,
    );
    if (blockedByMe) return FriendStatus.blockedByMe;
    final blockedMe = _blocks.any(
      (b) => b.blockerId == otherUserId && b.blockedId == me.userId,
    );
    if (blockedMe) return FriendStatus.blockedMe;
    final pair = _pair(me.userId, otherUserId);
    final row = _friendships.firstWhereOrNull(
      (f) => f.userA == pair.a && f.userB == pair.b,
    );
    if (row == null) return FriendStatus.none;
    if (row.status == 'accepted') return FriendStatus.friends;
    return row.requestedBy == me.userId
        ? FriendStatus.pendingOutgoing
        : FriendStatus.pendingIncoming;
  }

  Future<String> sendFriendRequest(String otherUserId, {String? note}) async {
    final me = _me;
    if (me == null) throw StateError('not signed in');
    if (me.userId == otherUserId) {
      throw StateError('cannot friend yourself');
    }
    if (_isBlocked(me.userId, otherUserId)) {
      throw StateError('a block prevents this request');
    }
    final pair = _pair(me.userId, otherUserId);
    var row = _friendships.firstWhereOrNull(
      (f) => f.userA == pair.a && f.userB == pair.b,
    );
    if (row != null) return row.friendshipId;
    row = _MockFriendship(
      friendshipId: _uuid.v4(),
      userA: pair.a,
      userB: pair.b,
      status: 'pending',
      requestedBy: me.userId,
      note: note,
      createdAt: DateTime.now(),
    );
    _friendships.add(row);
    return row.friendshipId;
  }

  Future<void> acceptFriendRequest(String friendshipId) async {
    final me = _me;
    if (me == null) return;
    final row = _friendships.firstWhereOrNull(
      (f) => f.friendshipId == friendshipId,
    );
    if (row == null) return;
    if (row.requestedBy == me.userId) {
      throw StateError('cannot accept your own request');
    }
    if (row.status != 'pending') return;
    row.status = 'accepted';
    row.acceptedAt = DateTime.now();
  }

  Future<void> declineFriendRequest(String friendshipId) async {
    _friendships.removeWhere(
      (f) => f.friendshipId == friendshipId && f.status == 'pending',
    );
  }

  Future<void> unfriend(String otherUserId) async {
    final me = _me;
    if (me == null) return;
    final pair = _pair(me.userId, otherUserId);
    _friendships.removeWhere(
      (f) => f.userA == pair.a && f.userB == pair.b && f.status == 'accepted',
    );
  }

  Future<void> blockUser(String otherUserId, {String? reason}) async {
    final me = _me;
    if (me == null) return;
    if (me.userId == otherUserId) return;
    _blocks.removeWhere(
      (b) => b.blockerId == me.userId && b.blockedId == otherUserId,
    );
    _blocks.add(
      _MockBlock(
        blockerId: me.userId,
        blockedId: otherUserId,
        reason: reason,
        createdAt: DateTime.now(),
      ),
    );
    // Blocks tear down any existing friendship in either status.
    final pair = _pair(me.userId, otherUserId);
    _friendships.removeWhere((f) => f.userA == pair.a && f.userB == pair.b);
  }

  Future<void> unblockUser(String otherUserId) async {
    final me = _me;
    if (me == null) return;
    _blocks.removeWhere(
      (b) => b.blockerId == me.userId && b.blockedId == otherUserId,
    );
  }

  Future<List<FriendSummary>> myFriends() async {
    final me = _me;
    if (me == null) return const [];
    final rows =
        _friendships
            .where(
              (f) =>
                  f.status == 'accepted' &&
                  (f.userA == me.userId || f.userB == me.userId),
            )
            .toList()
          ..sort(
            (a, b) => (b.acceptedAt ?? b.createdAt).compareTo(
              a.acceptedAt ?? a.createdAt,
            ),
          );
    return rows.map((f) {
      final otherId = f.userA == me.userId ? f.userB : f.userA;
      final u = _findUser(otherId);
      return FriendSummary(
        friendshipId: f.friendshipId,
        userId: otherId,
        pseudonym: u?.anonymousPseudonym ?? 'anonymous',
        avatarSeed: u?.avatarSeed ?? 'default-orb',
        karma: 0,
        isVerified: u?.isVerified ?? false,
        acceptedAt: f.acceptedAt ?? f.createdAt,
      );
    }).toList();
  }

  Future<List<FriendRequest>> incomingFriendRequests() async {
    final me = _me;
    if (me == null) return const [];
    final rows =
        _friendships
            .where(
              (f) =>
                  f.status == 'pending' &&
                  (f.userA == me.userId || f.userB == me.userId) &&
                  f.requestedBy != me.userId,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return rows.map((f) {
      final u = _findUser(f.requestedBy);
      return FriendRequest(
        friendshipId: f.friendshipId,
        otherUserId: f.requestedBy,
        otherPseudonym: u?.anonymousPseudonym ?? 'anonymous',
        otherAvatarSeed: u?.avatarSeed ?? 'default-orb',
        profilePhotoUrl: u?.profilePhotoUrl,
        otherKarma: 0,
        note: f.note,
        createdAt: f.createdAt,
        isOutgoing: false,
      );
    }).toList();
  }

  Future<List<FriendRequest>> outgoingFriendRequests() async {
    final me = _me;
    if (me == null) return const [];
    final rows =
        _friendships
            .where(
              (f) =>
                  f.status == 'pending' &&
                  (f.userA == me.userId || f.userB == me.userId) &&
                  f.requestedBy == me.userId,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return rows.map((f) {
      final otherId = f.userA == me.userId ? f.userB : f.userA;
      final u = _findUser(otherId);
      return FriendRequest(
        friendshipId: f.friendshipId,
        otherUserId: otherId,
        otherPseudonym: u?.anonymousPseudonym ?? 'anonymous',
        otherAvatarSeed: u?.avatarSeed ?? 'default-orb',
        profilePhotoUrl: u?.profilePhotoUrl,
        otherKarma: 0,
        note: f.note,
        createdAt: f.createdAt,
        isOutgoing: true,
      );
    }).toList();
  }

  // ──────────────────── Plugz Creator Studio (mock) ────────────────────

  final Map<String, List<String>> _pinnedByTribe = {};
  final Map<String, List<ScheduledPrompt>> _promptsByTribe = {};
  final Map<String, ({String? welcome, String? theme})> _brandingByTribe = {};

  Future<TribeStudioStats?> tribeStudioStats(String tribeId) async {
    final t = _tribes.firstWhereOrNull((x) => x.tribeId == tribeId);
    if (t == null) return null;
    final posts = _posts.where((p) => p.tribeId == tribeId).toList();
    final since7d = DateTime.now().subtract(const Duration(days: 7));
    final since24h = DateTime.now().subtract(const Duration(hours: 24));
    return TribeStudioStats(
      tribeId: tribeId,
      memberCount: t.memberCount,
      members7d: 0,
      members30d: 0,
      posts24h: posts.where((p) => p.createdAt.isAfter(since24h)).length,
      posts7d: posts.where((p) => p.createdAt.isAfter(since7d)).length,
      comments7d: 0,
      activePosters7d: posts
          .where((p) => p.createdAt.isAfter(since7d))
          .map((p) => p.authorId ?? p.authorPseudonym)
          .toSet()
          .length,
      pinnedCount: (_pinnedByTribe[tribeId] ?? const []).length,
      scheduledPrompts: (_promptsByTribe[tribeId] ?? const [])
          .where((p) => p.publishedAt == null)
          .length,
      openReports: 0,
    );
  }

  Future<List<Post>> pinnedPosts(String tribeId) async {
    final ids = _pinnedByTribe[tribeId] ?? const <String>[];
    return [for (final id in ids) ..._posts.where((p) => p.postId == id)];
  }

  Future<void> pinPost(String tribeId, String postId) async {
    final list = _pinnedByTribe.putIfAbsent(tribeId, () => <String>[]);
    if (!list.contains(postId)) list.insert(0, postId);
  }

  Future<void> unpinPost(String tribeId, String postId) async {
    _pinnedByTribe[tribeId]?.remove(postId);
  }

  Future<List<ScheduledPrompt>> tribePrompts(String tribeId) async {
    return List.unmodifiable(_promptsByTribe[tribeId] ?? const []);
  }

  Future<String> schedulePrompt({
    required String tribeId,
    required String text,
    DateTime? scheduledFor,
  }) async {
    final id = _uuid.v4();
    final live = scheduledFor == null || !scheduledFor.isAfter(DateTime.now());
    _promptsByTribe
        .putIfAbsent(tribeId, () => [])
        .add(
          ScheduledPrompt(
            promptId: id,
            tribeId: tribeId,
            text: text,
            answersCount: 0,
            isActive: true,
            scheduledFor: scheduledFor,
            publishedAt: live ? (scheduledFor ?? DateTime.now()) : null,
          ),
        );
    return id;
  }

  Future<void> cancelPrompt(String tribeId, String promptId) async {
    _promptsByTribe[tribeId]?.removeWhere(
      (p) => p.promptId == promptId && p.publishedAt == null,
    );
  }

  Future<void> updatePrompt({
    required String tribeId,
    required String promptId,
    required String text,
    DateTime? scheduledFor,
  }) async {
    final list = _promptsByTribe[tribeId];
    if (list == null) return;
    final i = list.indexWhere((p) => p.promptId == promptId);
    if (i == -1) return;
    final old = list[i];
    list[i] = ScheduledPrompt(
      promptId: old.promptId,
      tribeId: old.tribeId,
      text: text,
      answersCount: old.answersCount,
      isActive: old.isActive,
      scheduledFor: scheduledFor ?? old.scheduledFor,
      publishedAt: old.publishedAt,
    );
  }

  Future<void> deletePrompt(String tribeId, String promptId) async {
    _promptsByTribe[tribeId]?.removeWhere((p) => p.promptId == promptId);
  }

  Future<void> tribeChatHeartbeat(String tribeId) async {}

  Future<List<TribeOnlineMember>> tribeOnlineMembers(String tribeId) async {
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    final me = _me;
    if (me == null) return const [];
    return [
      TribeOnlineMember(
        userId: me.userId,
        pseudonym: me.anonymousPseudonym,
        avatarSeed: me.avatarSeed,
        profilePhotoUrl: me.profilePhotoUrl,
        role: tribe?.keeperId == me.userId ? 'keeper' : 'member',
        isOnline: true,
      ),
    ];
  }

  Future<void> setTribeAvatar({
    required String tribeId,
    required String avatarUrl,
  }) async {
    final i = _tribes.indexWhere((t) => t.tribeId == tribeId);
    if (i == -1) return;
    _tribes[i] = _tribes[i].copyWith(avatarUrl: avatarUrl);
  }

  Future<({String path, String url})> uploadTribeAvatar({
    required String tribeId,
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) async {
    return (path: 'mock/tribe/$tribeId.jpg', url: 'mock://tribe/$tribeId.jpg');
  }

  Future<({String path, String url})> uploadTribeChatAudio({
    required List<int> bytes,
    String extension = 'm4a',
    String contentType = 'audio/mp4',
  }) async {
    return (path: 'mock/chat.m4a', url: 'mock://chat.m4a');
  }

  Future<void> setTribeChatSettings({
    required String tribeId,
    required Map<String, dynamic> patch,
  }) async {}

  void broadcastTribeTyping(String tribeId, {required String pseudonym}) {}

  Stream<List<TribeTypingUser>> watchTribeTyping(String tribeId) =>
      const Stream.empty();

  Future<void> setTribeBranding({
    required String tribeId,
    String? welcomeMessage,
    String? themeColor,
  }) async {
    _brandingByTribe[tribeId] = (welcome: welcomeMessage, theme: themeColor);
  }

  Future<void> spotlightMember({
    required String tribeId,
    required String? userId,
    String? note,
  }) async {
    // No-op in mock; the directory list isn't keeper-aware enough to
    // surface a spotlight without restructuring the seed data.
  }

  Future<UserProfileView?> userProfile(String otherUserId) async {
    final me = _me;
    if (me == null) return null;
    final u = _findUser(otherUserId);
    if (u == null) return null;
    final relation = await friendStatus(otherUserId);
    final theirPosts = _posts.where((p) => p.authorId == otherUserId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final theirTribesIds = _joinedTribes; // mock doesn't track per-user

    // Mutual tribes: joined by me intersected with target's. Mock doesn't
    // model per-user memberships beyond _joinedTribes, so we treat both
    // sides as the current viewer's joined set for a plausible-looking
    // dev experience.
    final mutualTribesList = _tribes
        .where((t) => theirTribesIds.contains(t.tribeId))
        .map((t) => MutualTribe(tribeId: t.tribeId, name: t.name, slug: t.slug))
        .toList();

    final isFriend =
        relation == FriendStatus.friends || relation == FriendStatus.self;

    final moodCounts = <String, int>{};
    for (final p in theirPosts) {
      moodCounts[p.postMood] = (moodCounts[p.postMood] ?? 0) + 1;
    }
    final topMoods =
        moodCounts.entries
            .map((e) => MoodCount(mood: e.key, count: e.value))
            .toList()
          ..sort((a, b) => b.count.compareTo(a.count));

    final mostLiked = theirPosts.isEmpty
        ? null
        : (theirPosts.toList()
                ..sort((a, b) => b.likesCount.compareTo(a.likesCount)))
              .first;
    final mostCommented = theirPosts.isEmpty
        ? null
        : (theirPosts.toList()
                ..sort((a, b) => b.commentsCount.compareTo(a.commentsCount)))
              .first;
    ProfileHighlightPost? toHl(Post? p) => p == null
        ? null
        : ProfileHighlightPost(
            postId: p.postId,
            content: p.content,
            likes: p.likesCount,
            comments: p.commentsCount,
            createdAt: p.createdAt,
            category: p.categoryName,
            mood: p.postMood,
            crisisLevel: p.crisisLevel,
          );

    return UserProfileView(
      relation: relation,
      userId: u.userId,
      pseudonym: u.anonymousPseudonym,
      avatarSeed: u.avatarSeed,
      profilePhotoUrl: u.profilePhotoUrl,
      karma: 0,
      isVerified: u.isVerified,
      // Mock users don't carry a joined-at; pin to today for plausibility.
      joinedAt: DateTime.now().subtract(const Duration(days: 7)),
      currentMood: u.currentMood,
      accountStatus: 'active',
      safetyTier: 'standard',
      vents: theirPosts.length,
      comments: isFriend ? 0 : null,
      reactionsReceived: isFriend
          ? theirPosts.fold<int>(0, (s, p) => s + p.likesCount)
          : null,
      activeTribes: mutualTribesList.length,
      badgesCount: isFriend ? 0 : null,
      currentStreak: isFriend ? 0 : null,
      bestStreak: isFriend ? 0 : null,
      topMoods: isFriend ? topMoods.take(5).toList() : const [],
      mutualFriendsCount: 0,
      mutualFriendSample: const [],
      mutualTribes: mutualTribesList,
      mostLiked: isFriend ? toHl(mostLiked) : null,
      mostCommented: isFriend ? toHl(mostCommented) : null,
      recentPosts: isFriend
          ? theirPosts.take(6).map((p) => toHl(p)!).toList()
          : const [],
      badges: const [],
    );
  }

  Future<List<BlockedUser>> myBlocks() async {
    final me = _me;
    if (me == null) return const [];
    return _blocks.where((b) => b.blockerId == me.userId).map((b) {
      final u = _findUser(b.blockedId);
      return BlockedUser(
        userId: b.blockedId,
        pseudonym: u?.anonymousPseudonym ?? 'anonymous',
        avatarSeed: u?.avatarSeed ?? 'default-orb',
        reason: b.reason,
        createdAt: b.createdAt,
      );
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<bool> toggleCommentLike(String commentId) async {
    for (final tree in _commentsByPost.values) {
      if (_swapLike(tree, commentId)) {
        final n = _findInTree(tree, commentId);
        return n?.likedByMe ?? false;
      }
    }
    return false;
  }

  bool _swapLike(List<ThreadedComment> siblings, String id) {
    for (var i = 0; i < siblings.length; i++) {
      final n = siblings[i];
      if (n.commentId == id) {
        if (n.ownedBy(_me?.userId)) {
          throw StateError('self_interaction_not_allowed');
        }
        final next = !n.likedByMe;
        siblings[i] = n.copyWith(
          likedByMe: next,
          likesCount: next
              ? n.likesCount + 1
              : (n.likesCount - 1).clamp(0, 1 << 30),
        );
        return true;
      }
      if (_swapLike(n.children, id)) return true;
    }
    return false;
  }

  // -------------------- Plugz (read-only metadata) --------------------
  List<PlugProfile> allPlugz() => List.unmodifiable(_plugz);

  PlugProfile? plugByDisplayName(String name) =>
      _plugz.firstWhereOrNull((p) => p.displayName == name);

  // -------------------- Tribes --------------------
  bool joinedTribe(String tribeId) => _joinedTribes.contains(tribeId);

  List<Tribe> tribes({String? category, String? search}) {
    final q = search?.trim().toLowerCase();
    return _tribes
        .where((t) => category == null || t.category == category)
        .where(
          (t) => q == null || q.isEmpty || t.name.toLowerCase().contains(q),
        )
        .map((t) => t.copyWith(joinedByMe: _joinedTribes.contains(t.tribeId)))
        .toList()
      ..sort((a, b) => b.memberCount.compareTo(a.memberCount));
  }

  List<Tribe> tribesByKeeper(String keeperId) {
    return _tribes
        .where((t) => t.keeperId == keeperId)
        .map((t) => t.copyWith(joinedByMe: _joinedTribes.contains(t.tribeId)))
        .toList()
      ..sort((a, b) => b.memberCount.compareTo(a.memberCount));
  }

  List<Tribe> tribesIKeep() {
    final me = _me;
    if (me == null) return const [];
    return tribesByKeeper(me.userId);
  }

  KeeperMode keeperMode() {
    final me = _me;
    if (me == null) return KeeperMode.guest();
    final kept = tribesByKeeper(me.userId).length;
    final isKeeper = me.isPlug || kept > 0;
    String displayRole = 'member';
    if (me.userRole == 'super_admin') {
      displayRole = 'super_admin';
    } else if (me.isPlug) {
      displayRole = 'plug';
    } else if (kept > 0) {
      displayRole = 'keeper';
    }
    return KeeperMode(
      isKeeper: isKeeper,
      displayRole: displayRole,
      userRole: me.userRole,
      tribesKept: kept,
    );
  }

  KeeperModerationQueue keeperModerationQueue(String tribeId) {
    return const KeeperModerationQueue(
      items: [],
      keywordFilterCount: 2,
      warnings30d: 0,
    );
  }

  KeeperEngagementCalendar keeperEngagementCalendar(String tribeId) {
    final now = DateTime.now();
    return KeeperEngagementCalendar(
      scheduled: [
        KeeperCalendarPrompt(
          promptId: 'mock-prompt-1',
          promptText: 'What felt heavy before breakfast today?',
          scheduledFor: now.add(const Duration(days: 1)),
        ),
      ],
      recentPublished: [
        KeeperCalendarPrompt(
          promptId: 'mock-prompt-0',
          promptText: 'One small win from this week?',
          publishedAt: now.subtract(const Duration(days: 3)),
        ),
      ],
      suggestions: const [
        KeeperCalendarSuggestion(
          title: 'Morning check-in',
          slot: 'weekday_morning',
          hint: 'Post a gentle prompt before 9am local.',
        ),
      ],
    );
  }

  KeeperAiInsights keeperAiInsights(String tribeId) {
    return const KeeperAiInsights(
      healthScore: 78,
      safetyScore: 92,
      retentionLabel: 'stable',
      moodTrends: [
        KeeperMoodTrend(mood: 'healing', count: 12),
        KeeperMoodTrend(mood: 'hopeful', count: 8),
      ],
      insights: [
        KeeperAiInsight(
          kind: 'engagement',
          severity: 'medium',
          title: 'Posting pace is quiet',
          body: 'Try a scheduled prompt this week.',
          action: 'calendar',
        ),
      ],
    );
  }

  KeeperComodMatrix keeperComodMatrix(String tribeId) {
    final me = _me;
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    final rows = <KeeperComodRow>[];
    if (tribe?.keeperId != null) {
      final keeper = _users.firstWhereOrNull(
        (u) => u.userId == tribe!.keeperId,
      );
      if (keeper != null) {
        rows.add(
          KeeperComodRow(
            userId: keeper.userId,
            pseudonym: keeper.anonymousPseudonym,
            avatarSeed: keeper.avatarSeed,
            role: 'keeper',
            canPromote: true,
            canWarn: true,
            canReviewReports: true,
            canPin: true,
            canSchedule: true,
            canKickMods: true,
            canKickMembers: true,
            joinedAt: DateTime.now().subtract(const Duration(days: 30)),
          ),
        );
      }
    }
    return KeeperComodMatrix(
      mods: rows,
      callerIsKeeper: me?.userId == tribe?.keeperId,
    );
  }

  KeeperExportReport keeperExportReport(String tribeId) {
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    final name = tribe?.name ?? 'Tribe';
    final slug = tribe?.slug ?? 'tribe';
    final now = DateTime.now().toUtc();
    return KeeperExportReport(
      format: 'markdown',
      tribeName: name,
      tribeSlug: slug,
      generatedAt: now,
      markdown:
          '# $name Studio Report\n\nGenerated: ${now.toIso8601String()}\n\n## Snapshot\n- Members: ${tribe?.memberCount ?? 0}\n',
    );
  }

  List<Post> postsByKeeper(String keeperId, {int limit = 20, int offset = 0}) {
    final slugs = _tribes
        .where((t) => t.keeperId == keeperId)
        .map((t) => t.slug)
        .toSet();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final filtered =
        _posts
            .where(
              (p) =>
                  p.tribeSlug != null &&
                  slugs.contains(p.tribeSlug) &&
                  (!p.isWhisper || p.createdAt.isAfter(cutoff)),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered.skip(offset).take(limit).toList();
  }

  Tribe? tribeBySlug(String slug) {
    final t = _tribes.firstWhereOrNull((t) => t.slug == slug);
    return t?.copyWith(joinedByMe: _joinedTribes.contains(t.tribeId));
  }

  Tribe createTribe({
    required String name,
    required String category,
    String? description,
    bool isPrivate = false,
    List<String> tags = const [],
    String? visibility,
    String? welcomeMessage,
    TribeGovernanceSettings settings = const TribeGovernanceSettings(),
    List<TribeRuleItem> rules = const [],
  }) {
    final me = _me;
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final t = Tribe(
      tribeId: _uuid.v4(),
      name: name,
      slug: slug,
      description: description,
      category: category,
      memberCount: 1,
      isPrivate: isPrivate,
      visibility: visibility ?? (isPrivate ? 'private' : 'public'),
      tags: tags,
      welcomeMessage: welcomeMessage,
      managementSettings: settings.toJson(),
      createdAt: DateTime.now(),
      keeperId: me?.userId,
      keeperPseudonym: me?.anonymousPseudonym,
      keeperAvatarSeed: me?.avatarSeed,
      keeperIsVerified: me?.isVerified ?? false,
      joinedByMe: true,
    );
    _tribes.add(t);
    _ensureDefaultSpace(t);
    _joinedTribes.add(t.tribeId);
    _managementRules[t.tribeId] = rules;
    return t;
  }

  void joinTribe(String tribeId) {
    final i = _tribes.indexWhere((t) => t.tribeId == tribeId);
    if (i == -1) return;
    if (_joinedTribes.contains(tribeId)) return;
    _joinedTribes.add(tribeId);
    _tribes[i] = _tribes[i].copyWith(
      memberCount: _tribes[i].memberCount + 1,
      joinedByMe: true,
    );
  }

  void leaveTribe(String tribeId) {
    final i = _tribes.indexWhere((t) => t.tribeId == tribeId);
    if (i == -1) return;
    if (!_joinedTribes.contains(tribeId)) return;
    _joinedTribes.remove(tribeId);
    _tribes[i] = _tribes[i].copyWith(
      memberCount: max(_tribes[i].memberCount - 1, 0),
      joinedByMe: false,
    );
  }

  // -------------------- Chat / Inbox --------------------
  List<ChatRoom> inbox({required String tab}) {
    ChatRoom enrich(ChatRoom room) {
      final msgs = _messages[room.roomId] ?? const <ChatMessage>[];
      final unread = msgs
          .where((m) => !m.sentByMe && m.readAt == null && m.deletedAt == null)
          .length;
      final visible = msgs
          .where((m) => m.deletedAt == null)
          .toList(growable: false);
      final last = visible.isEmpty ? null : visible.last;
      final own = visible.where((m) => m.sentByMe).toList();
      final lastOwn = own.isEmpty ? null : own.last;
      return ChatRoom(
        roomId: room.roomId,
        peerPseudonym: room.peerPseudonym,
        peerAvatarSeed: room.peerAvatarSeed,
        peerProfilePhotoUrl: room.peerProfilePhotoUrl,
        requestPreview: room.requestPreview,
        roomStatus: room.roomStatus,
        createdAt: room.createdAt,
        initiatedByMe: room.initiatedByMe,
        unreadCount: unread,
        lastMessagePreview: last?.plaintext,
        lastMessageAt: last?.createdAt,
        lastOwnMessageRead: lastOwn?.readAt != null,
        peerUserId: room.peerUserId,
        isGroup: room.isGroup,
        groupTitle: room.groupTitle,
        memberCount: room.memberCount,
        groupAvatarPath: room.groupAvatarPath,
        groupInviteToken: room.groupInviteToken,
        groupInviteEnabled: room.groupInviteEnabled,
        groupAllowMemberInvites: room.groupAllowMemberInvites,
        isGroupOwner: room.isGroupOwner,
      );
    }

    return _rooms
        .where((r) {
          if (tab == 'requests') return r.roomStatus == 'pending_request';
          if (tab == 'active') return r.roomStatus == 'active';
          return true;
        })
        .map(enrich)
        .toList()
      ..sort(
        (a, b) => (b.lastMessageAt ?? b.createdAt).compareTo(
          a.lastMessageAt ?? a.createdAt,
        ),
      );
  }

  ChatRoom acceptRequest(String roomId) {
    final i = _rooms.indexWhere((r) => r.roomId == roomId);
    if (i == -1) throw StateError('Room not found');
    final room = _rooms[i];
    final updated = ChatRoom(
      roomId: room.roomId,
      peerPseudonym: room.peerPseudonym,
      peerAvatarSeed: room.peerAvatarSeed,
      peerProfilePhotoUrl: room.peerProfilePhotoUrl,
      requestPreview: room.requestPreview,
      roomStatus: 'active',
      createdAt: room.createdAt,
      initiatedByMe: room.initiatedByMe,
    );
    _rooms[i] = updated;
    _messages.putIfAbsent(
      roomId,
      () => [
        ChatMessage(
          messageId: _uuid.v4(),
          roomId: roomId,
          senderId: 'peer',
          plaintext: room.requestPreview,
          createdAt: room.createdAt,
          sentByMe: false,
        ),
      ],
    );
    _emitRooms();
    return updated;
  }

  void declineRequest(String roomId) {
    final i = _rooms.indexWhere((r) => r.roomId == roomId);
    if (i == -1) return;
    final r = _rooms[i];
    _rooms[i] = ChatRoom(
      roomId: r.roomId,
      peerPseudonym: r.peerPseudonym,
      peerAvatarSeed: r.peerAvatarSeed,
      peerProfilePhotoUrl: r.peerProfilePhotoUrl,
      requestPreview: r.requestPreview,
      roomStatus: 'declined',
      createdAt: r.createdAt,
      initiatedByMe: r.initiatedByMe,
    );
    _emitRooms();
  }

  final Set<String> _hiddenChatMessageIds = <String>{};

  List<ChatMessage> roomMessages(String roomId) =>
      (_messages[roomId] ?? const <ChatMessage>[])
          .where(
            (message) => !_hiddenChatMessageIds.contains(message.messageId),
          )
          .toList(growable: false);

  ChatRoom sendMessageRequest({
    required String peerPseudonym,
    required String peerAvatarSeed,
    required String preview,
  }) {
    final r = ChatRoom(
      roomId: _uuid.v4(),
      peerPseudonym: peerPseudonym,
      peerAvatarSeed: peerAvatarSeed,
      requestPreview: preview,
      roomStatus: 'pending_request',
      createdAt: DateTime.now(),
      initiatedByMe: true,
    );
    _rooms.add(r);
    _emitRooms();
    return r;
  }

  ChatRoom createGroupChat({
    required String title,
    required String friendUserId,
    required String friendPseudonym,
    required String friendAvatarSeed,
    List<String> additionalMemberUserIds = const [],
  }) {
    final cleanTitle = title.trim();
    if (cleanTitle.length < 2 || cleanTitle.length > 80) {
      throw ArgumentError('Group name must be 2 to 80 characters.');
    }
    final room = ChatRoom(
      roomId: _uuid.v4(),
      peerPseudonym: cleanTitle,
      peerAvatarSeed: 'group-$friendAvatarSeed',
      peerUserId: null,
      requestPreview: 'Private group with @$friendPseudonym',
      roomStatus: 'active',
      createdAt: DateTime.now(),
      initiatedByMe: true,
      isGroup: true,
      groupTitle: cleanTitle,
      memberCount: 2 + additionalMemberUserIds.length,
      groupInviteToken: _uuid.v4(),
      groupInviteEnabled: true,
      groupAllowMemberInvites: true,
      isGroupOwner: true,
    );
    _rooms.add(room);
    _messages[room.roomId] = const [];
    final me = _me;
    final friend = _users.firstWhereOrNull((u) => u.userId == friendUserId);
    final additional = additionalMemberUserIds
        .map((id) => _users.firstWhereOrNull((u) => u.userId == id))
        .whereType<AppUser>();
    _groupMembers[room.roomId] = [
      if (me != null)
        GroupChatMember(
          userId: me.userId,
          pseudonym: me.anonymousPseudonym,
          avatarSeed: me.avatarSeed,
          profilePhotoUrl: me.profilePhotoUrl,
          isVerified: me.isVerified,
          memberRole: 'owner',
          joinedAt: DateTime.now(),
          isMe: true,
        ),
      GroupChatMember(
        userId: friendUserId,
        pseudonym: friend?.anonymousPseudonym ?? friendPseudonym,
        avatarSeed: friend?.avatarSeed ?? friendAvatarSeed,
        profilePhotoUrl: friend?.profilePhotoUrl,
        isVerified: friend?.isVerified ?? false,
        memberRole: 'member',
        joinedAt: DateTime.now(),
        isMe: false,
      ),
      for (final user in additional)
        GroupChatMember(
          userId: user.userId,
          pseudonym: user.anonymousPseudonym,
          avatarSeed: user.avatarSeed,
          profilePhotoUrl: user.profilePhotoUrl,
          isVerified: user.isVerified,
          memberRole: 'member',
          joinedAt: DateTime.now(),
          isMe: false,
        ),
    ];
    _emitRooms();
    return room;
  }

  List<GroupChatMember> groupChatMembers(String roomId) =>
      List.unmodifiable(_groupMembers[roomId] ?? const []);

  int addGroupChatMembers(String roomId, List<String> memberUserIds) {
    final members = _groupMembers.putIfAbsent(roomId, () => []);
    var added = 0;
    for (final id in memberUserIds.toSet()) {
      if (members.any((m) => m.userId == id)) continue;
      final user = _users.firstWhereOrNull((u) => u.userId == id);
      if (user == null) continue;
      members.add(
        GroupChatMember(
          userId: user.userId,
          pseudonym: user.anonymousPseudonym,
          avatarSeed: user.avatarSeed,
          profilePhotoUrl: user.profilePhotoUrl,
          isVerified: user.isVerified,
          memberRole: 'member',
          joinedAt: DateTime.now(),
          isMe: user.userId == _me?.userId,
        ),
      );
      added++;
    }
    _syncMockGroupCount(roomId);
    return added;
  }

  bool removeGroupChatMember(String roomId, String userId) {
    final members = _groupMembers[roomId];
    if (members == null) return false;
    final before = members.length;
    members.removeWhere((m) => m.userId == userId && !m.isOwner);
    _syncMockGroupCount(roomId);
    return members.length != before;
  }

  bool leaveGroupChat(String roomId) {
    final me = _me?.userId;
    if (me == null) return false;
    final members = _groupMembers[roomId];
    if (members == null) return false;
    final before = members.length;
    members.removeWhere((m) => m.userId == me);
    _rooms.removeWhere((room) => room.roomId == roomId);
    _emitRooms();
    return members.length != before;
  }

  ChatRoom updateGroupChatIdentity(
    String roomId, {
    String? title,
    String? avatarPath,
    bool clearAvatar = false,
  }) {
    final index = _rooms.indexWhere((room) => room.roomId == roomId);
    if (index < 0) throw StateError('Group not found');
    final room = _rooms[index];
    final next = _copyGroupRoom(
      room,
      title: title,
      avatarPath: clearAvatar ? null : (avatarPath ?? room.groupAvatarPath),
      replaceAvatar: clearAvatar || avatarPath != null,
    );
    _rooms[index] = next;
    _emitRooms();
    return next;
  }

  bool setGroupChatNickname(String roomId, String nickname) {
    final members = _groupMembers[roomId];
    final me = _me?.userId;
    if (members == null || me == null) return false;
    final index = members.indexWhere((m) => m.userId == me);
    if (index < 0) return false;
    final current = members[index];
    members[index] = GroupChatMember(
      userId: current.userId,
      pseudonym: current.pseudonym,
      avatarSeed: current.avatarSeed,
      profilePhotoUrl: current.profilePhotoUrl,
      isVerified: current.isVerified,
      memberRole: current.memberRole,
      nickname: nickname.trim().isEmpty ? null : nickname.trim(),
      joinedAt: current.joinedAt,
      isMe: current.isMe,
    );
    return true;
  }

  bool setGroupChatPrivacy(
    String roomId, {
    bool? allowMemberInvites,
    bool? inviteEnabled,
  }) {
    final index = _rooms.indexWhere((room) => room.roomId == roomId);
    if (index < 0) return false;
    final room = _rooms[index];
    _rooms[index] = _copyGroupRoom(
      room,
      allowMemberInvites: allowMemberInvites ?? room.groupAllowMemberInvites,
      inviteEnabled: inviteEnabled ?? room.groupInviteEnabled,
    );
    _emitRooms();
    return true;
  }

  String regenerateGroupInvite(String roomId) {
    final index = _rooms.indexWhere((room) => room.roomId == roomId);
    if (index < 0) throw StateError('Group not found');
    final token = _uuid.v4();
    _rooms[index] = _copyGroupRoom(
      _rooms[index],
      inviteToken: token,
      inviteEnabled: true,
    );
    _emitRooms();
    return token;
  }

  GroupInvitePreview? groupInvitePreview(String token) {
    final room = _rooms.firstWhereOrNull(
      (r) => r.isGroup && r.groupInviteEnabled && r.groupInviteToken == token,
    );
    if (room == null) return null;
    return GroupInvitePreview(
      roomId: room.roomId,
      title: room.groupTitle ?? room.peerPseudonym,
      avatarPath: room.groupAvatarPath,
      memberCount: room.memberCount,
    );
  }

  String joinGroupChatByInvite(String token) {
    final preview = groupInvitePreview(token);
    if (preview == null) throw StateError('Invite not found');
    return preview.roomId;
  }

  void _syncMockGroupCount(String roomId) {
    final index = _rooms.indexWhere((room) => room.roomId == roomId);
    if (index < 0) return;
    _rooms[index] = _copyGroupRoom(
      _rooms[index],
      memberCount: _groupMembers[roomId]?.length ?? 0,
    );
    _emitRooms();
  }

  ChatRoom _copyGroupRoom(
    ChatRoom room, {
    String? title,
    String? avatarPath,
    bool replaceAvatar = false,
    String? inviteToken,
    bool? inviteEnabled,
    bool? allowMemberInvites,
    int? memberCount,
  }) {
    final nextTitle = title?.trim().isNotEmpty == true
        ? title!.trim()
        : (room.groupTitle ?? room.peerPseudonym);
    return ChatRoom(
      roomId: room.roomId,
      peerPseudonym: nextTitle,
      peerAvatarSeed: room.peerAvatarSeed,
      peerProfilePhotoUrl: room.peerProfilePhotoUrl,
      peerUserId: room.peerUserId,
      requestPreview: room.requestPreview,
      roomStatus: room.roomStatus,
      createdAt: room.createdAt,
      initiatedByMe: room.initiatedByMe,
      unreadCount: room.unreadCount,
      lastMessagePreview: room.lastMessagePreview,
      lastMessageAt: room.lastMessageAt,
      lastOwnMessageRead: room.lastOwnMessageRead,
      isGroup: true,
      groupTitle: nextTitle,
      memberCount: memberCount ?? room.memberCount,
      groupAvatarPath: replaceAvatar ? avatarPath : room.groupAvatarPath,
      groupInviteToken: inviteToken ?? room.groupInviteToken,
      groupInviteEnabled: inviteEnabled ?? room.groupInviteEnabled,
      groupAllowMemberInvites:
          allowMemberInvites ?? room.groupAllowMemberInvites,
      isGroupOwner: room.isGroupOwner,
    );
  }

  // No-ops for typing indicators in mock — broadcast lives on Supabase.
  void broadcastTyping(String roomId) {}
  Stream<bool> watchTyping(String roomId) => Stream<bool>.value(false);

  /// Toggle/swap/clear a reaction on a message in-memory. Mirrors the
  /// `set_chat_message_reaction` RPC semantic so the dev experience
  /// matches the live one when both are loaded.
  Future<String?> setMessageReaction(String messageId, String? reaction) async {
    for (final list in _messages.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].messageId != messageId) continue;
        final m = list[i];
        final counts = Map<String, int>.from(m.reactionCounts);
        // Clear existing
        if (m.myReaction != null) {
          counts[m.myReaction!] = (counts[m.myReaction!] ?? 1) - 1;
          if ((counts[m.myReaction!] ?? 0) <= 0) counts.remove(m.myReaction!);
        }
        String? next;
        if (reaction != null && reaction != m.myReaction) {
          counts[reaction] = (counts[reaction] ?? 0) + 1;
          next = reaction;
        }
        list[i] = m.copyWith(reactionCounts: counts, myReaction: next);
        _emitRooms();
        return next;
      }
    }
    return null;
  }

  bool editChatMessage({
    required String messageId,
    required String newPlaintext,
  }) {
    final next = newPlaintext.trim();
    if (next.isEmpty || next.length > 4000) return false;
    for (final messages in _messages.values) {
      final index = messages.indexWhere((item) => item.messageId == messageId);
      if (index < 0) continue;
      final current = messages[index];
      if (!current.canEdit) return false;
      messages[index] = current.copyWith(
        plaintext: next,
        editedAt: DateTime.now(),
      );
      _emitRooms();
      return true;
    }
    return false;
  }

  bool deleteChatMessage(String messageId) {
    for (final messages in _messages.values) {
      final index = messages.indexWhere((item) => item.messageId == messageId);
      if (index < 0) continue;
      final current = messages[index];
      if (!current.canDeleteForEveryone) return false;
      messages[index] = current.copyWith(
        plaintext: '',
        deletedAt: DateTime.now(),
      );
      _emitRooms();
      return true;
    }
    return false;
  }

  bool hideChatMessage(String messageId) {
    final exists = _messages.values.any(
      (messages) => messages.any((item) => item.messageId == messageId),
    );
    if (!exists) return false;
    _hiddenChatMessageIds.add(messageId);
    _emitRooms();
    return true;
  }

  Future<int> markRoomRead(String roomId) async {
    final msgs = _messages[roomId];
    if (msgs == null) return 0;
    var count = 0;
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (!m.sentByMe && m.readAt == null) {
        msgs[i] = ChatMessage(
          messageId: m.messageId,
          roomId: m.roomId,
          senderId: m.senderId,
          plaintext: m.plaintext,
          createdAt: m.createdAt,
          sentByMe: m.sentByMe,
          attachedPostId: m.attachedPostId,
          attachedPostSnapshot: m.attachedPostSnapshot,
          readAt: DateTime.now(),
        );
        count++;
      }
    }
    return count;
  }

  Future<int> unreadChatMessageCount() async {
    var count = 0;
    for (final msgs in _messages.values) {
      for (final m in msgs) {
        if (!m.sentByMe && m.readAt == null && m.deletedAt == null) {
          count++;
        }
      }
    }
    return count;
  }

  // Image uploads in the mock just hand back a deterministic placeholder
  // URL — there's no real bucket. Bubble UI renders a "preview" stub.
  Future<({String path, String messageId})> uploadChatImage({
    required String roomId,
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) async {
    final messageId = _uuid.v4();
    return (path: '$roomId/$messageId.$extension', messageId: messageId);
  }

  Future<String> chatImageSignedUrl(String path) async {
    return 'mock://chat-media/$path';
  }

  ChatMessage sendMessage({
    required String roomId,
    required String plaintext,
    String? attachedPostId,
    String? attachedMediaPath,
    String? attachedMediaType,
  }) {
    SharedPostSnapshot? snapshot;
    if (attachedPostId != null) {
      final p = _posts.firstWhereOrNull((x) => x.postId == attachedPostId);
      if (p != null) {
        snapshot = SharedPostSnapshot(
          postId: p.postId,
          content: p.content,
          authorPseudonym: p.authorPseudonym,
          authorDisplayName: p.authorDisplayName,
          authorAvatarSeed: p.authorAvatarSeed,
          category: p.categoryName,
          mood: p.postMood,
          isWhisper: p.isWhisper,
          createdAt: p.createdAt,
        );
      }
    }
    final msg = ChatMessage(
      messageId: _uuid.v4(),
      roomId: roomId,
      senderId: 'me',
      plaintext: plaintext,
      createdAt: DateTime.now(),
      sentByMe: true,
      attachedPostId: attachedPostId,
      attachedPostSnapshot: snapshot,
      attachedMediaPath: attachedMediaPath,
      attachedMediaType: attachedMediaType,
    );
    _messages.putIfAbsent(roomId, () => []).add(msg);
    // Add a soft auto-reply so the conversation breathes.
    Future.delayed(const Duration(seconds: 2), () {
      final reply = ChatMessage(
        messageId: _uuid.v4(),
        roomId: roomId,
        senderId: 'peer',
        plaintext: _softReply(),
        createdAt: DateTime.now(),
        sentByMe: false,
      );
      _messages[roomId]?.add(reply);
    });
    return msg;
  }

  String _softReply() {
    const replies = [
      'I hear you. Take a deep breath with me.',
      "Thank you for trusting me with that. You're not alone.",
      "That's exhausting. What helps you feel a little lighter?",
      "Sending you so much warmth tonight.",
    ];
    return replies[_rng.nextInt(replies.length)];
  }

  // -------------------- Prompts --------------------
  List<PlugPrompt> prompts() => List.unmodifiable(_prompts);

  final Map<String, List<PromptAnswer>> _promptAnswers = {};

  List<PromptAnswer> promptAnswers(String promptId) =>
      List.unmodifiable(_promptAnswers[promptId] ?? const []);

  PromptAnswer addPromptAnswer({
    required String promptId,
    required String text,
  }) {
    final me = _me;
    final a = PromptAnswer(
      answerId: _uuid.v4(),
      promptId: promptId,
      authorId: me?.userId,
      authorPseudonym: '@${me?.anonymousPseudonym ?? 'anonymous'}',
      authorDisplayName: me?.displayName,
      authorAvatarSeed: me?.avatarSeed ?? 'default-orb',
      authorProfilePhotoUrl: me?.profilePhotoUrl,
      text: text,
      createdAt: DateTime.now(),
    );
    _promptAnswers.putIfAbsent(promptId, () => []).insert(0, a);
    final i = _prompts.indexWhere((p) => p.promptId == promptId);
    if (i != -1) {
      _prompts[i] = PlugPrompt(
        promptId: _prompts[i].promptId,
        plugDisplayName: _prompts[i].plugDisplayName,
        plugAvatarSeed: _prompts[i].plugAvatarSeed,
        promptText: _prompts[i].promptText,
        answersCount: _prompts[i].answersCount + 1,
      );
    }
    return a;
  }

  // -------------------- Notifications --------------------
  List<NotificationItem> notifications() => List.unmodifiable(_notifications);

  void markNotificationRead(String id) {
    final i = _notifications.indexWhere((n) => n.id == id);
    if (i == -1 || _notifications[i].isRead) return;
    final n = _notifications[i];
    _notifications[i] = NotificationItem(
      id: n.id,
      kind: n.kind,
      title: n.title,
      body: n.body,
      createdAt: n.createdAt,
      isRead: true,
    );
  }

  void markAllNotificationsRead() {
    for (var i = 0; i < _notifications.length; i++) {
      if (_notifications[i].isRead) continue;
      final n = _notifications[i];
      _notifications[i] = NotificationItem(
        id: n.id,
        kind: n.kind,
        title: n.title,
        body: n.body,
        createdAt: n.createdAt,
        isRead: true,
      );
    }
  }

  // -------------------- Internal helpers --------------------
  void _emitAll() {
    _emitPosts();
    _emitRooms();
    _notificationsController.add(_notifications);
  }

  void _emitPosts() {
    final view = _posts
        .map(
          (p) => p.copyWith(
            myReaction: _myReactions[p.postId],
            savedByMe: _savedPosts.contains(p.postId),
          ),
        )
        .toList();
    _postsController.add(view);
  }

  void _emitRooms() {
    _roomsController.add(List.unmodifiable(_rooms));
  }

  // ---------------------------------------------------------------
  // Seed data — mirrors `supabase/seed/seed_demo.sql`
  // ---------------------------------------------------------------
  void _seed() {
    final patrick = PlugProfile(
      plugId: _uuid.v4(),
      displayName: '@PatrickO',
      bio: 'Community Plug | Kigali. Holding space for big feelings.',
      locationLabel: 'Kigali, Rwanda',
      tribeCount: 750000,
      avatarSeed: 'plum-orb-0001',
    );
    final healing = PlugProfile(
      plugId: _uuid.v4(),
      displayName: '@HealingCoach',
      bio: 'Daily gentle reminders. We rise softly.',
      locationLabel: 'Online',
      tribeCount: 212000,
      avatarSeed: 'rose-leaf-0042',
    );
    final campus = PlugProfile(
      plugId: _uuid.v4(),
      displayName: '@CampusCircle',
      bio: 'Kigali Tech Confessions. Vent. Heal. Belong.',
      locationLabel: 'Kigali, Rwanda',
      tribeCount: 45000,
      avatarSeed: 'berry-spark-0098',
    );
    _plugz.addAll([patrick, healing, campus]);

    final now0 = DateTime.now();
    _tribes.addAll([
      Tribe(
        tribeId: _uuid.v4(),
        name: 'University of Rwanda',
        slug: 'university-of-rwanda',
        description: 'The official emotional sanctuary for UR students.',
        category: 'campus',
        memberCount: 4209,
        isPrivate: false,
        createdAt: now0.subtract(const Duration(days: 90)),
        keeperPseudonym: 'CampusCircle',
        keeperAvatarSeed: 'berry-spark-0098',
        keeperIsVerified: true,
      ),
      Tribe(
        tribeId: _uuid.v4(),
        name: 'Kigali Institute',
        slug: 'kigali-institute',
        description: 'Late-night thoughts welcome.',
        category: 'campus',
        memberCount: 1200,
        isPrivate: false,
        createdAt: now0.subtract(const Duration(days: 60)),
      ),
      Tribe(
        tribeId: _uuid.v4(),
        name: 'Kigali Tech Confessions',
        slug: 'kigali-tech-confessions',
        description: 'Anonymous confessions from the tech scene.',
        category: 'interest_group',
        memberCount: 3892,
        isPrivate: false,
        createdAt: now0.subtract(const Duration(days: 30)),
        keeperPseudonym: 'PatrickO',
        keeperAvatarSeed: 'plum-orb-0001',
        keeperIsVerified: true,
      ),
      Tribe(
        tribeId: _uuid.v4(),
        name: 'Healing Together',
        slug: 'healing-together',
        description: 'Soft daily reminders. We rise together.',
        category: 'support',
        memberCount: 2102,
        isPrivate: false,
        createdAt: now0.subtract(const Duration(days: 14)),
        keeperPseudonym: 'HealingCoach',
        keeperAvatarSeed: 'rose-leaf-0042',
        keeperIsVerified: true,
      ),
    ]);
    for (final tribe in _tribes) {
      _ensureDefaultSpace(tribe, createdAt: tribe.createdAt);
    }
    final ur = _tribes[0];
    final kInst = _tribes[1];

    final now = DateTime.now();
    _posts.addAll([
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@SilentEcho',
        authorAvatarSeed: 'rose-orb-1132',
        categoryName: 'confessions',
        postType: 'user_post',
        content:
            "Sometimes I feel like I'm giving 100% to everyone around me, but when I need someone, the room is empty. Just needed a safe place to put this thought down before I sleep.",
        postMood: 'exhausted',
        likesCount: 24,
        commentsCount: 8,
        createdAt: now.subtract(const Duration(hours: 2)),
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@WanderingSoul',
        authorAvatarSeed: 'blush-petal-0099',
        categoryName: 'healing_corner',
        postType: 'user_post',
        content:
            "Today is the first day in a month that I woke up and didn't immediately feel a heavy weight on my chest. Progress isn't linear, but today feels like a win.",
        postMood: 'healing',
        likesCount: 156,
        commentsCount: 42,
        createdAt: now.subtract(const Duration(hours: 5)),
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@Anonymous291',
        authorAvatarSeed: 'mauve-mist-7711',
        categoryName: 'late_night',
        postType: 'user_post',
        content: 'Why do late nights always bring out the loudest thoughts?',
        postMood: 'overthinking',
        likesCount: 12,
        commentsCount: 2,
        createdAt: now.subtract(const Duration(hours: 8)),
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@MidnightMind',
        authorAvatarSeed: 'plum-moon-0420',
        categoryName: 'confessions',
        postType: 'user_post',
        content:
            "I accidentally told my boss 'love you' before hanging up on a Zoom call. I haven't spoken to him since and I'm dreading tomorrow morning. Is it time to fake my own death?",
        postMood: 'anxious',
        likesCount: 4200,
        commentsCount: 128,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 4)),
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@ShadowWalker',
        authorAvatarSeed: 'berry-ash-1090',
        categoryName: 'campus_life',
        postType: 'user_post',
        content:
            "Finals week is draining my soul. Anyone else studying in the library until 2 AM tonight? Bring coffee beans.",
        postMood: 'exhausted',
        likesCount: 124,
        commentsCount: 32,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 30)),
        tribeId: kInst.tribeId,
        tribeName: kInst.name,
        tribeSlug: kInst.slug,
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@Anonymous291',
        authorAvatarSeed: 'mauve-mist-7711',
        categoryName: 'campus_life',
        postType: 'user_post',
        content:
            "Just saw the cutest stray dog near the main gate. I gave him half my sandwich. Someone tell me I'm a good person.",
        postMood: 'happy',
        likesCount: 89,
        commentsCount: 15,
        createdAt: now.subtract(const Duration(hours: 5, minutes: 20)),
        tribeId: ur.tribeId,
        tribeName: ur.name,
        tribeSlug: ur.slug,
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@ShadowWalker',
        authorAvatarSeed: 'berry-ash-1090',
        categoryName: 'vent_zone',
        postType: 'user_post',
        content:
            "Sometimes 2am hits and every memory I never sat with shows up at once. I just want my mind to be quiet for one night.",
        postMood: 'overthinking',
        likesCount: 124,
        commentsCount: 18,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 10)),
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@AnonymousTiger',
        authorAvatarSeed: 'rose-feather-2244',
        categoryName: 'campus_life',
        postType: 'user_post',
        content:
            "Does anyone else feel like the library is just a competitive stress arena? I walked in to study and left with anxiety because everyone looks like they're curing a disease.",
        postMood: 'anxious',
        likesCount: 241,
        commentsCount: 45,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 45)),
        tribeId: ur.tribeId,
        tribeName: ur.name,
        tribeSlug: ur.slug,
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@SecretAdmirer',
        authorAvatarSeed: 'plum-glow-3322',
        categoryName: 'confessions',
        postType: 'user_post',
        content:
            "I deliberately take the long way to the cafeteria just in hopes of bumping into that guy from my Monday morning lecture. I don't even know his name.",
        postMood: 'hopeful',
        likesCount: 189,
        commentsCount: 12,
        createdAt: now.subtract(const Duration(hours: 5, minutes: 12)),
        tribeId: ur.tribeId,
        tribeName: ur.name,
        tribeSlug: ur.slug,
      ),
    ]);

    _seedCommentsForFirstConfession();
    _synchronizeSeedCommentCounts();

    _prompts.addAll([
      PlugPrompt(
        promptId: _uuid.v4(),
        plugDisplayName: '@PatrickO',
        plugAvatarSeed: patrick.avatarSeed,
        promptText: 'What secrets do you keep from your parents?',
        answersCount: 1842,
      ),
      PlugPrompt(
        promptId: _uuid.v4(),
        plugDisplayName: '@HealingCoach',
        plugAvatarSeed: healing.avatarSeed,
        promptText: "What's one kind thing you did for yourself today?",
        answersCount: 521,
      ),
    ]);

    // Seed message requests so the Inbox screen has content.
    _rooms.addAll([
      ChatRoom(
        roomId: _uuid.v4(),
        peerPseudonym: '@MidnightMind',
        peerAvatarSeed: 'plum-moon-0420',
        requestPreview:
            'I totally get what you mean about the pressure. Would love to chat if you need someone to listen.',
        roomStatus: 'pending_request',
        createdAt: now.subtract(const Duration(hours: 2)),
        initiatedByMe: false,
      ),
      ChatRoom(
        roomId: _uuid.v4(),
        peerPseudonym: '@HiddenFlower',
        peerAvatarSeed: 'rose-petal-9911',
        requestPreview:
            "Hey, your post really resonated with me. Just wanted to say you're not alone.",
        roomStatus: 'pending_request',
        createdAt: now.subtract(const Duration(days: 1)),
        initiatedByMe: false,
      ),
      ChatRoom(
        roomId: _uuid.v4(),
        peerPseudonym: '@SilentSoul',
        peerAvatarSeed: 'mauve-flame-5050',
        requestPreview:
            'Hey, are you there? I really needed to vent about something that happened today.',
        roomStatus: 'active',
        createdAt: now.subtract(const Duration(hours: 6)),
        initiatedByMe: false,
      ),
    ]);

    // Seed server-readable messages for the active chat
    _messages[_rooms.last.roomId] = [
      ChatMessage(
        messageId: _uuid.v4(),
        roomId: _rooms.last.roomId,
        senderId: 'peer',
        plaintext:
            'Hey, are you there? I really needed to vent about something that happened today.',
        createdAt: now.subtract(const Duration(hours: 6)),
        sentByMe: false,
      ),
      ChatMessage(
        messageId: _uuid.v4(),
        roomId: _rooms.last.roomId,
        senderId: 'me',
        plaintext: "I'm here. Safe space. What's on your mind?",
        createdAt: now.subtract(const Duration(hours: 6, minutes: -3)),
        sentByMe: true,
      ),
      ChatMessage(
        messageId: _uuid.v4(),
        roomId: _rooms.last.roomId,
        senderId: 'peer',
        plaintext:
            "Just feeling completely overwhelmed at work. Like no matter how much I do, it's never enough. And I can't talk to anyone there about it without sounding like I'm complaining.",
        createdAt: now.subtract(const Duration(hours: 5, minutes: 50)),
        sentByMe: false,
      ),
      ChatMessage(
        messageId: _uuid.v4(),
        roomId: _rooms.last.roomId,
        senderId: 'me',
        plaintext: "It's exhausting keeping up the 'everything is fine' mask.",
        createdAt: now.subtract(const Duration(hours: 5, minutes: 49)),
        sentByMe: true,
      ),
    ];

    _notifications.addAll([
      NotificationItem(
        id: _uuid.v4(),
        kind: 'message_request',
        title: 'New message request',
        body: '@MidnightMind sent you a message request.',
        createdAt: now.subtract(const Duration(hours: 2)),
        isRead: false,
      ),
      NotificationItem(
        id: _uuid.v4(),
        kind: 'comment_reply',
        title: 'New reply on your vent',
        body: '@Ghosty replied to your confession.',
        createdAt: now.subtract(const Duration(hours: 3)),
        isRead: false,
      ),
      NotificationItem(
        id: _uuid.v4(),
        kind: 'tribe_prompt',
        title: 'New prompt from @PatrickO',
        body: '"What secrets do you keep from your parents?"',
        createdAt: now.subtract(const Duration(hours: 7)),
        isRead: true,
      ),
    ]);
  }

  void _seedCommentsForFirstConfession() {
    final firstPost = _posts.first;
    final c1 = ThreadedComment(
      commentId: _uuid.v4(),
      authorPseudonym: '@Ghosty',
      authorAvatarSeed: 'rose-vapor-1144',
      content:
          "Bro just own it. Walk in tomorrow with a coffee for him and say 'for my favorite person'. Assert dominance.",
      path: 'a',
      depth: 0,
      likesCount: 1100,
      createdAt: DateTime.now().subtract(const Duration(hours: 5)),
    );
    final c2 = ThreadedComment(
      commentId: _uuid.v4(),
      parentId: c1.commentId,
      authorPseudonym: '@AnxiousPanda',
      authorAvatarSeed: 'mauve-bamboo-2266',
      content:
          'Do NOT do this. Just act like it never happened. Pls for your own sanity.',
      path: 'a.b',
      depth: 1,
      likesCount: 450,
      createdAt: DateTime.now().subtract(const Duration(minutes: 54)),
    );
    final c3 = ThreadedComment(
      commentId: _uuid.v4(),
      parentId: c2.commentId,
      authorPseudonym: '@ChaosDemon',
      authorAvatarSeed: 'berry-bolt-3091',
      content: 'Nah the coffee idea is peak Gen Z energy. I support the chaos.',
      path: 'a.b.c',
      depth: 2,
      likesCount: 89,
      createdAt: DateTime.now().subtract(const Duration(minutes: 30)),
    );
    c2.children.add(c3);
    c1.children.add(c2);

    final c4 = ThreadedComment(
      commentId: _uuid.v4(),
      authorPseudonym: '@MidnightThinker',
      authorAvatarSeed: 'plum-fog-4242',
      content:
          "I did this to my driving instructor once when I was 17. I failed the test and had to find a new instructor because I couldn't look him in the eye.",
      path: 'd',
      depth: 0,
      likesCount: 820,
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    );

    _commentsByPost[firstPost.postId] = [c1, c4];
  }

  void _synchronizeSeedCommentCounts() {
    int countTree(List<ThreadedComment> comments) {
      return comments.fold<int>(
        0,
        (total, comment) => total + 1 + countTree(comment.children),
      );
    }

    for (var index = 0; index < _posts.length; index++) {
      final post = _posts[index];
      final actualCount = countTree(
        _commentsByPost[post.postId] ?? const <ThreadedComment>[],
      );
      _posts[index] = post.copyWith(commentsCount: actualCount);
    }
  }
}

class _MockFriendship {
  final String friendshipId;
  final String userA;
  final String userB;
  String status;
  final String requestedBy;
  final String? note;
  final DateTime createdAt;
  DateTime? acceptedAt;

  _MockFriendship({
    required this.friendshipId,
    required this.userA,
    required this.userB,
    required this.status,
    required this.requestedBy,
    required this.createdAt,
    this.note,
  }) : acceptedAt = null;
}

class _MockBlock {
  final String blockerId;
  final String blockedId;
  final String? reason;
  final DateTime createdAt;

  const _MockBlock({
    required this.blockerId,
    required this.blockedId,
    required this.createdAt,
    this.reason,
  });
}
