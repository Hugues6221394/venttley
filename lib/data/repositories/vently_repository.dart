import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../domain/entities/entities.dart';
import '../services/identity_service.dart';
import '../services/mock_backend.dart';
import '../services/supabase_backend.dart';

/// Single facade exposing the data layer to the UI.
///
/// Internally it forwards to either:
///   * [MockBackend]      — when `VentlyConfig.useMockBackend` is true
///   * [SupabaseBackend]  — when the live Supabase project is reachable
class VentlyRepository {
  VentlyRepository({MockBackend? mock, IdentityService? identity})
      : _mock = mock ?? MockBackend.instance,
        _identity = identity ?? IdentityService(),
        _live = VentlyConfig.useMockBackend
            ? null
            : SupabaseBackend.of(Supabase.instance.client);

  final MockBackend _mock;
  final IdentityService _identity;
  final SupabaseBackend? _live;

  IdentityService get identity => _identity;
  bool get isMockMode => _live == null;

  // ===================== Session =====================
  AppUser? get currentUser => _live?.me ?? _mock.me;

  Future<AppUser> bootstrapAccount({
    required DateTime birthDate,
    required String pseudonym,
    required String avatarSeed,
  }) async {
    final age = _ageFrom(birthDate);
    if (age < VentlyConfig.minAge) {
      throw AgeGateBlocked();
    }
    final tier = age <= VentlyConfig.restrictedMaxAge
        ? 'restricted_minor'
        : 'standard';

    final live = _live;
    if (live != null) {
      final user = await live.bootstrap(
        pseudonym: pseudonym,
        avatarSeed: avatarSeed,
        birthYear: birthDate.year,
        safetyTier: tier,
      );
      await _identity.persistSession(
        userId: user.userId,
        pseudonym: pseudonym,
        avatarSeed: avatarSeed,
        recoveryKey: _identity.generateRecoveryKey(),
        birthYear: birthDate.year,
        safetyTier: tier,
      );
      return user;
    }

    // Mock path — keep the previous deterministic-from-recovery-key flow.
    final recoveryKey = _identity.generateRecoveryKey();
    final salt = await _identity.ensureDeviceSalt();
    final hash = _identity.hashRecoveryKey(recoveryKey, salt);
    final userId = 'u_${hash.substring(0, 16)}';
    final user = AppUser(
      userId: userId,
      anonymousPseudonym: pseudonym,
      avatarSeed: avatarSeed,
      currentMood: 'healing',
      userRole: 'normal',
      isVerified: false,
      safetyTier: tier,
      accountStatus: 'active',
      birthYear: birthDate.year,
    );
    await _identity.persistSession(
      userId: userId,
      pseudonym: pseudonym,
      avatarSeed: avatarSeed,
      recoveryKey: recoveryKey,
      birthYear: birthDate.year,
      safetyTier: tier,
    );
    _mock.registerSession(user);
    return user;
  }

  Future<String> currentRecoveryKey() async {
    final session = await _identity.loadSession();
    if (session == null) return '';
    final salt = await _identity.ensureDeviceSalt();
    final hash = _identity.hashRecoveryKey(session['user_id'] ?? '', salt);
    return hash.substring(0, 20).toUpperCase();
  }

  Future<AppUser?> restoreSession() async {
    final live = _live;
    if (live != null) {
      final user = await live.restore();
      if (user != null) return user;
    }
    final session = await _identity.loadSession();
    if (session == null) return null;
    final user = AppUser(
      userId: session['user_id']!,
      anonymousPseudonym: session['pseudonym']!,
      avatarSeed: session['avatar_seed']!,
      currentMood: 'healing',
      userRole: 'normal',
      isVerified: false,
      safetyTier: session['safety_tier']!,
      accountStatus: 'active',
      birthYear: int.tryParse(session['birth_year'] ?? ''),
    );
    if (live == null) _mock.registerSession(user);
    return user;
  }

  Future<void> logout() async {
    await _identity.clearSession();
    if (_live != null) {
      await _live.logout();
    } else {
      _mock.logout();
    }
  }

