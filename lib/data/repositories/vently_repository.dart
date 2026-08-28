import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/analytics_events.dart';
import '../../core/constants.dart';
import '../../domain/entities/entities.dart';
import '../../domain/home/home_discovery.dart';
import '../../domain/keeper/keeper_mode.dart';
import '../../domain/keeper/keeper_studio_v2.dart';
import '../../domain/tribe/tribe_chat_hub.dart';
import '../../domain/tribe/tribe_management.dart';
import '../services/analytics_service.dart';
import '../services/cache_service.dart';
import '../services/identity_service.dart';
import '../services/mock_backend.dart';
import '../services/supabase_backend.dart';
import '../services/telemetry_service.dart';

/// Single facade exposing the data layer to the UI.
///
/// Internally it forwards to either:
///   * [MockBackend]      — when `VentlyConfig.useMockBackend` is true
///   * [SupabaseBackend]  — when the live Supabase project is reachable
class VentlyRepository implements MusicProvider {
  VentlyRepository({
    MockBackend? mock,
    IdentityService? identity,
    bool forceMock = false,
  }) : _mockOverride = mock,
       _identity = identity ?? IdentityService(),
       _live = forceMock || VentlyConfig.useMockBackend
           ? null
           : SupabaseBackend.of(Supabase.instance.client);

  // Keep the populated development backend out of live processes entirely.
  // The getter is reached only from explicit mock-mode branches.
  final MockBackend? _mockOverride;
  MockBackend get _mock => _mockOverride ?? MockBackend.instance;
  final IdentityService _identity;
  final SupabaseBackend? _live;
  final CacheService _cache = CacheService();
  TelemetryService get _telemetry => TelemetryService.instance;

  Future<T> _trackSelfInteractionRejection<T>(
    String target,
    Future<T> Function() mutation,
  ) async {
    try {
      return await mutation();
    } on PostgrestException catch (error) {
      if (error.message.contains('self_interaction_not_allowed')) {
        unawaited(
          AnalyticsService.instance.track(
            Events.selfInteractionRejected,
            props: {'target_type': target},
          ),
        );
      }
      rethrow;
    }
  }

  IdentityService get identity => _identity;
  bool get isMockMode => _live == null;

  // ===================== Session =====================
  AppUser? get currentUser {
    final live = _live;
    return live != null ? live.me : _mock.me;
  }

  /// The identity held by the auth provider, available before profile
  /// hydration finishes during a restored session.
  String? get authenticatedUserId {
    final live = _live;
    return live != null ? live.authenticatedUserId : _mock.me?.userId;
  }

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
    final tier = age <= VentlyConfig.restrictedMaxAge
        ? 'restricted_minor'
        : 'standard';

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

  /// Email-based account creation. `user` is null when email
  /// confirmation is enabled on the Supabase project — the caller
  /// then routes to a "check your inbox" screen and the user finishes
  /// signing in after clicking the confirm link.
  Future<({AppUser? user, String recoveryPhrase})> registerAccountWithEmail({
    required DateTime birthDate,
    required String email,
    required String username,
    required String password,
    required String avatarSeed,
  }) async {
    if (!IdentityService.usernamePattern.hasMatch(username)) {
      throw const FormatException(
        'Usernames are 3–20 letters/numbers/underscores.',
      );
    }
    if (!_emailPattern.hasMatch(email)) {
      throw const FormatException('That doesn\'t look like a valid email.');
    }
    if (password.length < 8) {
      throw const FormatException('Password must be at least 8 characters.');
    }
    final age = _ageFrom(birthDate);
    if (age < VentlyConfig.minAge) {
      throw AgeGateBlocked();
    }
    final tier = age <= VentlyConfig.restrictedMaxAge
        ? 'restricted_minor'
        : 'standard';

    final phrase = _identity.generateRecoveryPhrase();
    final sealed = await _identity.sealPassword(
      password: password,
      phrase: phrase,
    );

    final live = _live;
    if (live == null) {
      throw StateError('Email signup needs the live backend.');
    }
    final user = await live.signUpWithEmail(
      email: email,
      password: password,
      username: username,
      avatarSeed: avatarSeed,
      birthYear: birthDate.year,
      safetyTier: tier,
      recoveryBlob: sealed.blob,
      recoverySalt: sealed.salt,
    );

    await _identity.persistSession(
      username: username,
      avatarSeed: avatarSeed,
      birthYear: birthDate.year,
      safetyTier: tier,
      recoveryPhrase: phrase,
    );
    return (user: user, recoveryPhrase: phrase);
  }

