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

  /// Result of a successful sign-up. The caller surfaces [recoveryPhrase] to
  /// the user once and only once — it is never stored server-side and the
  /// only on-device copy is in secure storage.
  /// Create a new account from username + password + DOB. Generates a
  /// 12-word recovery phrase, seals the password into a blob with an
  /// Argon2id-derived key, and stores blob + salt on the user row so the
  /// account can be restored on any device with just the phrase.
  Future<({AppUser user, String recoveryPhrase})> registerAccount({
    required DateTime birthDate,
    required String username,
    required String password,
    required String avatarSeed,
  }) async {
    if (!IdentityService.usernamePattern.hasMatch(username)) {
      throw const FormatException(
        'Usernames are 3–20 letters/numbers/underscores.',
      );
    }
    if (password.length < 8) {
      throw const FormatException('Password must be at least 8 characters.');
    }
    final age = _ageFrom(birthDate);
    if (age < VentlyConfig.minAge) {
      throw AgeGateBlocked();
    }
    final tier =
        age <= VentlyConfig.restrictedMaxAge ? 'restricted_minor' : 'standard';

    final phrase = _identity.generateRecoveryPhrase();
    final sealed = await _identity.sealPassword(
      password: password,
      phrase: phrase,
    );

    final AppUser user;
    final live = _live;
    if (live != null) {
      user = await live.signUp(
        username: username,
        password: password,
        avatarSeed: avatarSeed,
        birthYear: birthDate.year,
        safetyTier: tier,
        recoveryBlob: sealed.blob,
        recoverySalt: sealed.salt,
      );
    } else {
      user = _mock.signUp(
        username: username,
        password: password,
        avatarSeed: avatarSeed,
        birthYear: birthDate.year,
        safetyTier: tier,
        recoveryBlob: sealed.blob,
        recoverySalt: sealed.salt,
      );
    }

    await _identity.persistSession(
      username: username,
      avatarSeed: avatarSeed,
      birthYear: birthDate.year,
      safetyTier: tier,
      recoveryPhrase: phrase,
    );
    return (user: user, recoveryPhrase: phrase);
  }

  /// Sign in an existing account.
  Future<AppUser> signIn({
    required String username,
    required String password,
  }) async {
    final AppUser user;
    final live = _live;
    if (live != null) {
      user = await live.signIn(username: username, password: password);
    } else {
      user = _mock.signIn(username: username, password: password);
    }
    await _identity.persistSession(
      username: user.anonymousPseudonym,
      avatarSeed: user.avatarSeed,
      birthYear: user.birthYear ?? DateTime.now().year - 18,
      safetyTier: user.safetyTier,
    );
    return user;
  }

  /// Recover access using the 12-word phrase. Fetches the encrypted blob,
  /// derives the key from the phrase, decrypts to the original password, and
  /// signs in. Returns null if the phrase doesn't match (the AES-GCM MAC
  /// fails) or no such username exists.
  Future<AppUser?> recoverWithPhrase({
    required String username,
    required String phrase,
  }) async {
    final live = _live;
    final material = live != null
        ? await live.fetchRecoveryMaterial(username)
        : _mock.fetchRecoveryMaterial(username);
    if (material == null) return null;
    final password = await _identity.openPassword(
      blob: material.blob,
      salt: material.salt,
      phrase: phrase,
    );
    if (password == null) return null;
    return signIn(username: username, password: password);
  }

  Future<AppUser?> restoreSession() async {
    final live = _live;
    if (live != null) {
      // Supabase persists the session token in secure storage; restore()
      // hydrates from it.
      return live.restore();
    }
    // Mock path — re-attach the locally remembered user, if any.
    final username = await _identity.lastUsername();
    if (username == null) return null;
    try {
      return _mock.signIn(
        username: username,
        // Mock backend trusts the in-memory password store; restoring after
        // hot-restart only works if the mock still has the credential.
        password: _mock.passwordOf(username) ?? '',
      );
    } catch (_) {
      return null;
    }
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
  Stream<List<Post>> watchFeed({
    String? category,
    String? mood,
    String? tribeSlug,
    String? locationBucket,
  }) {
    final live = _live;
    if (live != null) {
      // Seed the stream with an immediate fetch, then track realtime emits.
      final controller = StreamController<List<Post>>();
      late StreamSubscription<List<Post>> sub;
      Future<void> emit() async {
        controller.add(await live.feed(
          category: category,
          mood: mood,
          tribeSlug: tribeSlug,
          locationBucket: locationBucket,
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
          tribeSlug: tribeSlug,
          locationBucket: locationBucket,
        ));
  }

  Future<List<Post>> feed({
    String? category,
    String? mood,
    String? tribeSlug,
    String? locationBucket,
  }) {
    final live = _live;
    if (live != null) {
      return live.feed(
        category: category,
        mood: mood,
        tribeSlug: tribeSlug,
        locationBucket: locationBucket,
      );
    }
    return Future.value(_mock.feed(
      category: category,
      mood: mood,
      tribeSlug: tribeSlug,
      locationBucket: locationBucket,
    ));
  }

  // ===================== Profile location =====================
  Future<AppUser> updateMyLocation({
    String? homeCity,
    String? homeCountry,
    String? homeCampus,
  }) async {
    final live = _live;
    if (live != null) {
      return live.updateMyLocation(
        homeCity: homeCity,
        homeCountry: homeCountry,
        homeCampus: homeCampus,
      );
    }
    return Future.value(_mock.updateMyLocation(
      homeCity: homeCity,
      homeCountry: homeCountry,
      homeCampus: homeCampus,
    ));
  }

  // ===================== Co-mods =====================
  Future<List<TribeMemberRow>> tribeMembers(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeMembers(tribeId);
    return Future.value(_mock.tribeMembers(tribeId));
  }

  Future<void> promoteToMod({
    required String tribeId,
    required String userId,
  }) async {
    final live = _live;
    if (live != null) {
      return live.promoteToMod(tribeId: tribeId, userId: userId);
    }
    _mock.promoteToMod(tribeId: tribeId, userId: userId);
  }

  Future<void> demoteToMember({
    required String tribeId,
    required String userId,
  }) async {
    final live = _live;
    if (live != null) {
      return live.demoteToMember(tribeId: tribeId, userId: userId);
    }
    _mock.demoteToMember(tribeId: tribeId, userId: userId);
  }

  Future<void> kickMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) async {
    final live = _live;
    if (live != null) {
      return live.kickMember(
          tribeId: tribeId, userId: userId, reason: reason);
    }
    _mock.kickMember(tribeId: tribeId, userId: userId, reason: reason);
  }

  Future<void> transferKeeper({
    required String tribeId,
    required String toUserId,
  }) async {
    final live = _live;
    if (live != null) {
      return live.transferKeeper(tribeId: tribeId, toUserId: toUserId);
    }
    _mock.transferKeeper(tribeId: tribeId, toUserId: toUserId);
  }

  // ===================== Badges + streaks =====================
  Future<List<BadgeDefinition>> badgeCatalogue() {
    final live = _live;
    if (live != null) return live.badgeCatalogue();
    return Future.value(_mock.badgeCatalogue());
  }

  Future<List<UserBadge>> badgesFor(String userId) {
    final live = _live;
    if (live != null) return live.badgesFor(userId);
    return Future.value(_mock.badgesFor(userId));
  }

  Future<List<UserStreak>> myStreaks() {
    final live = _live;
    if (live != null) return live.myStreaks();
    return Future.value(_mock.myStreaks());
  }

  Future<Post> createPost({
    required String content,
    required String category,
    required String mood,
    String? tribeId,
    bool isWhisper = false,
  }) {
    final live = _live;
    if (live != null) {
      return live.createPost(
        content: content,
        category: category,
        mood: mood,
        tribeId: tribeId,
        isWhisper: isWhisper,
      );
    }
    return _mock.createPost(
      content: content,
      category: category,
      mood: mood,
      tribeId: tribeId,
      isWhisper: isWhisper,
    );
  }

  // ===================== User lookup =====================
  Future<({String userId, String pseudonym, String avatarSeed})?>
      findUserByPseudonym(String pseudonym) async {
    final live = _live;
    if (live != null) {
      final row = await live.findUserByPseudonym(pseudonym);
      if (row == null) return null;
      return (
        userId: row['user_id'] as String,
        pseudonym: row['anonymous_pseudonym'] as String,
        avatarSeed:
            (row['avatar_seed'] as String?) ?? 'default-orb',
      );
    }
    final u = _mock.findUserByPseudonym(pseudonym);
    if (u == null) return null;
    return (
      userId: u.userId,
      pseudonym: u.anonymousPseudonym,
      avatarSeed: u.avatarSeed,
    );
  }

  // ===================== Tribe invitations =====================

  Future<void> inviteToTribe({
    required String tribeId,
    required String invitedUserId,
    String? message,
  }) async {
    final live = _live;
    if (live != null) {
      return live.inviteToTribe(
        tribeId: tribeId,
        invitedUserId: invitedUserId,
        message: message,
      );
    }
    _mock.inviteToTribe(
      tribeId: tribeId,
      invitedUserId: invitedUserId,
      message: message,
    );
  }

  Future<List<TribeInvite>> myPendingInvites() {
    final live = _live;
    if (live != null) return live.myPendingInvites();
    return Future.value(_mock.myPendingInvites());
  }

  Future<void> respondToInvite({
    required String inviteId,
    required bool accept,
  }) async {
    final live = _live;
    if (live != null) {
      return live.respondToInvite(inviteId: inviteId, accept: accept);
    }
    _mock.respondToInvite(inviteId: inviteId, accept: accept);
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

  Future<void> reportPost({
    required String postId,
    required String reason,
    String? note,
  }) async {
    final live = _live;
    if (live != null) {
      return live.reportPost(postId: postId, reason: reason, note: note);
    }
    _mock.reportPost(postId: postId, reason: reason, note: note);
  }

  Future<void> reportChat({
    required String roomId,
    required String reason,
    String? note,
  }) async {
    final live = _live;
    if (live != null) {
      return live.reportChat(roomId: roomId, reason: reason, note: note);
    }
    _mock.reportChat(roomId: roomId, reason: reason, note: note);
  }

  // ===================== Keeper tools =====================

  Future<PlugPrompt> createPromptForTribe({
    required String tribeId,
    required String text,
  }) {
    final live = _live;
    if (live != null) {
      return live.createPromptForTribe(tribeId: tribeId, text: text);
    }
    return Future.value(
        _mock.createPromptForTribe(tribeId: tribeId, text: text));
  }

  Future<List<TribeReport>> tribeReports(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeReports(tribeId);
    return Future.value(_mock.tribeReports(tribeId));
  }

  Future<void> resolveReport(String reportId) async {
    final live = _live;
    if (live != null) return live.resolveReport(reportId);
    _mock.resolveReport(reportId);
  }

  Future<Tribe> updateTribe({
    required String tribeId,
    String? name,
    String? description,
    bool? isPrivate,
    String? avatarUrl,
    String? bannerUrl,
  }) {
    final live = _live;
    if (live != null) {
      return live.updateTribe(
        tribeId: tribeId,
        name: name,
        description: description,
        isPrivate: isPrivate,
        avatarUrl: avatarUrl,
        bannerUrl: bannerUrl,
      );
    }
    return Future.value(_mock.updateTribe(
      tribeId: tribeId,
      name: name,
      description: description,
      isPrivate: isPrivate,
      avatarUrl: avatarUrl,
      bannerUrl: bannerUrl,
    ));
  }

  // ===================== Polls =====================
  Future<PostPoll> createPoll({
    required String postId,
    required String question,
    required List<String> optionTexts,
    Duration closesIn = const Duration(days: 3),
  }) {
    final live = _live;
    if (live != null) {
      return live.createPoll(
        postId: postId,
        question: question,
        optionTexts: optionTexts,
        closesIn: closesIn,
      );
    }
    return Future.value(_mock.createPoll(
      postId: postId,
      question: question,
      optionTexts: optionTexts,
      closesIn: closesIn,
    ));
  }

  Future<PostPoll?> pollForPost(String postId) {
    final live = _live;
    if (live != null) return live.pollForPost(postId);
    return Future.value(_mock.pollForPost(postId));
  }

  Future<void> votePoll({
    required String pollId,
    required String optionId,
  }) async {
    final live = _live;
    if (live != null) {
      return live.votePoll(pollId: pollId, optionId: optionId);
    }
    _mock.votePoll(pollId: pollId, optionId: optionId);
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

  // ===================== Plugz (read-only metadata) =====================
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

  // ===================== Tribes =====================
  Future<List<Tribe>> tribes({String? category, String? search}) {
    final live = _live;
    if (live != null) return live.tribes(category: category, search: search);
    return Future.value(_mock.tribes(category: category, search: search));
  }

  Future<Tribe?> tribeBySlug(String slug) {
    final live = _live;
    if (live != null) return live.tribeBySlug(slug);
    return Future.value(_mock.tribeBySlug(slug));
  }

  Future<Tribe> createTribe({
    required String name,
    required String category,
    String? description,
    bool isPrivate = false,
  }) {
    final live = _live;
    if (live != null) {
      return live.createTribe(
        name: name,
        category: category,
        description: description,
        isPrivate: isPrivate,
      );
    }
    return Future.value(_mock.createTribe(
      name: name,
      category: category,
      description: description,
      isPrivate: isPrivate,
    ));
  }

  bool joinedTribe(String tribeId) {
    final live = _live;
    if (live != null) return live.joinedTribe(tribeId);
    return _mock.joinedTribe(tribeId);
  }

  Future<void> joinTribe(String tribeId) {
    final live = _live;
    if (live != null) return live.joinTribe(tribeId);
    _mock.joinTribe(tribeId);
    return Future.value();
  }

  Future<void> leaveTribe(String tribeId) {
    final live = _live;
    if (live != null) return live.leaveTribe(tribeId);
    _mock.leaveTribe(tribeId);
    return Future.value();
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

  /// Realtime per-room message stream. Mock mode replays the current list on
  /// every inbox-stream tick — good enough for offline development.
  Stream<List<ChatMessage>> watchMessages(String roomId) {
    final live = _live;
    if (live != null) return live.watchMessages(roomId);
    return _mock.roomsStream.map((_) => _mock.roomMessages(roomId));
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

  /// Private DM send. V1 is plaintext server-side so moderators can review
  /// reported chats; we do not advertise end-to-end encryption.
  Future<ChatMessage> sendMessage({required String roomId, required String plaintext}) {
    final live = _live;
    if (live != null) {
      return live.sendMessage(
        roomId: roomId,
        payload: plaintext,
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

  Future<List<PromptAnswer>> promptAnswers(String promptId) {
    final live = _live;
    if (live != null) return live.promptAnswers(promptId);
    return Future.value(_mock.promptAnswers(promptId));
  }

  Future<PromptAnswer> addPromptAnswer({
    required String promptId,
    required String text,
  }) {
    final live = _live;
    if (live != null) {
      return live.addPromptAnswer(promptId: promptId, text: text);
    }
    return Future.value(
        _mock.addPromptAnswer(promptId: promptId, text: text));
  }

  // ===================== Notifications =====================
  Future<List<NotificationItem>> notifications() {
    final live = _live;
    if (live != null) return live.notifications();
    return Future.value(_mock.notifications());
  }

  Future<void> markNotificationRead(String id) async {
    final live = _live;
    if (live != null) return live.markNotificationRead(id);
    _mock.markNotificationRead(id);
  }

  Future<void> markAllNotificationsRead() async {
    final live = _live;
    if (live != null) return live.markAllNotificationsRead();
    _mock.markAllNotificationsRead();
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
      'Venttly requires members to be 13 or older to keep our community safe.';
}