  // ===================== Posts / Feed =====================
  Stream<List<Post>> watchFeed({String? category, String? mood, String? spaceName}) {
    final live = _live;
    if (live != null) {
      // Seed the stream with an immediate fetch, then track realtime emits.
      final controller = StreamController<List<Post>>();
      late StreamSubscription<List<Post>> sub;
      Future<void> emit() async {
        controller.add(await live.feed(
          category: category,
          mood: mood,
          spaceName: spaceName,
        ));
      }
      sub = live.postsStream.listen((_) => emit());
      controller.onListen = emit;
      controller.onCancel = () => sub.cancel();
      return controller.stream;
    }
    return _mock.postsStream.map((_) => _mock.feed(
          category: category,
          mood: mood,
          spaceName: spaceName,
        ));
  }

  Future<List<Post>> feed({String? category, String? mood, String? spaceName}) {
    final live = _live;
    if (live != null) {
      return live.feed(category: category, mood: mood, spaceName: spaceName);
    }
    return Future.value(
        _mock.feed(category: category, mood: mood, spaceName: spaceName));
  }

  Future<Post> createPost({
    required String content,
    required String category,
    required String mood,
    String? spaceName,
    bool isAudio = false,
    String? audioUrl,
    int audioDurationMs = 0,
  }) {
    final live = _live;
    if (live != null) {
      return live.createPost(
        content: content,
        category: category,
        mood: mood,
        spaceName: spaceName,
        isAudio: isAudio,
        audioUrl: audioUrl,
        audioDurationMs: audioDurationMs,
      );
    }
    return _mock.createPost(
      content: content,
      category: category,
      mood: mood,
      spaceName: spaceName,
      isAudio: isAudio,
      audioUrl: audioUrl,
      audioDurationMs: audioDurationMs,
    );
  }

  Future<void> toggleLike(String postId) {
    final live = _live;
    if (live != null) return live.toggleLike(postId);
    _mock.toggleLike(postId);
    return Future.value();
  }

  Future<void> toggleSave(String postId) {
    final live = _live;
    if (live != null) return live.toggleSave(postId);
    _mock.toggleSave(postId);
    return Future.value();
  }

  Future<Post?> postById(String postId) {
    final live = _live;
    if (live != null) return live.postById(postId);
    return Future.value(_mock.postById(postId));
  }

  Future<List<Post>> mySaved() {
    final live = _live;
    if (live != null) return live.mySaved();
    return Future.value(_mock.mySaved());
  }

  Future<List<Post>> myVents() {
    final live = _live;
    if (live != null) return live.myVents();
    return Future.value(_mock.myVents());
  }

  // ===================== Comments =====================
  Future<List<ThreadedComment>> comments(String postId) {
    final live = _live;
    if (live != null) return live.comments(postId);
    return Future.value(_mock.comments(postId));
  }

  Future<ThreadedComment> addComment({
    required String postId,
    String? parentId,
    required String content,
  }) {
    final live = _live;
    if (live != null) {
      return live.addComment(
          postId: postId, parentId: parentId, content: content);
    }
    return _mock.addComment(
        postId: postId, parentId: parentId, content: content);
  }

  // ===================== Plugz / Tribes =====================
  Future<List<PlugProfile>> allPlugz() {
    final live = _live;
    if (live != null) return live.allPlugz();
    return Future.value(_mock.allPlugz());
  }

  Future<PlugProfile?> plug(String name) {
    final live = _live;
    if (live != null) return live.plugByName(name);
    return Future.value(_mock.plugByDisplayName(name));
  }

  bool isFollowing(String plugId) {
    final live = _live;
    if (live != null) return live.isFollowing(plugId);
    return _mock.isFollowing(plugId);
  }

  Future<void> toggleFollow(String plugId) {
    final live = _live;
    if (live != null) return live.toggleFollow(plugId);
    _mock.toggleFollow(plugId);
    return Future.value();
  }

