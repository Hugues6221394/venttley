import 'dart:async';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../domain/entities/entities.dart';

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
  final List<PlugProfile> _plugz = [];
  final List<Space> _spaces = [];
  final List<Post> _posts = [];
  final Map<String, List<ThreadedComment>> _commentsByPost = {};
  final Set<String> _likedPosts = {};
  final Set<String> _savedPosts = {};
  final Set<String> _followedPlugz = {};
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

  void logout() {
    _me = null;
    _emitAll();
  }

  // -------------------- Feed --------------------
  List<Post> feed({String? category, String? mood, String? spaceName}) {
    final filtered = _posts.where((p) {
      final byCategory = category == null || p.categoryName == category;
      final byMood     = mood == null || p.postMood == mood;
      final bySpace    = spaceName == null || p.spaceName == spaceName;
      return byCategory && byMood && bySpace;
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
    String? spaceName,
    bool isAudio = false,
    String? audioUrl,
    int audioDurationMs = 0,
  }) async {
    final me = _me;
    if (me == null) throw StateError('No active session');
    final post = Post(
      postId: _uuid.v4(),
      authorPseudonym: '@${me.anonymousPseudonym}',
      authorAvatarSeed: me.avatarSeed,
      categoryName: category,
      postType: 'user_post',
      content: content,
      postMood: mood,
      isAudio: isAudio,
      audioUrl: audioUrl,
      audioDurationMs: audioDurationMs,
      likesCount: 0,
      commentsCount: 0,
      createdAt: DateTime.now(),
      spaceName: spaceName,
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

  // -------------------- Plugz / Tribes --------------------
  List<PlugProfile> allPlugz() => List.unmodifiable(_plugz);

  PlugProfile? plugByDisplayName(String name) =>
      _plugz.firstWhereOrNull((p) => p.displayName == name);

  bool isFollowing(String plugId) => _followedPlugz.contains(plugId);

  void toggleFollow(String plugId) {
    final idx = _plugz.indexWhere((p) => p.plugId == plugId);
    if (idx == -1) return;
    if (_followedPlugz.contains(plugId)) {
      _followedPlugz.remove(plugId);
      _plugz[idx] = PlugProfile(
        plugId: _plugz[idx].plugId,
        displayName: _plugz[idx].displayName,
        bio: _plugz[idx].bio,
        locationLabel: _plugz[idx].locationLabel,
        tribeCount: max(_plugz[idx].tribeCount - 1, 0),
        avatarSeed: _plugz[idx].avatarSeed,
      );
    } else {
      _followedPlugz.add(plugId);
      _plugz[idx] = PlugProfile(
        plugId: _plugz[idx].plugId,
        displayName: _plugz[idx].displayName,
        bio: _plugz[idx].bio,
        locationLabel: _plugz[idx].locationLabel,
        tribeCount: _plugz[idx].tribeCount + 1,
        avatarSeed: _plugz[idx].avatarSeed,
      );
    }
  }

  // -------------------- Spaces --------------------
  List<Space> spaces() => List.unmodifiable(_spaces);

  Space createSpace({
    required String name,
    required String type,
    String? description,
  }) {
    final s = Space(
      spaceId: _uuid.v4(),
      spaceName: name,
      spaceType: type,
      description: description,
      memberCount: 1,
    );
    _spaces.add(s);
    return s;
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

  // -------------------- Notifications --------------------
  List<NotificationItem> notifications() => List.unmodifiable(_notifications);

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

    _spaces.addAll([
      Space(
        spaceId: _uuid.v4(),
        spaceName: 'University of Rwanda',
        spaceType: 'campus',
        description: 'The official emotional sanctuary for UR students.',
        memberCount: 4209,
      ),
      Space(
        spaceId: _uuid.v4(),
        spaceName: 'Kigali Institute',
        spaceType: 'campus',
        description: 'Late-night thoughts welcome.',
        memberCount: 1200,
      ),
      Space(
        spaceId: _uuid.v4(),
        spaceName: 'Kigali Tech Confessions',
        spaceType: 'interest_group',
        description: 'Anonymous confessions from the tech scene.',
        memberCount: 3892,
      ),
    ]);

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
        isAudio: false,
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
        isAudio: false,
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
        isAudio: false,
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
        isAudio: false,
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
        isAudio: false,
        likesCount: 124,
        commentsCount: 32,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 30)),
        spaceName: 'Kigali Institute',
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
        isAudio: false,
        likesCount: 89,
        commentsCount: 15,
        createdAt: now.subtract(const Duration(hours: 5, minutes: 20)),
        spaceName: 'University of Rwanda',
      ),
      Post(
        postId: _uuid.v4(),
        authorPseudonym: '@ShadowWalker',
        authorAvatarSeed: 'berry-ash-1090',
        categoryName: 'vent_zone',
        postType: 'user_post',
        content: 'Midnight Thoughts',
        postMood: 'overthinking',
        isAudio: true,
        audioUrl: 'local://demo/midnight-thoughts.m4a',
        audioDurationMs: 130000,
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
        isAudio: false,
        likesCount: 241,
        commentsCount: 45,
        createdAt: now.subtract(const Duration(hours: 2, minutes: 45)),
        spaceName: 'University of Rwanda',
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
        isAudio: false,
        likesCount: 189,
        commentsCount: 12,
        createdAt: now.subtract(const Duration(hours: 5, minutes: 12)),
        spaceName: 'University of Rwanda',
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
