import 'dart:async';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../domain/entities/entities.dart';
import 'supabase_backend.dart'
    show
        UsernameTakenException,
        InvalidCredentialsException;

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
  final List<Post> _posts = [];
  final Map<String, List<ThreadedComment>> _commentsByPost = {};
  final Set<String> _likedPosts = {};
  final Set<String> _savedPosts = {};
  final Set<String> _joinedTribes = {};
  final List<ChatRoom> _rooms = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final List<PlugPrompt> _prompts = [];
  final List<NotificationItem> _notifications = [];

  // Stream controllers for live UI updates.
  final _postsController = StreamController<List<Post>>.broadcast();
  final _roomsController = StreamController<List<ChatRoom>>.broadcast();
  final _notificationsController = StreamController<List<NotificationItem>>.broadcast();

  Stream<List<Post>> get postsStream => _postsController.stream;
  Stream<List<ChatRoom>> get roomsStream => _roomsController.stream;
  Stream<List<NotificationItem>> get notificationsStream =>
      _notificationsController.stream;

  AppUser? get me => _me;

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
    final user =
        _users.firstWhere((u) => u.anonymousPseudonym.toLowerCase() == key);
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
  }) {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final filtered = _posts.where((p) {
      final byCategory = category == null || p.categoryName == category;
      final byMood     = mood == null || p.postMood == mood;
      final byTribe    = tribeSlug == null || p.tribeSlug == tribeSlug;
      final byWhisper  = !p.isWhisper || p.createdAt.isAfter(cutoff);
      // Mock posts don't carry a location_bucket. When the caller asks for
      // a local feed, return empty so the UI exercises the fallback path.
      final byLocation = locationBucket == null;
      return byCategory && byMood && byTribe && byWhisper && byLocation;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return [
      for (final p in filtered)
        p.copyWith(
          likedByMe: _likedPosts.contains(p.postId),
          savedByMe: _savedPosts.contains(p.postId),
        ),
    ];
  }

  Post? postById(String postId) {
    final p = _posts.firstWhereOrNull((p) => p.postId == postId);
    if (p == null) return null;
    return p.copyWith(
      likedByMe: _likedPosts.contains(postId),
      savedByMe: _savedPosts.contains(postId),
    );
  }

  Future<Post> createPost({
    required String content,
    required String category,
    required String mood,
    String? tribeId,
    bool isWhisper = false,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final tribe = tribeId == null
        ? null
        : _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    final post = Post(
      postId: _uuid.v4(),
      authorPseudonym: '@${me.anonymousPseudonym}',
      authorAvatarSeed: me.avatarSeed,
      authorIsVerified: me.isVerified,
      categoryName: category,
      postType: 'user_post',
      content: content,
      postMood: mood,
      isWhisper: isWhisper,
      likesCount: 0,
      commentsCount: 0,
      createdAt: DateTime.now(),
      tribeId: tribe?.tribeId,
      tribeName: tribe?.name,
      tribeSlug: tribe?.slug,
    );
    _posts.insert(0, post);
    _emitPosts();
    return post;
  }

  void toggleLike(String postId) {
    final i = _posts.indexWhere((p) => p.postId == postId);
    if (i == -1) return;
    final liked = _likedPosts.contains(postId);
    if (liked) {
      _likedPosts.remove(postId);
      _posts[i] = _posts[i].copyWith(likesCount: max(_posts[i].likesCount - 1, 0));
    } else {
      _likedPosts.add(postId);
      _posts[i] = _posts[i].copyWith(likesCount: _posts[i].likesCount + 1);
    }
    _emitPosts();
  }

  void toggleSave(String postId) {
    if (_savedPosts.contains(postId)) {
      _savedPosts.remove(postId);
    } else {
      _savedPosts.add(postId);
    }
    _emitPosts();
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

  List<TribeReport> tribeReports(String tribeId) {
    // Mock only — keep the demo seed posts visible to the keeper as if
    // they'd been reported, so the queue isn't empty in dev mode.
    if (_tribeReports.isEmpty) {
      final tribePosts =
          _posts.where((p) => p.tribeId == tribeId).take(2).toList();
      for (final p in tribePosts) {
        _tribeReports.add(TribeReport(
          reportId: _uuid.v4(),
          reason: 'harassment',
          isResolved: false,
          createdAt: DateTime.now().subtract(const Duration(hours: 4)),
          postId: p.postId,
          postPreview:
              p.content.length > 160 ? p.content.substring(0, 160) : p.content,
          postDeleted: false,
        ));
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

  // -------------------- Profile location --------------------
  AppUser updateMyLocation({
    String? homeCity,
    String? homeCountry,
    String? homeCampus,
  }) {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final updated = me.copyWith(
      homeCity: homeCity?.trim().isEmpty == true ? null : homeCity?.trim(),
      homeCountry:
          homeCountry?.trim().isEmpty == true ? null : homeCountry?.trim(),
      homeCampus:
          homeCampus?.trim().isEmpty == true ? null : homeCampus?.trim(),
    );
    _me = updated;
    final i = _users.indexWhere((u) => u.userId == me.userId);
    if (i != -1) _users[i] = updated;
    _emitAll();
    return updated;
  }

  // -------------------- Co-mod hierarchy --------------------
  final Map<String, Map<String, String>> _tribeRoles = {}; // tribeId -> userId -> role

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
        out.add(TribeMemberRow(
          userId: keeper.userId,
          pseudonym: keeper.anonymousPseudonym,
          avatarSeed: keeper.avatarSeed,
          role: 'keeper',
          joinedAt: tribe.createdAt,
        ));
      }
    }
    final me = _me;
    if (me != null && me.userId != tribe.keeperId && _joinedTribes.contains(tribeId)) {
      out.add(TribeMemberRow(
        userId: me.userId,
        pseudonym: me.anonymousPseudonym,
        avatarSeed: me.avatarSeed,
        role: _roleFor(tribeId, me.userId),
        joinedAt: DateTime.now(),
      ));
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

  void transferKeeper({
    required String tribeId,
    required String toUserId,
  }) {
    final i = _tribes.indexWhere((t) => t.tribeId == tribeId);
    if (i == -1) return;
    _tribes[i] = _tribes[i].copyWith();
    // Mock doesn't have full keeperId reassignment plumbing — left as a
    // smoke shim; live path is the one we ship against.
  }

  // -------------------- Badges + streaks --------------------
  final List<BadgeDefinition> _badgeCatalogue = const [
    BadgeDefinition(key: 'first_vent', label: 'First Vent',
        description: 'Your first confession.', icon: '⭐', tier: 'bronze'),
    BadgeDefinition(key: 'seven_day_venter', label: '7-Day Venter',
        description: 'Seven consecutive days posting.', icon: '🌙', tier: 'silver'),
    BadgeDefinition(key: 'keeper', label: 'Keeper',
        description: 'Started your own Tribe.', icon: '🌿', tier: 'silver'),
    BadgeDefinition(key: 'whisper_keeper', label: 'Whisper Keeper',
        description: 'Posted ten Whispers.', icon: '🌒', tier: 'bronze'),
  ];
  final Map<String, List<UserBadge>> _userBadges = {};

  List<BadgeDefinition> badgeCatalogue() => _badgeCatalogue;
  List<UserBadge> badgesFor(String userId) =>
      _userBadges[userId] ?? const [];
  List<UserStreak> myStreaks() => const [];

  // -------------------- User lookup --------------------
  AppUser? findUserByPseudonym(String pseudonym) {
    final q = pseudonym.trim().replaceAll('@', '').toLowerCase();
    if (q.isEmpty) return null;
    return _users.firstWhereOrNull(
        (u) => u.anonymousPseudonym.toLowerCase() == q);
  }

  // -------------------- Tribe invitations --------------------
  final List<TribeInvite> _invites = [];

  void inviteToTribe({
    required String tribeId,
    required String invitedUserId,
    String? message,
  }) {
    if (_invites.any((i) =>
        i.tribeId == tribeId &&
        i.invitedUserId == invitedUserId &&
        i.isPending)) return;
    final tribe = _tribes.firstWhereOrNull((t) => t.tribeId == tribeId);
    _invites.add(TribeInvite(
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
    ));
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
      for (final t in optionTexts)
        PollOption(optionId: _uuid.v4(), text: t),
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

  void votePoll({
    required String pollId,
    required String optionId,
  }) {
    final entry =
        _polls.entries.firstWhereOrNull((e) => e.value.pollId == pollId);
    if (entry == null) return;
    final poll = entry.value;
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
      .map((p) => p.copyWith(savedByMe: true, likedByMe: _likedPosts.contains(p.postId)))
      .toList();

  List<Post> myVents() {
    final me = _me;
    if (me == null) return [];
    return _posts
        .where((p) => p.authorPseudonym == '@${me.anonymousPseudonym}')
        .map((p) => p.copyWith(
              likedByMe: _likedPosts.contains(p.postId),
              savedByMe: _savedPosts.contains(p.postId),
            ))
        .toList();
  }

  // -------------------- Comments --------------------
  List<ThreadedComment> comments(String postId) {
    return _commentsByPost[postId] ?? const [];
  }

  Future<ThreadedComment> addComment({
    required String postId,
    String? parentId,
    required String content,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final tree = _commentsByPost.putIfAbsent(postId, () => []);
    final parent = parentId == null ? null : _findInTree(tree, parentId);
    final depth = parent == null ? 0 : parent.depth + 1;
    final path = parent == null
        ? _uuid.v4().replaceAll('-', '')
        : '${parent.path}.${_uuid.v4().replaceAll('-', '')}';
    final comment = ThreadedComment(
      commentId: _uuid.v4(),
      parentId: parentId,
      authorPseudonym: '@${me.anonymousPseudonym}',
      authorAvatarSeed: me.avatarSeed,
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
      _posts[i] = _posts[i].copyWith(commentsCount: _posts[i].commentsCount + 1);
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
        .where((t) =>
            q == null || q.isEmpty || t.name.toLowerCase().contains(q))
        .map((t) => t.copyWith(joinedByMe: _joinedTribes.contains(t.tribeId)))
        .toList()
      ..sort((a, b) => b.memberCount.compareTo(a.memberCount));
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
      createdAt: DateTime.now(),
      keeperId: me?.userId,
      keeperPseudonym: me?.anonymousPseudonym,
      keeperAvatarSeed: me?.avatarSeed,
      keeperIsVerified: me?.isVerified ?? false,
      joinedByMe: true,
    );
    _tribes.add(t);
    _joinedTribes.add(t.tribeId);
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
    return _rooms.where((r) {
      if (tab == 'requests') return r.roomStatus == 'pending_request';
      if (tab == 'active')   return r.roomStatus == 'active';
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  ChatRoom acceptRequest(String roomId) {
    final i = _rooms.indexWhere((r) => r.roomId == roomId);
    if (i == -1) throw StateError('Room not found');
    final room = _rooms[i];
    final updated = ChatRoom(
      roomId: room.roomId,
      peerPseudonym: room.peerPseudonym,
      peerAvatarSeed: room.peerAvatarSeed,
      requestPreview: room.requestPreview,
      roomStatus: 'active',
      createdAt: room.createdAt,
      initiatedByMe: room.initiatedByMe,
    );
    _rooms[i] = updated;
    _messages.putIfAbsent(roomId, () => [
      ChatMessage(
        messageId: _uuid.v4(),
        roomId: roomId,
        senderId: 'peer',
        plaintext: room.requestPreview,
        createdAt: room.createdAt,
        sentByMe: false,
      ),
    ]);
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
      requestPreview: r.requestPreview,
      roomStatus: 'declined',
      createdAt: r.createdAt,
      initiatedByMe: r.initiatedByMe,
    );
    _emitRooms();
  }

  List<ChatMessage> roomMessages(String roomId) =>
      _messages[roomId] ?? const [];

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

  ChatMessage sendMessage({
    required String roomId,
    required String plaintext,
  }) {
    final msg = ChatMessage(
      messageId: _uuid.v4(),
      roomId: roomId,
      senderId: 'me',
      plaintext: plaintext,
      createdAt: DateTime.now(),
      sentByMe: true,
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
      authorPseudonym: '@${me?.anonymousPseudonym ?? 'anonymous'}',
      authorAvatarSeed: me?.avatarSeed ?? 'default-orb',
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
        .map((p) => p.copyWith(
              likedByMe: _likedPosts.contains(p.postId),
              savedByMe: _savedPosts.contains(p.postId),
            ))
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
      bio: 'Community Keeper | Kigali. Holding space for big feelings.',
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
    final ur     = _tribes[0];
    final kInst  = _tribes[1];

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
        authorAvatarSeed: 'plum-bloom-3322',
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
        requestPreview: 'Hey, are you there? I really needed to vent about something that happened today.',
        roomStatus: 'active',
        createdAt: now.subtract(const Duration(hours: 6)),
        initiatedByMe: false,
      ),
    ]);

    // Seed encrypted messages for the active chat
    _messages[_rooms.last.roomId] = [
      ChatMessage(
        messageId: _uuid.v4(),
        roomId: _rooms.last.roomId,
        senderId: 'peer',
        plaintext: 'Hey, are you there? I really needed to vent about something that happened today.',
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
}