  /// Email-based sign-in. Mirrors [signIn] but with a real email.
  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final live = _live;
    if (live == null) {
      throw StateError('Email sign-in needs the live backend.');
    }
    final user = await live.signInWithEmail(email: email, password: password);
    await _identity.persistSession(
      username: user.anonymousPseudonym,
      avatarSeed: user.avatarSeed,
      birthYear: user.birthYear,
      safetyTier: user.safetyTier,
    );
    return user;
  }

  // ===================== Optional real-email verification =================

  /// True when the signed-in account uses a real email (vs an anonymous
  /// synthetic handle). Only these accounts are gated on verification.
  bool get hasRealEmail => _live?.hasRealEmail ?? false;

  String? get currentEmail => _live?.currentEmail;

  bool get isEmailVerified => currentUser?.emailVerified ?? false;

  /// Email + queue a fresh 6-digit verification code.
  Future<void> sendEmailVerification() async {
    final live = _live;
    if (live == null) return; // mock/dev: nothing to verify
    await live.sendEmailVerification();
  }

  /// Confirm a 6-digit code. Returns true when the email is now verified.
  Future<bool> confirmEmailVerification(String code) async {
    final live = _live;
    if (live == null) return true;
    return live.confirmEmailVerification(code.trim());
  }

  /// Re-read the verified flag from the backend (best-effort).
  Future<bool> refreshEmailVerified() async {
    final live = _live;
    if (live == null) return true;
    return live.refreshEmailVerified();
  }

  // ===================== Password & security ==============================

  /// Rotate the signed-in user's password (re-auths with the current one).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? recoveryPhrase,
  }) async {
    if (newPassword.length < 8) {
      throw const FormatException('Password must be at least 8 characters.');
    }
    if (newPassword == currentPassword) {
      throw const FormatException('Choose a password you haven\'t used here.');
    }
    final live = _live;
    if (live == null) return;
    await live.reauthenticate(currentPassword);

    final material = await live.myRecoveryMaterial();
    ({String blob, String salt})? rotated;
    String? phrase;
    if (material != null) {
      phrase = await _identity.savedRecoveryPhrase() ?? recoveryPhrase?.trim();
      if (phrase == null || phrase.isEmpty) {
        throw const FormatException(
          'Enter your 12-word recovery phrase on this device before changing the password.',
        );
      }
      final recoveredPassword = await _identity.openPassword(
        blob: material.blob,
        salt: material.salt,
        phrase: phrase,
      );
      if (recoveredPassword != currentPassword) {
        throw const FormatException('That recovery phrase is not correct.');
      }
      rotated = await _identity.sealPassword(
        password: newPassword,
        phrase: phrase,
      );
    }

    await _setPasswordWithReadback(
      live,
      intendedPassword: newPassword,
      fallbackPassword: currentPassword,
      ambiguityMessage:
          'The password service returned an uncertain result. Try signing in again before retrying.',
    );
    if (rotated != null) {
      try {
        await live.rotateRecoveryMaterial(
          blob: rotated.blob,
          salt: rotated.salt,
        );
      } catch (rotationError, rotationStack) {
        // A timeout can happen after Postgres committed. Read back before any
        // compensation so we never roll Auth back while leaving the new blob.
        final ({String blob, String salt}) observed;
        try {
          final value = await live.myRecoveryMaterial();
          if (value == null) throw StateError('Recovery material disappeared.');
          observed = value;
        } catch (_) {
          throw StateError(
            'Password changed but recovery status could not be confirmed. Sign out other sessions and contact support immediately.',
          );
        }
        final rotationCommitted =
            observed.blob == rotated.blob && observed.salt == rotated.salt;
        final oldMaterialIntact =
            material != null &&
            observed.blob == material.blob &&
            observed.salt == material.salt;
        if (!rotationCommitted) {
          if (!oldMaterialIntact) {
            throw StateError(
              'Password changed but recovery material is in an unexpected state. Contact support immediately.',
            );
          }
          try {
            await _setPasswordWithReadback(
              live,
              intendedPassword: currentPassword,
              fallbackPassword: newPassword,
              ambiguityMessage:
                  'Password changed but recovery rollback could not be confirmed. Contact support immediately.',
            );
          } catch (_) {
            throw StateError(
              'Password changed but recovery rotation failed. Sign out other sessions and contact support immediately.',
            );
          }
          Error.throwWithStackTrace(rotationError, rotationStack);
        }
      }
      await _identity.saveRecoveryPhrase(phrase!);
    }
  }

  /// Auth password updates are idempotent, but their HTTP response can be
  /// lost after commit. Confirm the intended credential before deciding that
  /// the operation failed; confirm the fallback before surfacing a safe error.
  Future<void> _setPasswordWithReadback(
    SupabaseBackend live, {
    required String intendedPassword,
    required String fallbackPassword,
    required String ambiguityMessage,
  }) async {
    try {
      await live.updateAuthenticatedPassword(intendedPassword);
      return;
    } catch (updateError, updateStack) {
      try {
        await live.reauthenticate(intendedPassword);
        return;
      } catch (_) {
        try {
          await live.reauthenticate(fallbackPassword);
        } catch (_) {
          throw StateError(ambiguityMessage);
        }
        Error.throwWithStackTrace(updateError, updateStack);
      }
    }
  }

  Future<bool> needsRecoveryPhraseForPasswordChange() async {
    final live = _live;
    if (live == null) return false;
    final material = await live.myRecoveryMaterial();
    if (material == null) return false;
    return await _identity.savedRecoveryPhrase() == null;
  }

  Future<void> reauthenticate(String password) async {
    if (password.isEmpty) {
      throw const FormatException('Enter your current password.');
    }
    final live = _live;
    if (live != null) return live.reauthenticate(password);
    if (!_mock.verifyCurrentPassword(password)) {
      throw const FormatException('That password is not correct.');
    }
  }

  /// Attach / change a real recovery email (Supabase emails a confirm link).
  Future<void> setRecoveryEmail(String email) async {
    final live = _live;
    if (live == null) return;
    await live.setRecoveryEmail(email);
  }

  /// Sign out of every device (revokes all refresh tokens).
  Future<void> signOutEverywhere() async {
    final live = _live;
    if (live == null) return logout();
    await live.signOutEverywhere();
  }

  // ===================== Optional social sign-in ==========================

  /// Launch Google OAuth. Returns false if the flow could not start.
  Future<bool> signInWithGoogle() async {
    final live = _live;
    if (live == null) {
      throw StateError('Google sign-in needs the live backend.');
    }
    return live.signInWithGoogle();
  }

  /// Send an SMS OTP to [phone] (E.164).
  Future<void> startPhoneOtp(String phone) async {
    final live = _live;
    if (live == null) {
      throw StateError('Phone sign-in needs the live backend.');
    }
    await live.startPhoneOtp(phone);
  }

  /// Verify the SMS OTP and finish sign-in.
  Future<AppUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    final live = _live;
    if (live == null) {
      throw StateError('Phone sign-in needs the live backend.');
    }
    final user = await live.verifyPhoneOtp(phone: phone, token: token);
    await _identity.persistSession(
      username: user.anonymousPseudonym,
      avatarSeed: user.avatarSeed,
      birthYear: user.birthYear,
      safetyTier: user.safetyTier,
    );
    return user;
  }

  Future<AppUser> completeAgeVerification(DateTime birthDate) async {
    final live = _live;
    if (live == null) {
      throw StateError('Age verification needs the live backend.');
    }
    final user = await live.setMyBirthYear(birthDate.year);
    await _identity.persistSession(
      username: user.anonymousPseudonym,
      avatarSeed: user.avatarSeed,
      birthYear: user.birthYear,
      safetyTier: user.safetyTier,
    );
    return user;
  }

  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

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
      birthYear: user.birthYear,
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
    _cache.clear();
    unawaited(_telemetry.event('logout'));
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
    String sort = 'fresh',
  }) {
    final live = _live;
    if (live != null) {
      final controller = StreamController<List<Post>>();
      late StreamSubscription<List<Post>> sub;
      Future<void> emit() async {
        controller.add(
          await live.feed(
            category: category,
            mood: mood,
            tribeSlug: tribeSlug,
            locationBucket: locationBucket,
            sort: sort,
          ),
        );
      }

      sub = live.postsStream.listen((_) => emit());
      controller.onListen = emit;
      controller.onCancel = () => sub.cancel();
      return controller.stream;
    }
    return _mockSnapshotStream(
      _mock.postsStream,
      () => _mock.feed(
        category: category,
        mood: mood,
        tribeSlug: tribeSlug,
        locationBucket: locationBucket,
        sort: sort,
      ),
    );
  }

  /// Mock streams are bare broadcast controllers: they only emit on writes,
  /// so a listener that subscribes after the last write waits forever. Wrap
  /// them so every subscription gets the current snapshot immediately.
  Stream<T> _mockSnapshotStream<T>(
    Stream<dynamic> ticks,
    T Function() snapshot,
  ) {
    final controller = StreamController<T>();
    late StreamSubscription<dynamic> sub;
    void emit() => controller.add(snapshot());
    sub = ticks.listen((_) => emit());
    controller.onListen = emit;
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  Future<List<Post>> feed({
    String? category,
    String? mood,
    String? tribeSlug,
    String? locationBucket,
    String sort = 'fresh',
    int limit = 30,
    int offset = 0,
  }) {
    final live = _live;
    if (live != null) {
      return live.feed(
        category: category,
        mood: mood,
        tribeSlug: tribeSlug,
        locationBucket: locationBucket,
        sort: sort,
        limit: limit,
        offset: offset,
      );
    }
    return Future.value(
      _mock.feed(
        category: category,
        mood: mood,
        tribeSlug: tribeSlug,
        locationBucket: locationBucket,
        sort: sort,
        limit: limit,
        offset: offset,
      ),
    );
  }

  Future<List<Post>> friendStories({int limit = 24}) async {
    final live = _live;
    if (live != null) return live.friendStories(limit: limit);
    final me = _mock.me;
    if (me == null) return const <Post>[];
    final friends = await _mock.myFriends();
    final friendIds = friends.map((f) => f.userId).toSet();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final stories = _mock
        .feed(sort: 'hot', limit: limit * 4)
        .where(
          (p) =>
              p.isStory &&
              p.authorId != null &&
              p.createdAt.isAfter(cutoff) &&
              (p.authorId == me.userId || friendIds.contains(p.authorId)),
        )
        .take(limit)
        .toList();
    return stories;
  }

  // ===================== Profile location =====================
  Future<AppUser> updateMyAvatar(String seed) {
    final live = _live;
    if (live != null) return live.updateMyAvatar(seed);
    return Future.value(_mock.updateMyAvatar(seed));
  }

  /// Friends who are around right now. Empty on the mock backend, which has no
  /// presence.
  Future<List<OnlineFriend>> onlineFriends({int limit = 12}) {
    final live = _live;
    if (live == null) return Future.value(const <OnlineFriend>[]);
    return live.onlineFriends(limit: limit);
  }

  /// Profile background image. Falls back to the current session on the mock
  /// backend, which has no storage.
  Future<AppUser> uploadMyProfileBanner({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
    double offset = 0.5,
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadMyProfileBanner(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
        offset: offset,
      );
    }
    // The mock backend has no storage; the banner is a no-op there.
    return Future.value(_mock.removeMyProfilePhoto());
  }

  /// Re-anchor the banner crop. No-ops on the mock backend.
  Future<AppUser> setMyProfileBannerOffset(double offset) {
    final live = _live;
    if (live == null) return Future.value(_mock.removeMyProfilePhoto());
    return live.setMyProfileBannerOffset(offset);
  }

  Future<AppUser> removeMyProfileBanner() {
    final live = _live;
    if (live != null) return live.removeMyProfileBanner();
    return Future.value(_mock.removeMyProfilePhoto());
  }

  /// Clears my banner only when the object behind it is provably gone. See
  /// [SupabaseBackend.healMyProfileBannerIfMissing] for why it is that strict.
  /// Returns true when the row changed.
  Future<bool> healMyProfileBannerIfMissing() {
    final live = _live;
    if (live == null) return Future.value(false);
    return live.healMyProfileBannerIfMissing();
  }

  Future<AppUser> uploadMyProfilePhoto({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadMyProfilePhoto(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return Future.value(
      _mock.uploadMyProfilePhoto(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      ),
    );
  }

  Future<AppUser> removeMyProfilePhoto() {
    final live = _live;
    if (live != null) return live.removeMyProfilePhoto();
    return Future.value(_mock.removeMyProfilePhoto());
  }

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
    return Future.value(
      _mock.updateMyLocation(
        homeCity: homeCity,
        homeCountry: homeCountry,
        homeCampus: homeCampus,
      ),
    );
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
      return live.kickMember(tribeId: tribeId, userId: userId, reason: reason);
    }
    _mock.kickMember(tribeId: tribeId, userId: userId, reason: reason);
  }

  /// Remove AND block from rejoining (rule enforcement, migration 0071).
  Future<void> banMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) async {
    final live = _live;
    if (live != null) {
      return live.banMember(tribeId: tribeId, userId: userId, reason: reason);
    }
    _mock.kickMember(tribeId: tribeId, userId: userId, reason: reason);
  }

  Future<void> unbanMember({
    required String tribeId,
    required String userId,
  }) async {
    final live = _live;
    if (live != null) {
      return live.unbanMember(tribeId: tribeId, userId: userId);
    }
  }

  Future<List<Map<String, dynamic>>> tribeBans(String tribeId) async {
    final live = _live;
    if (live != null) return live.tribeBans(tribeId);
    return const [];
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
  /// Badge catalogue is effectively immutable per release — long TTL.
  Future<List<BadgeDefinition>> badgeCatalogue() {
    return _cache.getOrLoad('badge_catalogue', () async {
      final live = _live;
      if (live != null) return live.badgeCatalogue();
      return _mock.badgeCatalogue();
    }, ttl: const Duration(hours: 6));
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
    String? spaceId,
    String? personaId,
    bool isWhisper = false,
    bool isStory = false,
    String storyAudience = 'everyone',
    String? imagePath,
    String? imageUrl,
    String? audioPath,
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
    String? idempotencyKey,
  }) async {
    final live = _live;
    final Post post;
    if (live != null) {
      post = await live.createPost(
        content: content,
        category: category,
        mood: mood,
        tribeId: tribeId,
        spaceId: spaceId,
        personaId: personaId,
        isWhisper: isWhisper,
        isStory: isStory,
        storyAudience: storyAudience,
        imagePath: imagePath,
        imageUrl: imageUrl,
        audioPath: audioPath,
        audioUrl: audioUrl,
        audioDurationSeconds: audioDurationSeconds,
        pollQuestion: pollQuestion,
        pollOptions: pollOptions,
        cardBackgroundColor: cardBackgroundColor,
        cardTextColor: cardTextColor,
        musicTrack: musicTrack,
        musicStartMs: musicStartMs,
        musicDurationMs: musicDurationMs,
        musicVolume: musicVolume,
        idempotencyKey: idempotencyKey,
      );
    } else {
      post = await _mock.createPost(
        content: content,
        category: category,
        mood: mood,
        tribeId: tribeId,
        spaceId: spaceId,
        personaId: personaId,
        isWhisper: isWhisper,
        isStory: isStory,
        storyAudience: storyAudience,
        imageUrl: imageUrl,
        audioUrl: audioUrl,
        audioDurationSeconds: audioDurationSeconds,
        pollQuestion: pollQuestion,
        pollOptions: pollOptions,
        cardBackgroundColor: cardBackgroundColor,
        cardTextColor: cardTextColor,
        musicTrack: musicTrack,
        musicStartMs: musicStartMs,
        musicDurationMs: musicDurationMs,
        musicVolume: musicVolume,
      );
    }
    // PII rule: never ship `content` — only its dimensions.
    AnalyticsService.instance.track(
      (isStory || isWhisper) ? Events.storyPublished : Events.postCreated,
      props: {
        'category': category,
        'mood': mood,
        'has_image': imageUrl != null,
        'has_audio': audioUrl != null,
        'has_music': musicTrack != null,
        if (musicTrack != null) 'music_provider': musicTrack.provider,
        'has_tribe': tribeId != null,
        'has_persona': personaId != null,
        'has_poll': pollQuestion != null,
        'is_story': isStory,
        'story_audience': isStory ? storyAudience : null,
        'content_chars': content.length,
      },
    );
    return post;
  }

  // ===================== Premium home (migration 0038) =====================

  Future<HomeStats> homeStats() {
    final live = _live;
    if (live != null) return live.homeStats();
    return Future.value(_mock.homeStats());
  }

  Future<List<TrendingCategory>> trendingCategories({int limit = 6}) {
    final live = _live;
    if (live != null) return live.trendingCategories(limit: limit);
    return Future.value(_mock.trendingCategories(limit: limit));
  }

  Future<List<TrendingTopic>> trendingTopicStats({int limit = 8}) {
    final live = _live;
    if (live != null) return live.trendingTopicStats(limit: limit);
    final posts = _mock.feed(sort: 'hot', limit: 100000);
    return Future.value(HomeDiscovery.topicStatsFromPosts(posts, limit: limit));
  }

  Future<List<TrendingVoice>> trendingVoices({int limit = 6}) {
    final live = _live;
    if (live != null) return live.trendingVoices(limit: limit);
    return Future.value(_mock.trendingVoices(limit: limit));
  }

  Future<bool> markStoryViewed(String postId) {
    final live = _live;
    if (live != null) return live.markStoryViewed(postId);
    return Future.value(_mock.markStoryViewed(postId));
  }

  Future<bool> storyRepliesEnabled() {
    final live = _live;
    if (live != null) return live.storyRepliesEnabled();
    return Future.value(true);
  }

  Future<bool> setStoryRepliesEnabled(bool enabled) {
    final live = _live;
    if (live != null) return live.setStoryRepliesEnabled(enabled);
    return Future.value(enabled);
  }

  /// Whether the signed-in user may START a new DM with [targetUserId].
  /// Mock mode has no tier data, so it permits — matching canReplyToStory.
  Future<bool> canInitiateDm(String targetUserId) {
    final live = _live;
    if (live != null) return live.canInitiateDm(targetUserId);
    return Future.value(true);
  }

  Future<bool> canReplyToStory(String postId) {
    final live = _live;
    if (live != null) return live.canReplyToStory(postId);
    return Future.value(true);
  }

  Future<List<StoryReactionUser>> storyReactions(String postId) {
    final live = _live;
    if (live != null) return live.storyReactions(postId);
    return Future.value(const []);
  }

  Future<List<SearchHit>> searchGlobal(String query, {int limit = 24}) {
    final live = _live;
    if (live != null) return live.searchGlobal(query, limit: limit);
    return Future.value(_mock.searchGlobal(query, limit: limit));
  }

  @override
  Future<List<MusicTrack>> searchMusic({
    String query = '',
    String? mood,
    int limit = 24,
    int offset = 0,
  }) {
    final live = _live;
    if (live == null) {
      return Future.value(
        _mock.searchMusic(
          query: query,
          mood: mood,
          limit: limit,
          offset: offset,
        ),
      );
    }
    return live.searchMusic(
      query: query,
      mood: mood,
      limit: limit,
      offset: offset,
    );
  }

  Future<List<MusicTrack>> musicCatalogSection(
    String section, {
    int limit = 12,
  }) {
    final live = _live;
    if (live == null) {
      return Future.value(_mock.musicCatalogSection(section, limit: limit));
    }
    return live.musicCatalogSection(section, limit: limit);
  }

  Future<void> setPostMusic(
    String postId, {
    MusicTrack? track,
    int startMs = 0,
    int durationMs = 15000,
    double volume = 0.75,
  }) {
    final live = _live;
    if (live == null) {
      _mock.setPostMusic(
        postId,
        track: track,
        startMs: startMs,
        durationMs: durationMs,
        volume: volume,
      );
      return Future.value();
    }
    return live.setPostMusic(
      postId,
      track: track,
      startMs: startMs,
      durationMs: durationMs,
      volume: volume,
    );
  }

  Future<({String path, String url})> uploadPostImage({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) async {
    final live = _live;
    if (live != null) {
      return live.uploadPostImage(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return _mock.uploadPostImage(
      bytes: bytes,
      extension: extension,
      contentType: contentType,
    );
  }

  // ===================== Personas =====================
  Future<List<Persona>> myPersonas() {
    final live = _live;
    if (live != null) return live.myPersonas();
    return Future.value(_mock.myPersonas());
  }

  Future<Persona> createPersona({
    required String pseudonym,
    required String avatarSeed,
    String? bio,
  }) {
    final live = _live;
    if (live != null) {
      return live.createPersona(
        pseudonym: pseudonym,
        avatarSeed: avatarSeed,
        bio: bio,
      );
    }
    return _mock.createPersona(
      pseudonym: pseudonym,
      avatarSeed: avatarSeed,
      bio: bio,
    );
  }

  Future<Persona> updatePersona({
    required String personaId,
    required String pseudonym,
    required String avatarSeed,
    String? bio,
  }) {
    final live = _live;
    if (live != null) {
      return live.updatePersona(
        personaId: personaId,
        pseudonym: pseudonym,
        avatarSeed: avatarSeed,
        bio: bio,
      );
    }
    return _mock.updatePersona(
      personaId: personaId,
      pseudonym: pseudonym,
      avatarSeed: avatarSeed,
      bio: bio,
    );
  }

  Future<bool> deletePersona(String personaId) {
    final live = _live;
    if (live != null) return live.deletePersona(personaId);
    return _mock.deletePersona(personaId);
  }

  Future<void> setPostCrisis(String postId, String level) {
    final live = _live;
    if (live != null) return live.setPostCrisis(postId, level);
    return _mock.setPostCrisis(postId, level);
  }

  Future<void> setTribeMessageCrisis(String messageId, String level) {
    final live = _live;
    if (live != null) return live.setTribeMessageCrisis(messageId, level);
    return Future.value();
  }

  Future<void> setChatMessageCrisis(String messageId, String level) {
    final live = _live;
    if (live != null) return live.setChatMessageCrisis(messageId, level);
    return Future.value();
  }

  Future<List<CrisisHelpline>> crisisResources({String? region}) {
    final live = _live;
    if (live != null) return live.crisisResources(region: region);
    return _mock.crisisResources(region: region);
  }

  Future<List<AutomodRule>> automodRules() {
    final live = _live;
    if (live != null) return live.automodRules();
    return Future.value(const <AutomodRule>[]);
  }

  Future<Map<String, dynamic>?> moderateRemote(String text) {
    final live = _live;
    if (live != null) return live.moderateRemote(text);
    return Future.value(null);
  }

  Future<Map<String, dynamic>> exportMyData() {
    final live = _live;
    if (live != null) return live.exportMyData();
    return Future.value(<String, dynamic>{});
  }

  // ===================== Friends graph =====================

  Future<FriendStatus> friendStatus(String otherUserId) {
    final live = _live;
    if (live != null) return live.friendStatus(otherUserId);
    return _mock.friendStatus(otherUserId);
  }

  Future<String> sendFriendRequest(String otherUserId, {String? note}) async {
    final live = _live;
    final id = live != null
        ? await live.sendFriendRequest(otherUserId, note: note)
        : await _mock.sendFriendRequest(otherUserId, note: note);
    AnalyticsService.instance.track(
      Events.friendRequestSent,
      props: {'has_note': note != null && note.trim().isNotEmpty},
    );
    return id;
  }

  Future<void> acceptFriendRequest(String friendshipId) {
    final live = _live;
    if (live != null) return live.acceptFriendRequest(friendshipId);
    return _mock.acceptFriendRequest(friendshipId);
  }

  Future<void> declineFriendRequest(String friendshipId) {
    final live = _live;
    if (live != null) return live.declineFriendRequest(friendshipId);
    return _mock.declineFriendRequest(friendshipId);
  }

  /// Re-read a conversation in place. Prefer this to invalidating the stream
  /// provider after a send: invalidating disposes the stream, which blanks the
  /// list for a frame and refetches from scratch.
  /// Fresh media_status for whispers whose background is still being scanned.
  Future<Map<String, String>> whisperMediaStatuses(List<String> ids) {
    final live = _live;
    if (live == null) return Future.value(const {});
    return live.whisperMediaStatuses(ids);
  }

  Future<TribeCreationEligibility> tribeCreationEligibility() {
    final live = _live;
    if (live == null) {
      return Future.value(
        const TribeCreationEligibility(status: 'adult', tribesKept: 0),
      );
    }
    return live.tribeCreationEligibility();
  }

  Future<TribeCreationEligibility> setMyBirthMonth(int month) {
    final live = _live;
    if (live == null) {
      return Future.value(
        const TribeCreationEligibility(status: 'adult', tribesKept: 0),
      );
    }
    return live.setMyBirthMonth(month);
  }

  Future<void> refreshMessages(String roomId) {
    final live = _live;
    if (live == null) return Future.value();
    return live.refreshMessages(roomId);
  }

  Future<void> refreshTribeMessages(String tribeId) {
    final live = _live;
    if (live == null) return Future.value();
    return live.refreshTribeMessages(tribeId);
  }

  Future<void> unfriend(String otherUserId) {
    final live = _live;
    if (live != null) return live.unfriend(otherUserId);
    return _mock.unfriend(otherUserId);
  }

  Future<void> blockUser(String otherUserId, {String? reason}) {
    final live = _live;
    if (live != null) return live.blockUser(otherUserId, reason: reason);
    return _mock.blockUser(otherUserId, reason: reason);
  }

  Future<void> unblockUser(String otherUserId) {
    final live = _live;
    if (live != null) return live.unblockUser(otherUserId);
    return _mock.unblockUser(otherUserId);
  }

  Future<DmRoomPrefs> dmRoomPrefs(String roomId) {
    final live = _live;
    if (live != null) return live.dmRoomPrefs(roomId);
    return Future.value(DmRoomPrefs.empty);
  }

  Future<void> setDmRoomPref({
    required String roomId,
    bool? muted,
    String? peerNickname,
    bool clearNickname = false,
    int? disappearingSeconds,
    String? theme,
    String? fontStyle,
  }) {
    final live = _live;
    if (live != null) {
      return live.setDmRoomPref(
        roomId: roomId,
        muted: muted,
        peerNickname: peerNickname,
        clearNickname: clearNickname,
        disappearingSeconds: disappearingSeconds,
        theme: theme,
        fontStyle: fontStyle,
      );
    }
    return Future.value();
  }

  Future<int> roomDisappearingSeconds(String roomId) {
    final live = _live;
    if (live != null) return live.roomDisappearingSeconds(roomId);
    return Future.value(0);
  }

  Future<void> setRoomDisappearing(String roomId, int seconds) {
    final live = _live;
    if (live != null) return live.setRoomDisappearing(roomId, seconds);
    return Future.value();
  }

  Future<List<FriendSummary>> myFriends() {
    final live = _live;
    if (live != null) return live.myFriends();
    return _mock.myFriends();
  }

  Future<bool> toggleFriendFavorite(String friendshipId) {
    final live = _live;
    if (live != null) return live.toggleFriendFavorite(friendshipId);
    return Future.value(false);
  }

  Future<List<FriendSuggestion>> friendSuggestions({int limit = 6}) {
    final live = _live;
    if (live != null) return live.friendSuggestions(limit: limit);
    return Future.value(const <FriendSuggestion>[]);
  }

  // ===================== Tribe group chat (migration 0041) =====================

  Future<List<TribeMessage>> tribeMessages(String tribeId, {int limit = 80}) {
    final live = _live;
    if (live != null) return live.tribeMessages(tribeId, limit: limit);
    return Future.value(const <TribeMessage>[]);
  }

  Stream<List<TribeMessage>> watchTribeMessages(String tribeId) {
    final live = _live;
    if (live != null) return live.watchTribeMessages(tribeId);
    return const Stream<List<TribeMessage>>.empty();
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
    String? idempotencyKey,
  }) {
    final live = _live;
    if (live != null) {
      return live.sendTribeMessage(
        tribeId: tribeId,
        content: content,
        personaId: personaId,
        imagePath: imagePath,
        imageUrl: imageUrl,
        audioPath: audioPath,
        audioUrl: audioUrl,
        audioDurationSeconds: audioDurationSeconds,
        replyToMessageId: replyToMessageId,
        metadata: metadata,
        idempotencyKey: idempotencyKey,
      );
    }
    return Future.value('mock-message-id');
  }

  Future<void> voteTribeChatPoll({
    required String messageId,
    required String optionId,
  }) {
    final live = _live;
    if (live != null) {
      return live.voteTribeChatPoll(messageId: messageId, optionId: optionId);
    }
    return Future.value();
  }

  Future<void> closeTribeChatPoll(String messageId) {
    final live = _live;
    if (live != null) return live.closeTribeChatPoll(messageId);
    return Future.value();
  }

  Future<void> setTribeMessageReaction({
    required String messageId,
    required String emoji,
  }) {
    final live = _live;
    if (live != null) {
      return live.setTribeMessageReaction(messageId: messageId, emoji: emoji);
    }
    return Future.value();
  }

  Future<({String path, String url})> uploadTribeChatImage({
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadTribeChatImage(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return Future.value((path: 'mock/path.jpg', url: 'mock://chat/path.jpg'));
  }

  Future<int> tribeChatPresence(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeChatPresence(tribeId);
    return Future.value(0);
  }

  Future<void> tribeChatHeartbeat(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeChatHeartbeat(tribeId);
    return Future.value();
  }

  Future<List<TribeOnlineMember>> tribeOnlineMembers(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeOnlineMembers(tribeId);
    return Future.value(const []);
  }

  Future<void> setTribeAvatar({
    required String tribeId,
    required String avatarUrl,
  }) {
    final live = _live;
    if (live != null) {
      return live.setTribeAvatar(tribeId: tribeId, avatarUrl: avatarUrl);
    }
    return Future.value();
  }

  Future<({String path, String url})> uploadTribeAvatar({
    required String tribeId,
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadTribeAvatar(
        tribeId: tribeId,
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return Future.value((path: 'mock/tribe.jpg', url: 'mock://tribe.jpg'));
  }

  Future<({String path, String url})> uploadTribeChatAudio({
    required List<int> bytes,
    String extension = 'm4a',
    String contentType = 'audio/mp4',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadTribeChatAudio(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return Future.value((path: 'mock/audio.m4a', url: 'mock://audio.m4a'));
  }

  Future<void> setTribeChatSettings({
    required String tribeId,
    required Map<String, dynamic> patch,
  }) {
    final live = _live;
    if (live != null) {
      return live.setTribeChatSettings(tribeId: tribeId, patch: patch);
    }
    return Future.value();
  }

  Future<void> markTribeChatRead(String tribeId) {
    final live = _live;
    if (live != null) return live.markTribeChatRead(tribeId);
    return Future.value();
  }

  Future<List<TribeChatInboxSummary>> tribeChatInbox() {
    final live = _live;
    if (live != null) return live.tribeChatInbox();
    return Future.value(const []);
  }

  Future<List<TribeChatMediaItem>> tribeChatMedia(
    String tribeId, {
    int limit = 60,
  }) {
    final live = _live;
    if (live != null) return live.tribeChatMedia(tribeId, limit: limit);
    return Future.value(const []);
  }

  Future<void> pinTribeMessage({
    required String tribeId,
    required String messageId,
  }) {
    final live = _live;
    if (live != null) {
      return live.pinTribeMessage(tribeId: tribeId, messageId: messageId);
    }
    return Future.value();
  }

  Future<void> unpinTribeMessage(String tribeId) {
    final live = _live;
    if (live != null) return live.unpinTribeMessage(tribeId);
    return Future.value();
  }

  Future<({bool hugged, int hugsCount})> toggleTribeMessageHug(
    String messageId,
  ) {
    final live = _live;
    if (live != null) return live.toggleTribeMessageHug(messageId);
    return Future.value((hugged: false, hugsCount: 0));
  }

  void broadcastTribeTyping(String tribeId, {required String pseudonym}) {
    _live?.broadcastTribeTyping(tribeId, pseudonym: pseudonym);
  }

  Stream<List<TribeTypingUser>> watchTribeTyping(String tribeId) {
    final live = _live;
    if (live != null) return live.watchTribeTyping(tribeId);
    return const Stream.empty();
  }

  // ===================== Plugz V2 moderation (0045) =====================

  Future<List<TribeKeywordFilter>> tribeKeywordFilters(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeKeywordFilters(tribeId);
    return Future.value(const <TribeKeywordFilter>[]);
  }

  Future<String?> addKeywordFilter({
    required String tribeId,
    required String keyword,
    String severity = 'soft',
  }) async {
    final live = _live;
    if (live == null) return null;
    return live.addKeywordFilter(
      tribeId: tribeId,
      keyword: keyword,
      severity: severity,
    );
  }

  Future<void> removeKeywordFilter(String filterId) async {
    final live = _live;
    if (live == null) return;
    return live.removeKeywordFilter(filterId);
  }

  Future<List<TribeMemberWarning>> tribeMemberWarnings(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeMemberWarnings(tribeId);
    return Future.value(const <TribeMemberWarning>[]);
  }

  Future<String?> warnMember({
    required String tribeId,
    required String memberId,
    required String reason,
    String severity = 'warning',
  }) async {
    final live = _live;
    if (live == null) return null;
    return live.warnMember(
      tribeId: tribeId,
      memberId: memberId,
      reason: reason,
      severity: severity,
    );
  }

  Future<void> setTribeRules({
    required String tribeId,
    required Map<String, dynamic> rules,
  }) async {
    final live = _live;
    if (live == null) return;
    return live.setTribeRules(tribeId: tribeId, rules: rules);
  }

  // ===================== Whispers (migration 0042) =====================

  /// Pass the caller's last row as the cursor; omit it for the first page.
  Future<List<Whisper>> listWhispers({
    int limit = 30,
    String? category,
    DateTime? beforeCreatedAt,
    String? beforeWhisperId,
  }) {
    final live = _live;
    if (live != null) {
      return live.listWhispers(
        limit: limit,
        category: category,
        beforeCreatedAt: beforeCreatedAt,
        beforeWhisperId: beforeWhisperId,
      );
    }
    return Future.value(const <Whisper>[]);
  }

  Future<List<Whisper>> whispersForAuthor(String userId, {int limit = 12}) {
    final live = _live;
    if (live != null) return live.whispersForAuthor(userId, limit: limit);
    return Future.value(const <Whisper>[]);
  }

  Future<bool> toggleWhisperLike(String whisperId) {
    final live = _live;
    if (live != null) return live.toggleWhisperLike(whisperId);
    return Future.value(false);
  }

  Future<String?> reactToWhisper(String whisperId, String reaction) async {
    final live = _live;
    if (live != null) {
      return _trackSelfInteractionRejection(
        'whisper',
        () => live.reactToWhisper(whisperId, reaction),
      );
    }
    return Future.value(_mock.reactToWhisper(whisperId, reaction));
  }

  Future<void> bumpWhisperPlays(String whisperId) {
    final live = _live;
    if (live != null) return live.bumpWhisperPlays(whisperId);
    return Future.value();
  }

  /// Capture a real listen (dedup per user; first listen bumps plays_count).
  Future<void> recordWhisperListen(String whisperId) {
    final live = _live;
    if (live != null) return live.recordWhisperListen(whisperId);
    return Future.value();
  }

  /// Public tribes a user belongs to (private ones only visible to fellow
  /// members). Powers the Tribes section on a public profile.
  Future<List<Tribe>> userPublicTribes(String userId) {
    final live = _live;
    if (live != null) return live.userPublicTribes(userId);
    return Future.value(const <Tribe>[]);
  }

  /// Reversible: hides the account app-wide until next login.
  Future<void> deactivateMyAccount() {
    final live = _live;
    if (live != null) return live.deactivateMyAccount();
    return Future.value();
  }

  /// Starts the 30-day deletion grace period (deactivates immediately).
  Future<void> requestAccountDeletion() {
    final live = _live;
    if (live != null) return live.requestAccountDeletion();
    return Future.value();
  }

  /// Restores a deactivated account / cancels a pending deletion on login.
  Future<void> reactivateMyAccount() {
    final live = _live;
    if (live != null) return live.reactivateMyAccount();
    return Future.value();
  }

  /// Update the signed-in user's public profile. Mock backend is a no-op that
  /// echoes the current user.
  Future<AppUser?> updateMyProfile({
    String? pseudonym,
    String? displayName,
    String? bio,
    String? pronouns,
    String? profilePhotoUrl,
    String? homeCity,
    bool clearPhoto = false,
    bool clearBio = false,
    bool clearPronouns = false,
  }) async {
    final live = _live;
    if (live != null) {
      final updated = await live.updateMyProfile(
        pseudonym: pseudonym,
        displayName: displayName,
        bio: bio,
        pronouns: pronouns,
        profilePhotoUrl: profilePhotoUrl,
        homeCity: homeCity,
        clearPhoto: clearPhoto,
        clearBio: clearBio,
        clearPronouns: clearPronouns,
      );
      if (displayName != null) {
        unawaited(AnalyticsService.instance.track(Events.displayNameUpdated));
      }
      return updated;
    }
    return _mock.me;
  }

  Future<List<WhisperComment>> listWhisperComments(
    String whisperId, {
    int limit = 50,
    int offset = 0,
  }) {
    final live = _live;
    if (live != null) {
      return live.listWhisperComments(whisperId, limit: limit, offset: offset);
    }
    return Future.value(const <WhisperComment>[]);
  }

  Stream<List<WhisperComment>> watchWhisperComments(String whisperId) {
    final live = _live;
    if (live != null) return live.watchWhisperComments(whisperId);
    return Stream.value(const <WhisperComment>[]);
  }

  Future<String> addWhisperComment(
    String whisperId,
    String content, {
    String? personaId,
    String? parentId,
    String? idempotencyKey,
  }) {
    final live = _live;
    if (live != null) {
      return live.addWhisperComment(
        whisperId,
        content,
        personaId: personaId,
        parentId: parentId,
        idempotencyKey: idempotencyKey,
      );
    }
    return Future.value('mock-comment-id');
  }

  /// Resolve an @handle to a user or tribe.
  Future<ResolvedTag?> resolveTag(String handle) {
    final live = _live;
    if (live != null) return live.resolveTag(handle);
    return Future.value(null);
  }

  /// @-autocomplete candidates for tagging.
  Future<List<TagCandidate>> searchTagCandidates(String prefix) {
    final live = _live;
    if (live != null) return live.searchTagCandidates(prefix);
    return Future.value(const <TagCandidate>[]);
  }

  /// Server-evaluated feature flags (flag_key -> enabled for this user).
  Future<Map<String, bool>> myFeatureFlags() {
    final live = _live;
    if (live != null) return live.myFeatureFlags();
    return Future.value(const <String, bool>{'vent_music': true});
  }

  /// Live flag map — refetches when any flag row changes.
  Stream<Map<String, bool>> watchFeatureFlags() {
    final live = _live;
    if (live != null) return live.watchFeatureFlags();
    return Stream.value(const <String, bool>{'vent_music': true});
  }

  /// Typo-tolerant search typeahead.
  Future<List<SearchSuggestion>> searchSuggestions(String prefix) {
    final live = _live;
    if (live != null) return live.searchSuggestions(prefix);
    return Future.value(const <SearchSuggestion>[]);
  }

  /// Busiest categories/tribes of the last 24h.
  Future<List<SearchSuggestion>> trendingSearches() {
    final live = _live;
    if (live != null) return live.trendingSearches();
    return Future.value(const <SearchSuggestion>[]);
  }

  /// Delete a whisper comment (author or whisper owner).
  Future<bool> deleteWhisperComment(String commentId) {
    final live = _live;
    if (live != null) return live.deleteWhisperComment(commentId);
    return Future.value(true);
  }

  /// Toggle a like on a whisper comment; returns resulting liked state.
  Future<bool> toggleWhisperCommentLike(String commentId) async {
    final live = _live;
    if (live != null) {
      return _trackSelfInteractionRejection(
        'whisper_comment',
        () => live.toggleWhisperCommentLike(commentId),
      );
    }
    return Future.value(true);
  }

  Future<bool> toggleWhisperSave(String whisperId) {
    final live = _live;
    if (live != null) return live.toggleWhisperSave(whisperId);
    return Future.value(_mock.toggleWhisperSave(whisperId));
  }

  Future<List<Whisper>> mySavedWhispers() {
    final live = _live;
    if (live != null) return live.mySavedWhispers();
    return Future.value(_mock.mySavedWhispers());
  }

  Future<({String path, String url})> uploadWhisperAudio({
    required List<int> bytes,
    required String extension,
    String contentType = 'audio/mp4',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadWhisperAudio(
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return Future.value((path: 'mock/whisper.m4a', url: 'mock://whisper'));
  }

  /// Mark one of your own goals reached, or un-mark it. No-ops on the mock
  /// backend. Returns the reached timestamp, or null when cleared.
  Future<DateTime?> setGoalReached({
    required String postId,
    required bool reached,
  }) async {
    final live = _live;
    if (live == null) return reached ? DateTime.now() : null;
    return live.setGoalReached(postId: postId, reached: reached);
  }

  /// Attach or clear a whisper's background music bed. No-ops on the mock
  /// backend, which has no music catalogue.
  Future<void> setWhisperMusic({
    required String whisperId,
    String? trackId,
    int startMs = 0,
    double volume = 0.18,
  }) async {
    final live = _live;
    if (live == null) return;
    await live.setWhisperMusic(
      whisperId: whisperId,
      trackId: trackId,
      startMs: startMs,
      volume: volume,
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
    String? idempotencyKey,
  }) async {
    final live = _live;
    final id = live != null
        ? await live.createWhisper(
            audioPath: audioPath,
            audioUrl: audioUrl,
            audioDurationSeconds: audioDurationSeconds,
            category: category,
            backgroundImageUrl: backgroundImageUrl,
            voiceFilter: voiceFilter,
            title: title,
            description: description,
            personaId: personaId,
            idempotencyKey: idempotencyKey,
          )
        : 'mock-whisper-id';
    AnalyticsService.instance.track(
      Events.whisperPublished,
      props: {
        'category': category,
        'voice_filter': voiceFilter,
        'duration_seconds': audioDurationSeconds,
        'has_background': backgroundImageUrl != null,
        'has_title': title != null && title.isNotEmpty,
        'has_persona': personaId != null,
      },
    );
    return id;
  }

  Future<List<FriendRequest>> incomingFriendRequests() {
    final live = _live;
    if (live != null) return live.incomingFriendRequests();
    return _mock.incomingFriendRequests();
  }

  Future<List<FriendRequest>> outgoingFriendRequests() {
    final live = _live;
    if (live != null) return live.outgoingFriendRequests();
    return _mock.outgoingFriendRequests();
  }

  Future<List<BlockedUser>> myBlocks() {
    final live = _live;
    if (live != null) return live.myBlocks();
    return _mock.myBlocks();
  }

  Future<UserProfileView?> userProfile(String otherUserId) {
    final live = _live;
    if (live != null) return live.userProfile(otherUserId);
    return _mock.userProfile(otherUserId);
  }

  Future<int> hugsReceivedFor(String userId) {
    final live = _live;
    if (live != null) return live.hugsReceivedFor(userId);
    return Future.value(0);
  }

  Future<String> requestVerification({String? note}) {
    final live = _live;
    if (live != null) return live.requestVerification(note: note);
    return Future.value('pending');
  }

  Future<String> myVerificationStatus() {
    final live = _live;
    if (live != null) return live.myVerificationStatus();
    return Future.value('none');
  }

  // ===================== Plugz Creator Studio =====================

  Future<TribeStudioStats?> tribeStudioStats(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeStudioStats(tribeId);
    return _mock.tribeStudioStats(tribeId);
  }

  Future<List<Post>> pinnedPosts(String tribeId) {
    final live = _live;
    if (live != null) return live.pinnedPosts(tribeId);
    return _mock.pinnedPosts(tribeId);
  }

  Future<void> pinPost(String tribeId, String postId) {
    final live = _live;
    if (live != null) return live.pinPost(tribeId, postId);
    return _mock.pinPost(tribeId, postId);
  }

  Future<void> unpinPost(String tribeId, String postId) {
    final live = _live;
    if (live != null) return live.unpinPost(tribeId, postId);
    return _mock.unpinPost(tribeId, postId);
  }

  Future<List<ScheduledPrompt>> tribePrompts(String tribeId) {
    final live = _live;
    if (live != null) return live.tribePrompts(tribeId);
    return _mock.tribePrompts(tribeId);
  }

  Future<String> schedulePrompt({
    required String tribeId,
    required String text,
    DateTime? scheduledFor,
  }) {
    final live = _live;
    if (live != null) {
      return live.schedulePrompt(
        tribeId: tribeId,
        text: text,
        scheduledFor: scheduledFor,
      );
    }
    return _mock.schedulePrompt(
      tribeId: tribeId,
      text: text,
      scheduledFor: scheduledFor,
    );
  }

  Future<void> cancelPrompt(String tribeId, String promptId) {
    final live = _live;
    if (live != null) return live.cancelPrompt(tribeId, promptId);
    return _mock.cancelPrompt(tribeId, promptId);
  }

  Future<void> updatePrompt({
    required String tribeId,
    required String promptId,
    required String text,
    DateTime? scheduledFor,
  }) {
    final live = _live;
    if (live != null) {
      return live.updatePrompt(
        tribeId: tribeId,
        promptId: promptId,
        text: text,
        scheduledFor: scheduledFor,
      );
    }
    return _mock.updatePrompt(
      tribeId: tribeId,
      promptId: promptId,
      text: text,
      scheduledFor: scheduledFor,
    );
  }

  Future<void> deletePrompt(String tribeId, String promptId) {
    final live = _live;
    if (live != null) return live.deletePrompt(tribeId, promptId);
    return _mock.deletePrompt(tribeId, promptId);
  }

  Future<void> setTribeBranding({
    required String tribeId,
    String? welcomeMessage,
    String? themeColor,
  }) {
    final live = _live;
    if (live != null) {
      return live.setTribeBranding(
        tribeId: tribeId,
        welcomeMessage: welcomeMessage,
        themeColor: themeColor,
      );
    }
    return _mock.setTribeBranding(
      tribeId: tribeId,
      welcomeMessage: welcomeMessage,
      themeColor: themeColor,
    );
  }

  Future<void> spotlightMember({
    required String tribeId,
    required String? userId,
    String? note,
  }) {
    final live = _live;
    if (live != null) {
      return live.spotlightMember(tribeId: tribeId, userId: userId, note: note);
    }
    return _mock.spotlightMember(tribeId: tribeId, userId: userId, note: note);
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
        avatarSeed: (row['avatar_seed'] as String?) ?? 'default-orb',
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

  Future<void> toggleLike(String postId) => react(postId, 'hug');

  Future<String?> reactToStory(String postId, String reaction) =>
      react(postId, reaction);

  Future<ChatRoom> replyToStory({
    required String authorId,
    required String authorPseudonym,
    required String authorAvatarSeed,
    required String storyPostId,
    required String reply,
  }) async {
    final live = _live;
    if (live != null) {
      return live.replyToStory(storyPostId: storyPostId, reply: reply);
    }
    final room = await sendMessageRequest(
      peerUserId: authorId,
      peerPseudonym: authorPseudonym,
      peerAvatarSeed: authorAvatarSeed,
      preview: _trimPreview('Replied to your story: $reply'),
      originPostId: storyPostId,
    );
    if (room.roomStatus == 'active') {
      await sendMessage(
        roomId: room.roomId,
        plaintext: reply,
        attachedPostId: storyPostId,
      );
    }
    return room;
  }

  String _trimPreview(String value) {
    final text = value.trim();
    if (text.length <= 280) return text;
    return '${text.substring(0, 277)}...';
  }

  /// Set / switch / clear the caller's emotional reaction on a post.
  /// Returns the resulting reaction (`null` when the user toggled the
  /// same reaction off).
  Future<String?> react(String postId, String reaction) async {
    final live = _live;
    if (live != null) {
      return _trackSelfInteractionRejection(
        'post',
        () => live.react(postId, reaction),
      );
    }
    return _mock.react(postId, reaction);
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

  Future<void> reportTribeMessage({
    required String messageId,
    required String reason,
    String? note,
  }) async {
    final live = _live;
    if (live != null) {
      return live.reportTribeMessage(
        messageId: messageId,
        reason: reason,
        note: note,
      );
    }
    // Mock backend has no moderation store — treat as a no-op.
  }

  Future<void> reportChatMessage({
    required String messageId,
    required String reason,
    String? note,
  }) async {
    final live = _live;
    if (live != null) {
      return live.reportChatMessage(
        messageId: messageId,
        reason: reason,
        note: note,
      );
    }
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
      _mock.createPromptForTribe(tribeId: tribeId, text: text),
    );
  }

  /// Member-authored question to everyone or friends only (migration 0069).
  Future<PlugPrompt> createUserQuestion({
    required String text,
    String audience = 'everyone',
  }) {
    final live = _live;
    if (live != null) {
      return live.createUserQuestion(text: text, audience: audience);
    }
    return Future.value(
      _mock.createUserQuestion(text: text, audience: audience),
    );
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
    return Future.value(
      _mock.updateTribe(
        tribeId: tribeId,
        name: name,
        description: description,
        isPrivate: isPrivate,
        avatarUrl: avatarUrl,
        bannerUrl: bannerUrl,
      ),
    );
  }

  // ===================== Tribe ownership & lifecycle =====================

  Future<TribeManagementOverview> tribeManagementOverview(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeManagementOverview(tribeId);
    return Future.value(_mock.tribeManagementOverview(tribeId));
  }

  Future<TribeManagementOverview> updateTribeConfiguration({
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
  }) async {
    final live = _live;
    final result = live != null
        ? await live.updateTribeConfiguration(
            tribeId: tribeId,
            name: name,
            description: description,
            category: category,
            tags: tags,
            visibility: visibility,
            avatarUrl: avatarUrl,
            bannerUrl: bannerUrl,
            welcomeMessage: welcomeMessage,
            settings: settings,
          )
        : _mock.updateTribeConfiguration(
            tribeId: tribeId,
            name: name,
            description: description,
            category: category,
            tags: tags,
            visibility: visibility,
            avatarUrl: avatarUrl,
            bannerUrl: bannerUrl,
            welcomeMessage: welcomeMessage,
            settings: settings,
          );
    _cache.invalidate(prefix: 'tribes:');
    return result;
  }

  Future<TribeManagementOverview> replaceTribeRules(
    String tribeId,
    List<TribeRuleItem> rules,
  ) {
    final live = _live;
    if (live != null) return live.replaceTribeRules(tribeId, rules);
    return Future.value(_mock.replaceTribeRules(tribeId, rules));
  }

  Future<List<TribeJoinRequest>> tribeJoinRequests(String tribeId) {
    final live = _live;
    if (live != null) return live.tribeJoinRequests(tribeId);
    return Future.value(_mock.tribeJoinRequests(tribeId));
  }

  Future<void> respondTribeJoinRequest({
    required String requestId,
    required bool approve,
    String? reason,
  }) async {
    final live = _live;
    if (live != null) {
      return live.respondTribeJoinRequest(
        requestId: requestId,
        approve: approve,
        reason: reason,
      );
    }
    _mock.respondTribeJoinRequest(requestId, approve: approve);
  }

  Future<String> requestTribeMembership(String tribeId, {String? note}) async {
    final live = _live;
    if (live != null) return live.requestTribeMembership(tribeId, note: note);
    return _mock.requestTribeMembership(tribeId, note: note);
  }

  Future<void> manageTribeMember({
    required String tribeId,
    required String userId,
    required String action,
    String? reason,
    DateTime? muteUntil,
  }) async {
    final live = _live;
    if (live != null) {
      return live.manageTribeMember(
        tribeId: tribeId,
        userId: userId,
        action: action,
        reason: reason,
        muteUntil: muteUntil,
      );
    }
    _mock.manageTribeMember(
      tribeId: tribeId,
      userId: userId,
      action: action,
      reason: reason,
      muteUntil: muteUntil,
    );
  }

  Future<String> initiateTribeTransfer({
    required String tribeId,
    required String toUserId,
    bool keepPreviousOwnerAsMod = true,
  }) {
    final live = _live;
    if (live != null) {
      return live.initiateTribeTransfer(
        tribeId: tribeId,
        toUserId: toUserId,
        keepPreviousOwnerAsMod: keepPreviousOwnerAsMod,
      );
    }
    return Future.value(
      _mock.initiateTribeTransfer(
        tribeId: tribeId,
        toUserId: toUserId,
        keepPreviousOwnerAsMod: keepPreviousOwnerAsMod,
      ),
    );
  }

  Future<void> respondTribeTransfer({
    required String transferId,
    required bool accept,
  }) async {
    final live = _live;
    if (live != null) {
      await live.respondTribeTransfer(transferId: transferId, accept: accept);
    } else {
      _mock.respondTribeTransfer(transferId, accept: accept);
    }
    _cache.invalidate(prefix: 'tribes:');
  }

  Future<TribeManagementOverview> setTribeLifecycle({
    required String tribeId,
    required String action,
    String? reason,
    String? confirmedName,
    String? password,
  }) async {
    if (action == 'request_delete') {
      await reauthenticate(password ?? '');
    }
    final live = _live;
    final result = live != null
        ? await live.setTribeLifecycle(
            tribeId: tribeId,
            action: action,
            reason: reason,
            confirmedName: confirmedName,
          )
        : _mock.setTribeLifecycle(
            tribeId: tribeId,
            action: action,
            reason: reason,
            confirmedName: confirmedName,
          );
    _cache.invalidate(prefix: 'tribes:');
    return result;
  }

  Future<List<TribeAuditEvent>> tribeAuditLog(
    String tribeId, {
    int limit = 100,
  }) {
    final live = _live;
    if (live != null) return live.tribeAuditLog(tribeId, limit: limit);
    return Future.value(_mock.tribeAuditLog(tribeId, limit: limit));
  }

  Future<List<TribeManagedPost>> managedTribePosts(
    String tribeId, {
    int limit = 100,
  }) {
    final live = _live;
    if (live != null) return live.managedTribePosts(tribeId, limit: limit);
    return Future.value(_mock.managedTribePosts(tribeId, limit: limit));
  }

  Future<String> manageTribeSpace({
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
  }) async {
    final live = _live;
    if (live != null) {
      return live.manageTribeSpace(
        tribeId: tribeId,
        action: action,
        spaceId: spaceId,
        name: name,
        description: description,
        iconName: iconName,
        weeklyTheme: weeklyTheme,
        postingPermission: postingPermission,
        isPinned: isPinned,
        activatesAt: activatesAt,
        deactivatesAt: deactivatesAt,
        reason: reason,
      );
    }
    return _mock.manageTribeSpace(
      tribeId: tribeId,
      action: action,
      spaceId: spaceId,
      name: name,
      description: description,
      iconName: iconName,
      weeklyTheme: weeklyTheme,
      postingPermission: postingPermission,
      isPinned: isPinned,
      activatesAt: activatesAt,
      deactivatesAt: deactivatesAt,
      reason: reason,
    );
  }

  Future<void> manageTribePost({
    required String tribeId,
    required String postId,
    required String action,
    String? targetSpaceId,
    String? reason,
  }) async {
    final live = _live;
    if (live != null) {
      return live.manageTribePost(
        tribeId: tribeId,
        postId: postId,
        action: action,
        targetSpaceId: targetSpaceId,
        reason: reason,
      );
    }
    _mock.manageTribePost(
      tribeId: tribeId,
      postId: postId,
      action: action,
      targetSpaceId: targetSpaceId,
    );
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
    return Future.value(
      _mock.createPoll(
        postId: postId,
        question: question,
        optionTexts: optionTexts,
        closesIn: closesIn,
      ),
    );
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
      return _trackSelfInteractionRejection(
        'poll',
        () => live.votePoll(pollId: pollId, optionId: optionId),
      );
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

  Future<List<Post>> postsByAuthor(
    String authorId, {
    int limit = 20,
    int offset = 0,
  }) {
    final key = 'posts:author:$authorId:$limit:$offset';
    return _cache.getOrLoad(key, () async {
      final live = _live;
      if (live != null) {
        return live.postsByAuthor(authorId, limit: limit, offset: offset);
      }
      return _mock.postsByAuthor(authorId, limit: limit, offset: offset);
    }, ttl: const Duration(seconds: 45));
  }

  Future<List<Post>> activeStoriesByAuthor(
    String authorId, {
    int limit = 24,
  }) async {
    final live = _live;
    if (live != null) {
      return live.activeStoriesByAuthor(authorId, limit: limit);
    }
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    return _mock
        .postsByAuthor(authorId, limit: limit * 4)
        .where((post) => post.isStory && post.createdAt.isAfter(cutoff))
        .take(limit)
        .toList();
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
    String? personaId,
    String? imageUrl,
    String? imagePath,
    String? idempotencyKey,
  }) {
    final live = _live;
    if (live != null) {
      return live.addComment(
        postId: postId,
        parentId: parentId,
        content: content,
        personaId: personaId,
        imageUrl: imageUrl,
        imagePath: imagePath,
        idempotencyKey: idempotencyKey,
      );
    }
    return _mock.addComment(
      postId: postId,
      parentId: parentId,
      content: content,
      personaId: personaId,
    );
  }

  Future<bool> toggleCommentLike(String commentId) async {
    final live = _live;
    if (live != null) {
      return _trackSelfInteractionRejection(
        'comment',
        () => live.toggleCommentLike(commentId),
      );
    }
    return _mock.toggleCommentLike(commentId);
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
  /// Tribe lists are stable enough to cache for a minute per query —
  /// the directory screen swipes through several categories quickly.
  Future<List<Tribe>> tribes({String? category, String? search}) {
    final key = 'tribes:${category ?? ''}:${search ?? ''}';
    return _cache.getOrLoad(key, () async {
      final live = _live;
      if (live != null) {
        return live.tribes(category: category, search: search);
      }
      return _mock.tribes(category: category, search: search);
    }, ttl: const Duration(minutes: 1));
  }

  Future<List<Tribe>> tribesIKeep() {
    final live = _live;
    if (live != null) return live.tribesIKeep();
    return Future.value(_mock.tribesIKeep());
  }

  Future<KeeperMode> keeperMode() {
    final live = _live;
    if (live != null) return live.keeperMode();
    return Future.value(_mock.keeperMode());
  }

  Future<KeeperModerationQueue> keeperModerationQueue(
    String tribeId, {
    int limit = 30,
    int offset = 0,
  }) {
    final live = _live;
    if (live != null) {
      return live.keeperModerationQueue(tribeId, limit: limit, offset: offset);
    }
    return Future.value(_mock.keeperModerationQueue(tribeId));
  }

  Future<KeeperEngagementCalendar> keeperEngagementCalendar(String tribeId) {
    final live = _live;
    if (live != null) return live.keeperEngagementCalendar(tribeId);
    return Future.value(_mock.keeperEngagementCalendar(tribeId));
  }

  Future<KeeperAiInsights> keeperAiInsights(String tribeId) {
    final live = _live;
    if (live != null) return live.keeperAiInsights(tribeId);
    return Future.value(_mock.keeperAiInsights(tribeId));
  }

  Future<KeeperComodMatrix> keeperComodMatrix(String tribeId) {
    final live = _live;
    if (live != null) return live.keeperComodMatrix(tribeId);
    return Future.value(_mock.keeperComodMatrix(tribeId));
  }

  Future<KeeperExportReport> keeperExportReport(
    String tribeId, {
    String format = 'markdown',
  }) {
    final live = _live;
    if (live != null) {
      return live.keeperExportReport(tribeId, format: format);
    }
    return Future.value(_mock.keeperExportReport(tribeId));
  }

  Future<List<Tribe>> tribesByKeeper(String keeperId) {
    final key = 'tribes:keeper:$keeperId';
    return _cache.getOrLoad(key, () async {
      final live = _live;
      if (live != null) return live.tribesByKeeper(keeperId);
      return _mock.tribesByKeeper(keeperId);
    }, ttl: const Duration(minutes: 1));
  }

  Future<List<Post>> postsByKeeper(
    String keeperId, {
    int limit = 20,
    int offset = 0,
  }) {
    final key = 'posts:keeper:$keeperId:$limit:$offset';
    return _cache.getOrLoad(key, () async {
      final live = _live;
      if (live != null) {
        return live.postsByKeeper(keeperId, limit: limit, offset: offset);
      }
      return _mock.postsByKeeper(keeperId, limit: limit, offset: offset);
    }, ttl: const Duration(seconds: 45));
  }

  // ─── Spaces (migration 0050) ────────────────────────────────────────

  Future<List<Space>> spacesByTribe(String tribeId) {
    final live = _live;
    if (live != null) return live.spacesByTribe(tribeId);
    return Future.value(_mock.spacesByTribe(tribeId));
  }

  Future<Space?> spaceById(String spaceId) {
    final live = _live;
    if (live != null) return live.spaceById(spaceId);
    return Future.value(_mock.spaceById(spaceId));
  }

  Future<List<Post>> postsInSpace({
    required String spaceId,
    String sort = 'fresh',
    int limit = 60,
  }) {
    final live = _live;
    if (live != null) {
      return live.postsInSpace(spaceId: spaceId, sort: sort, limit: limit);
    }
    return Future.value(
      _mock.postsInSpace(spaceId: spaceId, sort: sort, limit: limit),
    );
  }

  Future<String> createSpace({
    required String tribeId,
    required String name,
    String? description,
  }) {
    final live = _live;
    if (live != null) {
      return live.createSpace(
        tribeId: tribeId,
        name: name,
        description: description,
      );
    }
    return Future.error(StateError('not_signed_in'));
  }

  Future<bool> renameSpace({required String spaceId, required String name}) {
    final live = _live;
    if (live != null) return live.renameSpace(spaceId: spaceId, name: name);
    return Future.value(false);
  }

  Future<bool> archiveSpace(String spaceId) {
    final live = _live;
    if (live != null) return live.archiveSpace(spaceId);
    return Future.value(false);
  }

  Future<SpaceSummary?> latestSpaceSummary(String spaceId) {
    final live = _live;
    if (live != null) return live.latestSpaceSummary(spaceId);
    return Future.value(null);
  }

  Future<bool> updateSpaceTheme({
    required String spaceId,
    String? weeklyTheme,
    String? themeColor,
    String? description,
  }) {
    final live = _live;
    if (live != null) {
      return live.updateSpaceTheme(
        spaceId: spaceId,
        weeklyTheme: weeklyTheme,
        themeColor: themeColor,
        description: description,
      );
    }
    return Future.value(false);
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
    List<String> tags = const [],
    String? visibility,
    String? welcomeMessage,
    TribeGovernanceSettings settings = const TribeGovernanceSettings(),
    List<TribeRuleItem> rules = const [],
  }) {
    final live = _live;
    if (live != null) {
      return live.createTribe(
        name: name,
        category: category,
        description: description,
        isPrivate: isPrivate,
        tags: tags,
        visibility: visibility,
        welcomeMessage: welcomeMessage,
        settings: settings,
        rules: rules,
      );
    }
    return Future.value(
      _mock.createTribe(
        name: name,
        category: category,
        description: description,
        isPrivate: isPrivate,
        tags: tags,
        visibility: visibility,
        welcomeMessage: welcomeMessage,
        settings: settings,
        rules: rules,
      ),
    );
  }

  bool joinedTribe(String tribeId) {
    final live = _live;
    if (live != null) return live.joinedTribe(tribeId);
    return _mock.joinedTribe(tribeId);
  }

  Future<void> joinTribe(String tribeId) async {
    _cache.invalidate(prefix: 'tribes:');
    unawaited(_telemetry.event('tribe_join', props: {'tribe_id': tribeId}));
    final live = _live;
    if (live != null) return live.joinTribe(tribeId);
    _mock.joinTribe(tribeId);
  }

  Future<void> leaveTribe(String tribeId) async {
    _cache.invalidate(prefix: 'tribes:');
    unawaited(_telemetry.event('tribe_leave', props: {'tribe_id': tribeId}));
    final live = _live;
    if (live != null) return live.leaveTribe(tribeId);
    _mock.leaveTribe(tribeId);
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
    return _mockSnapshotStream(_mock.roomsStream, () => _mock.inbox(tab: tab));
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
    return _mockSnapshotStream(
      _mock.roomsStream,
      () => _mock.roomMessages(roomId),
    );
  }

  /// Returns true when the current user is allowed to DM [peerUserId].
  /// Used by UI to show/hide the Message CTA on Friend Profile and
  /// inbox surfaces. Mock backend returns true if mutually friends.
  Future<bool> canDm(String peerUserId) async {
    final live = _live;
    if (live != null) return live.canDm(peerUserId);
    final s = await _mock.friendStatus(peerUserId);
    return s == FriendStatus.friends || s == FriendStatus.self;
  }

  /// Open-or-create the DM with [peerUserId]. Throws
  /// [DmGatingException] when the pair isn't friends (migration 0026).
  Future<ChatRoom> sendMessageRequest({
    required String peerUserId,
    required String peerPseudonym,
    required String peerAvatarSeed,
    required String preview,
    String? originPostId,
  }) async {
    final live = _live;
    if (live != null) {
      return live.sendMessageRequest(
        peerUserId: peerUserId,
        preview: preview,
        originPostId: originPostId,
      );
    }
    // Mock path: enforce the same gate locally so the UX is consistent.
    final s = await _mock.friendStatus(peerUserId);
    if (s != FriendStatus.friends && s != FriendStatus.self) {
      throw const DmGatingException(
        'Send a friend request first — you can only message friends.',
      );
    }
    return _mock.sendMessageRequest(
      peerPseudonym: peerPseudonym,
      peerAvatarSeed: peerAvatarSeed,
      preview: preview,
    );
  }

  Future<ChatRoom> createGroupChat({
    required String title,
    required String friendUserId,
    required String friendPseudonym,
    required String friendAvatarSeed,
    List<String> additionalMemberUserIds = const [],
  }) async {
    final live = _live;
    if (live != null) {
      return live.createGroupChat(
        title: title,
        memberUserIds: [friendUserId, ...additionalMemberUserIds],
      );
    }
    final status = await _mock.friendStatus(friendUserId);
    if (status != FriendStatus.friends) {
      throw const DmGatingException(
        'Only accepted friends can create a private group chat.',
      );
    }
    return _mock.createGroupChat(
      title: title,
      friendUserId: friendUserId,
      friendPseudonym: friendPseudonym,
      friendAvatarSeed: friendAvatarSeed,
      additionalMemberUserIds: additionalMemberUserIds,
    );
  }

  Future<List<GroupChatMember>> groupChatMembers(String roomId) {
    final live = _live;
    if (live != null) return live.groupChatMembers(roomId);
    return Future.value(_mock.groupChatMembers(roomId));
  }

  Future<int> addGroupChatMembers({
    required String roomId,
    required List<String> memberUserIds,
  }) {
    final live = _live;
    if (live != null) {
      return live.addGroupChatMembers(
        roomId: roomId,
        memberUserIds: memberUserIds,
      );
    }
    return Future.value(_mock.addGroupChatMembers(roomId, memberUserIds));
  }

  Future<bool> removeGroupChatMember({
    required String roomId,
    required String userId,
  }) {
    final live = _live;
    if (live != null) {
      return live.removeGroupChatMember(roomId: roomId, userId: userId);
    }
    return Future.value(_mock.removeGroupChatMember(roomId, userId));
  }

  Future<bool> leaveGroupChat(String roomId) {
    final live = _live;
    if (live != null) return live.leaveGroupChat(roomId);
    return Future.value(_mock.leaveGroupChat(roomId));
  }

  Future<bool> markGroupSpamAndLeave(String roomId) {
    final live = _live;
    if (live != null) return live.markGroupSpamAndLeave(roomId);
    return Future.value(_mock.leaveGroupChat(roomId));
  }

  Future<ChatRoom> updateGroupChatIdentity({
    required String roomId,
    String? title,
    String? avatarPath,
    bool clearAvatar = false,
  }) {
    final live = _live;
    if (live != null) {
      return live.updateGroupChatIdentity(
        roomId: roomId,
        title: title,
        avatarPath: avatarPath,
        clearAvatar: clearAvatar,
      );
    }
    return Future.value(
      _mock.updateGroupChatIdentity(
        roomId,
        title: title,
        avatarPath: avatarPath,
        clearAvatar: clearAvatar,
      ),
    );
  }

  Future<bool> setGroupChatNickname({
    required String roomId,
    required String nickname,
  }) {
    final live = _live;
    if (live != null) {
      return live.setGroupChatNickname(roomId: roomId, nickname: nickname);
    }
    return Future.value(_mock.setGroupChatNickname(roomId, nickname));
  }

  Future<bool> setGroupChatPrivacy({
    required String roomId,
    bool? allowMemberInvites,
    bool? inviteEnabled,
  }) {
    final live = _live;
    if (live != null) {
      return live.setGroupChatPrivacy(
        roomId: roomId,
        allowMemberInvites: allowMemberInvites,
        inviteEnabled: inviteEnabled,
      );
    }
    return Future.value(
      _mock.setGroupChatPrivacy(
        roomId,
        allowMemberInvites: allowMemberInvites,
        inviteEnabled: inviteEnabled,
      ),
    );
  }

  Future<String> regenerateGroupInvite(String roomId) {
    final live = _live;
    if (live != null) return live.regenerateGroupInvite(roomId);
    return Future.value(_mock.regenerateGroupInvite(roomId));
  }

  Future<GroupInvitePreview?> groupInvitePreview(String token) {
    final live = _live;
    if (live != null) return live.groupInvitePreview(token);
    return Future.value(_mock.groupInvitePreview(token));
  }

  Future<String> joinGroupChatByInvite(String token) {
    final live = _live;
    if (live != null) return live.joinGroupChatByInvite(token);
    return Future.value(_mock.joinGroupChatByInvite(token));
  }

  /// Private DM send. V1 is plaintext server-side so moderators can review
  /// reported chats; we do not advertise end-to-end encryption.
  /// Stamp the room as read for the current user. Returns the count of
  /// newly-marked messages (zero when the room is already up to date).
  Future<int> markRoomRead(String roomId) {
    final live = _live;
    if (live != null) return live.markRoomRead(roomId);
    return _mock.markRoomRead(roomId);
  }

  /// Fires on any friendships change involving the caller (realtime).
  Stream<int> watchFriendshipEvents() {
    final live = _live;
    if (live != null) return live.watchFriendshipEvents();
    return Stream.value(0);
  }

  /// Stamp delivered_at on peer messages the client just received.
  Future<int> markRoomDelivered(String roomId) {
    final live = _live;
    if (live != null) return live.markRoomDelivered(roomId);
    return Future.value(0);
  }

  /// Presence heartbeat (resume + ~60s while foregrounded).
  Future<void> touchLastSeen() {
    final live = _live;
    if (live != null) return live.touchLastSeen();
    return Future.value();
  }

  // ---- Devices, sessions, and the security ledger -------------------------

  /// Bind this installation to the current session. Idempotent per session.
  Future<DeviceRegistration?> registerDeviceSession({
    required String deviceId,
    String? deviceName,
    String deviceType = 'unknown',
    String? osName,
    String? osVersion,
    String? appVersion,
  }) {
    final live = _live;
    if (live == null) return Future.value();
    return live.registerDeviceSession(
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      osName: osName,
      osVersion: osVersion,
      appVersion: appVersion,
    );
  }

  Future<List<DeviceSession>> myDeviceSessions() {
    final live = _live;
    if (live != null) return live.myDeviceSessions();
    return Future.value(const <DeviceSession>[]);
  }

  Future<bool> revokeDeviceSession(String deviceSessionId) {
    final live = _live;
    if (live != null) return live.revokeDeviceSession(deviceSessionId);
    return Future.value(false);
  }

  Future<int> revokeOtherDeviceSessions() {
    final live = _live;
    if (live != null) return live.revokeOtherDeviceSessions();
    return Future.value(0);
  }

  /// False means this session was revoked elsewhere and the app should sign
  /// out. The mock backend has no sessions to revoke, so it answers true.
  Future<bool> touchDeviceSession() {
    final live = _live;
    if (live != null) return live.touchDeviceSession();
    return Future.value(true);
  }

  Future<bool> trustDevice(String deviceRowId) {
    final live = _live;
    if (live != null) return live.trustDevice(deviceRowId);
    return Future.value(false);
  }

  Future<int> blockDevice(String deviceRowId) {
    final live = _live;
    if (live != null) return live.blockDevice(deviceRowId);
    return Future.value(0);
  }

  Future<List<SecurityEvent>> mySecurityEvents({
    int limit = 30,
    DateTime? before,
  }) {
    final live = _live;
    if (live != null) return live.mySecurityEvents(limit: limit, before: before);
    return Future.value(const <SecurityEvent>[]);
  }

  Future<void> logSecurityEvent(String kind, {Map<String, dynamic>? context}) {
    final live = _live;
    if (live != null) return live.logSecurityEvent(kind, context: context);
    return Future.value();
  }

  Future<void> recordFailedLogin(String identifier) {
    final live = _live;
    if (live != null) return live.recordFailedLogin(identifier);
    return Future.value();
  }

  /// Peer presence tier: online | recent | offline | hidden.
  Future<({String state, DateTime? lastSeen})> peerPresence(String userId) {
    final live = _live;
    if (live != null) return live.peerPresence(userId);
    return Future.value((state: 'online', lastSeen: DateTime.now()));
  }

  /// Unread peer messages in active DM rooms (Inbox tab badge).
  Future<int> unreadChatMessageCount() {
    final live = _live;
    if (live != null) return live.unreadChatMessageCount();
    return _mock.unreadChatMessageCount();
  }

  /// Toggle/swap/clear an emoji reaction on a chat message. Mirrors
  /// the post-reaction semantic: same emoji again clears, different
  /// emoji swaps, null clears. Returns the resulting reaction.
  Future<String?> setMessageReaction(String messageId, String? reaction) {
    final live = _live;
    if (live != null) return live.setMessageReaction(messageId, reaction);
    return _mock.setMessageReaction(messageId, reaction);
  }

  /// Best-effort ephemeral "I'm typing" ping. UI debounces. No DB write.
  void broadcastTyping(String roomId) {
    final live = _live;
    if (live != null) {
      live.broadcastTyping(roomId);
    } else {
      _mock.broadcastTyping(roomId);
    }
  }

  /// True when the peer is currently typing in [roomId]; flips false
  /// ~3 seconds after the last typing signal.
  Stream<bool> watchTyping(String roomId) {
    final live = _live;
    if (live != null) return live.watchTyping(roomId);
    return _mock.watchTyping(roomId);
  }

  Future<ChatMessage> sendMessage({
    required String roomId,
    required String plaintext,
    String? attachedPostId,
    String? attachedMediaPath,
    String? attachedMediaType,
    String? parentMessageId,
    String? idempotencyKey,
  }) async {
    final live = _live;
    final ChatMessage msg;
    if (live != null) {
      msg = await live.sendMessage(
        roomId: roomId,
        payload: plaintext,
        attachedPostId: attachedPostId,
        attachedMediaPath: attachedMediaPath,
        attachedMediaType: attachedMediaType,
        parentMessageId: parentMessageId,
        idempotencyKey: idempotencyKey,
      );
    } else {
      msg = _mock.sendMessage(
        roomId: roomId,
        plaintext: plaintext,
        attachedPostId: attachedPostId,
        attachedMediaPath: attachedMediaPath,
        attachedMediaType: attachedMediaType,
      );
    }
    AnalyticsService.instance.track(
      parentMessageId != null
          ? Events.chatMessageReplied
          : Events.chatMessageSent,
      props: {
        'has_image': attachedMediaPath != null,
        'has_attached_post': attachedPostId != null,
        'is_reply': parentMessageId != null,
        'content_chars': plaintext.length,
      },
    );
    return msg;
  }

  Future<bool> editChatMessage({
    required String messageId,
    required String newPlaintext,
  }) {
    final live = _live;
    if (live != null) {
      return live.editChatMessage(
        messageId: messageId,
        newPlaintext: newPlaintext,
      );
    }
    return Future.value(
      _mock.editChatMessage(messageId: messageId, newPlaintext: newPlaintext),
    );
  }

  Future<bool> deleteChatMessage(String messageId) {
    final live = _live;
    if (live != null) return live.deleteChatMessage(messageId);
    return Future.value(_mock.deleteChatMessage(messageId));
  }

  Future<bool> hideChatMessage(String messageId) {
    final live = _live;
    if (live != null) return live.hideChatMessage(messageId);
    return Future.value(_mock.hideChatMessage(messageId));
  }

  // ===================== Author CRUD (migration 0047) =====================

  Future<bool> editPost({required String postId, required String newContent}) {
    final live = _live;
    if (live != null) {
      return live.editPost(postId: postId, newContent: newContent);
    }
    return Future.value(_mock.editPost(postId: postId, newContent: newContent));
  }

  Future<bool> deletePost(String postId) {
    final live = _live;
    if (live != null) return live.deletePost(postId);
    return Future.value(_mock.deletePost(postId));
  }

  Future<bool> editComment({
    required String commentId,
    required String newContent,
  }) {
    final live = _live;
    if (live != null) {
      return live.editComment(commentId: commentId, newContent: newContent);
    }
    return Future.value(false);
  }

  Future<bool> deleteComment(String commentId) {
    final live = _live;
    if (live != null) return live.deleteComment(commentId);
    return Future.value(false);
  }

  Future<bool> editWhisper({
    required String whisperId,
    String? title,
    String? description,
  }) {
    final live = _live;
    if (live != null) {
      return live.editWhisper(
        whisperId: whisperId,
        title: title,
        description: description,
      );
    }
    return Future.value(false);
  }

  Future<bool> deleteWhisper(String whisperId) {
    final live = _live;
    if (live != null) return live.deleteWhisper(whisperId);
    return Future.value(false);
  }

  Future<bool> editTribeMessage({
    required String messageId,
    required String newContent,
  }) {
    final live = _live;
    if (live != null) {
      return live.editTribeMessage(
        messageId: messageId,
        newContent: newContent,
      );
    }
    return Future.value(false);
  }

  Future<bool> deleteTribeMessage(String messageId) {
    final live = _live;
    if (live != null) return live.deleteTribeMessage(messageId);
    return Future.value(false);
  }

  Future<bool> hideTribeMessage(String messageId) {
    final live = _live;
    if (live != null) return live.hideTribeMessage(messageId);
    return Future.value(false);
  }

  /// Used by the sign-in screens after catching
  /// [MfaChallengeRequiredException] to complete AAL2.
  Future<void> verifyMfa({required String factorId, required String code}) {
    final live = _live;
    if (live != null) {
      return live.verifyMfa(factorId: factorId, code: code);
    }
    return Future.value();
  }

  // ─── Phase 2 (migration 0051) ──────────────────────────────────────

  Future<bool> pinComment(String commentId) {
    final live = _live;
    if (live != null) return live.pinComment(commentId);
    return Future.value(false);
  }

  Future<bool> unpinComment(String commentId) {
    final live = _live;
    if (live != null) return live.unpinComment(commentId);
    return Future.value(false);
  }

  Future<bool> setPostCommentsLock({
    required String postId,
    required bool locked,
  }) {
    final live = _live;
    if (live != null) {
      return live.setPostCommentsLock(postId: postId, locked: locked);
    }
    return Future.value(false);
  }

  Future<bool> toggleKeeperPick(String postId) {
    final live = _live;
    if (live != null) return live.toggleKeeperPick(postId);
    return Future.value(false);
  }

  Future<bool> updateTribeManagement({
    required String tribeId,
    String? name,
    String? rules,
    bool? isPremium,
    String? avatarUrl,
    Map<String, dynamic>? settings,
  }) {
    final live = _live;
    if (live != null) {
      return live.updateTribeManagement(
        tribeId: tribeId,
        name: name,
        rules: rules,
        isPremium: isPremium,
        avatarUrl: avatarUrl,
        settings: settings,
      );
    }
    return Future.value(false);
  }

  Future<void> registerPushToken({
    required String token,
    required String platform,
    String? locale,
    String? appVersion,
  }) async {
    final live = _live;
    if (live == null) return;
    return live.registerPushToken(
      token: token,
      platform: platform,
      locale: locale,
      appVersion: appVersion,
    );
  }

  Future<void> unregisterPushToken(String token) async {
    final live = _live;
    if (live == null) return;
    return live.unregisterPushToken(token);
  }

  Future<void> unregisterAllPushTokens() async {
    final live = _live;
    if (live == null) return;
    return live.unregisterAllPushTokens();
  }

  /// Upload an image to the room's chat-media folder. Returns the
  /// storage path which can then be passed into [sendMessage] as
  /// `attachedMediaPath`. Voice deliberately unsupported.
  Future<({String path, String messageId})> uploadChatImage({
    required String roomId,
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadChatImage(
        roomId: roomId,
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return _mock.uploadChatImage(
      roomId: roomId,
      bytes: bytes,
      extension: extension,
      contentType: contentType,
    );
  }

  Future<String> uploadGroupChatAvatar({
    required String roomId,
    required List<int> bytes,
    required String extension,
    String contentType = 'image/jpeg',
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadGroupChatAvatar(
        roomId: roomId,
        bytes: bytes,
        extension: extension,
        contentType: contentType,
      );
    }
    return Future.value('$roomId/group-avatar-mock.${extension.toLowerCase()}');
  }

  Future<void> deleteChatMedia(String path) {
    final live = _live;
    if (live != null) return live.deleteChatMedia(path);
    return Future.value();
  }

  /// Upload a DM voice note (m4a). Duration rides in the object name so no
  /// schema change is needed — see SupabaseBackend.uploadChatAudio.
  Future<({String path, String messageId})> uploadChatAudio({
    required String roomId,
    required List<int> bytes,
    required int durationSeconds,
  }) {
    final live = _live;
    if (live != null) {
      return live.uploadChatAudio(
        roomId: roomId,
        bytes: bytes,
        durationSeconds: durationSeconds,
      );
    }
    return Future.value((path: 'mock/voice.m4a', messageId: 'mock'));
  }

  /// Resolve a chat-media storage path into a signed URL the UI can
  /// pass to Image.network / CachedNetworkImage.
  Future<String> chatImageSignedUrl(String path) {
    final live = _live;
    if (live != null) return live.chatImageSignedUrl(path);
    return _mock.chatImageSignedUrl(path);
  }

  // ===================== Prompts =====================
  Future<List<PlugPrompt>> prompts() {
    final live = _live;
    if (live != null) return live.prompts();
    return Future.value(_mock.prompts());
  }

  /// Questions a given member has asked (public-profile section).
  Future<List<PlugPrompt>> questionsByAuthor(String userId) {
    final live = _live;
    if (live != null) return live.questionsByAuthor(userId);
    return Future.value(_mock.questionsByAuthor(userId));
  }

  Future<void> updateUserQuestion({
    required String promptId,
    String? text,
    String? audience,
  }) {
    final live = _live;
    if (live != null) {
      return live.updateUserQuestion(
        promptId: promptId,
        text: text,
        audience: audience,
      );
    }
    _mock.updateUserQuestion(
      promptId: promptId,
      text: text,
      audience: audience,
    );
    return Future.value();
  }

  Future<void> deleteUserQuestion(String promptId) {
    final live = _live;
    if (live != null) return live.deleteUserQuestion(promptId);
    _mock.deleteUserQuestion(promptId);
    return Future.value();
  }

  Future<void> likeQuestion(String promptId) {
    final live = _live;
    if (live != null) return live.likeQuestion(promptId);
    _mock.likeQuestion(promptId);
    return Future.value();
  }

  Future<void> unlikeQuestion(String promptId) {
    final live = _live;
    if (live != null) return live.unlikeQuestion(promptId);
    _mock.unlikeQuestion(promptId);
    return Future.value();
  }

  Future<void> reportQuestion({
    required String promptId,
    required String reason,
  }) {
    final live = _live;
    if (live != null) {
      return live.reportQuestion(promptId: promptId, reason: reason);
    }
    return Future.value();
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
    return Future.value(_mock.addPromptAnswer(promptId: promptId, text: text));
  }

  // ===================== Notifications =====================
  Future<List<NotificationItem>> notifications() {
    final live = _live;
    if (live != null) return live.notifications();
    return Future.value(_mock.notifications());
  }

  Stream<List<NotificationItem>> watchNotifications() {
    final live = _live;
    if (live != null) return live.watchNotifications();
    return Stream.value(_mock.notifications());
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
        now.month > birth.month ||
        (now.month == birth.month && now.day >= birth.day);
    if (!hasBirthdayPassed) age -= 1;
    return age;
  }
}

class AgeGateBlocked implements Exception {
  @override
  String toString() =>
      'Venttly requires members to be 13 or older to keep our community safe.';
}