  // ===================== Spaces =====================
  Future<List<Space>> spaces() {
    final live = _live;
    if (live != null) return live.spaces();
    return Future.value(_mock.spaces());
  }

  Future<Space> createSpace(
      {required String name, required String type, String? description}) {
    final live = _live;
    if (live != null) {
      return live.createSpace(name: name, type: type, description: description);
    }
    return Future.value(
        _mock.createSpace(name: name, type: type, description: description));
  }

  // ===================== Chat =====================
  Stream<List<ChatRoom>> watchInbox(String tab) {
    final live = _live;
    if (live != null) {
      final controller = StreamController<List<ChatRoom>>();
      late StreamSubscription<List<ChatRoom>> sub;
      Future<void> emit() async => controller.add(await live.inbox(tab: tab));
      sub = live.roomsStream.listen((_) => emit());
      controller.onListen = emit;
      controller.onCancel = () => sub.cancel();
      return controller.stream;
    }
    return _mock.roomsStream.map((_) => _mock.inbox(tab: tab));
  }

  Future<List<ChatRoom>> inbox(String tab) {
    final live = _live;
    if (live != null) return live.inbox(tab: tab);
    return Future.value(_mock.inbox(tab: tab));
  }

  Future<ChatRoom> acceptRequest(String roomId) {
    final live = _live;
    if (live != null) return live.acceptRequest(roomId);
    return Future.value(_mock.acceptRequest(roomId));
  }

  Future<void> declineRequest(String roomId) {
    final live = _live;
    if (live != null) return live.declineRequest(roomId);
    _mock.declineRequest(roomId);
    return Future.value();
  }

  Future<List<ChatMessage>> messages(String roomId) {
    final live = _live;
    if (live != null) return live.messages(roomId);
    return Future.value(_mock.roomMessages(roomId));
  }

  Future<ChatRoom> sendMessageRequest({
    required String peerPseudonym,
    required String peerAvatarSeed,
    required String preview,
  }) async {
    final live = _live;
    if (live != null) {
      // For the live demo we ping a random known peer because we don't yet
      // surface their UUID through the UI. The post detail screen will pass
      // the author's user_id directly once user→user routing ships.
      final peer = await live.randomPeer();
      final peerId = peer?['user_id'] as String?;
      if (peerId == null) {
        throw StateError('No peer available to message');
      }
      return live.sendMessageRequest(peerUserId: peerId, preview: preview);
    }
    return _mock.sendMessageRequest(
      peerPseudonym: peerPseudonym,
      peerAvatarSeed: peerAvatarSeed,
      preview: preview,
    );
  }

  /// In live mode messages are encrypted client-side. For the V1 build we
  /// transmit plaintext so the demo conversation works end-to-end; once the
  /// double-ratchet rolls out we'll plug `CryptoService.encryptForRoom` here.
  Future<ChatMessage> sendMessage({required String roomId, required String plaintext}) {
    final live = _live;
    if (live != null) {
      return live.sendMessage(
        roomId: roomId,
        encryptedPayload: plaintext,
        nonceIv: 'v1-placeholder',
      );
    }
    return Future.value(
        _mock.sendMessage(roomId: roomId, plaintext: plaintext));
  }

  // ===================== Prompts =====================
  Future<List<PlugPrompt>> prompts() {
    final live = _live;
    if (live != null) return live.prompts();
    return Future.value(_mock.prompts());
  }

  // ===================== Notifications =====================
  Future<List<NotificationItem>> notifications() {
    final live = _live;
    if (live != null) return live.notifications();
    return Future.value(_mock.notifications());
  }

  int _ageFrom(DateTime birth) {
    final now = DateTime.now();
    var age = now.year - birth.year;
    final hasBirthdayPassed =
        now.month > birth.month || (now.month == birth.month && now.day >= birth.day);
    if (!hasBirthdayPassed) age -= 1;
    return age;
  }
}

class AgeGateBlocked implements Exception {
  @override
  String toString() =>
      'Vently requires members to be 13 or older to keep our community safe.';
}
