import 'package:collection/collection.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/vently_repository.dart';
import '../data/services/analytics_service.dart';
import '../data/services/feature_flags_service.dart';
import '../data/services/moderation_service.dart';
import '../data/services/music_playback_service.dart';
import '../data/services/push_registration_service.dart';
import '../data/services/whisper_player.dart';
import '../domain/entities/entities.dart';
import '../domain/home/home_discovery.dart';
import '../domain/tribe/tribe_chat_hub.dart';
import '../domain/tribe/tribe_management.dart';
import '../domain/tribe/tribe_recommendations.dart';
import '../domain/keeper/keeper_overview.dart';
import '../domain/keeper/keeper_mode.dart';
import '../domain/keeper/keeper_studio_v2.dart';
import 'analytics_events.dart';
import 'logger.dart';

final repositoryProvider = Provider<VentlyRepository>((ref) {
  return VentlyRepository();
});

final musicPlaybackProvider = ChangeNotifierProvider<MusicPlaybackController>((
  ref,
) => MusicPlaybackController());

final musicCatalogProvider = FutureProvider.autoDispose
    .family<List<MusicTrack>, ({String query, String? mood})>((
      ref,
      request,
    ) async {
      return ref
          .watch(repositoryProvider)
          .searchMusic(query: request.query, mood: request.mood);
    });

/// Active staff-managed automod keyword rules (migration 0085). Loaded once
/// and kept until the app restarts; safe to fail (empty = built-ins only).
final automodRulesProvider = FutureProvider<List<AutomodRule>>((ref) async {
  // Rules are RLS-scoped to authenticated users, so refetch when auth changes.
  ref.watch(sessionProvider);
  try {
    return await ref.watch(repositoryProvider).automodRules();
  } catch (_) {
    return const <AutomodRule>[];
  }
});

final moderationServiceProvider = Provider<ModerationService>((ref) {
  final repo = ref.watch(repositoryProvider);
  // Tier-2 runs server-side via the `moderate` edge function (key off-device +
  // trusted verdict cache). If it fails, Tier-2 fails open to 'safe' — Tier-1
  // on-device still applies — rather than falling back to an on-device key.
  final service = ModerationService(
    remoteGuard: (text) => repo.moderateRemote(text),
  );
  // Feed in dynamic automod rules as they resolve; until then the service
  // runs on its built-in dictionaries.
  final rules = ref.watch(automodRulesProvider).valueOrNull;
  if (rules != null) service.setDynamicRules(rules);
  return service;
});

/// Reactive session — null when logged out.
final sessionProvider = StateNotifierProvider<SessionController, AppUser?>((
  ref,
) {
  final repo = ref.watch(repositoryProvider);
  return SessionController(repo);
});

class SessionController extends StateNotifier<AppUser?> {
  SessionController(this._repo) : super(_repo.currentUser) {
    // If the repo already has a cached user (warm app start), tell
    // analytics + flags immediately so the first event is attributed.
    final cached = _repo.currentUser;
    if (cached != null) _identifyDownstream(cached);
  }
  final VentlyRepository _repo;

  /// Identify the user on every downstream service that needs it.
  /// Idempotent — safe to call on every restore() / register / signIn.
  void _identifyDownstream(AppUser user) {
    final traits = <String, Object?>{
      'safety_tier': user.safetyTier,
      'user_role': user.userRole,
      'is_verified': user.isVerified,
      // Pseudonym + birth year are PII-adjacent — leave them out so we
      // never end up grouping people by anonymous handle in PostHog.
    };
    AnalyticsService.instance.identify(user.userId, traits: traits);
    FeatureFlagsService.instance.identify(user.userId, traits: traits);
  }

  Future<void> restore() async {
    state = await _repo.restoreSession();
    final user = state;
    if (user != null) _identifyDownstream(user);
  }

  /// Sign up. Returns the user *and* the freshly generated 12-word recovery
  /// phrase — the caller must display it once before navigating away;
  /// nothing else holds a copy outside the user's device + their own memory.
  Future<({AppUser user, String recoveryPhrase})> register({
    required DateTime birthDate,
    required String username,
    required String password,
    required String avatarSeed,
  }) async {
    final result = await _repo.registerAccount(
      birthDate: birthDate,
      username: username,
      password: password,
      avatarSeed: avatarSeed,
    );
    state = result.user;
    _identifyDownstream(result.user);
    AnalyticsService.instance.track(Events.signupAnonymous);
    return result;
  }

  /// Email-based sign-up. `user` is null when the Supabase project
  /// requires email confirmation — caller surfaces a "check your inbox"
  /// state until the confirmation link is clicked.
  Future<({AppUser? user, String recoveryPhrase})> registerWithEmail({
    required DateTime birthDate,
    required String email,
    required String username,
    required String password,
    required String avatarSeed,
  }) async {
    final result = await _repo.registerAccountWithEmail(
      birthDate: birthDate,
      email: email,
      username: username,
      password: password,
      avatarSeed: avatarSeed,
    );
    if (result.user != null) {
      state = result.user;
      _identifyDownstream(result.user!);
      AnalyticsService.instance.track(Events.signupEmail);
    } else {
      // Email confirmation pending — track the funnel step but don't
      // identify (we don't have a stable user id yet).
      AnalyticsService.instance.track(
        Events.signupEmail,
        props: {'state': 'awaiting_confirmation'},
      );
    }
    return result;
  }

  Future<AppUser> signInEmail({
    required String email,
    required String password,
  }) async {
    final user = await _repo.signInWithEmail(email: email, password: password);
    await _repo
        .reactivateMyAccount(); // restore if deactivated / cancel deletion
    state = user;
    _identifyDownstream(user);
    AnalyticsService.instance.track(Events.signinEmail);
    return user;
  }

  // ---- Optional real-email verification ---------------------------------

  bool get hasRealEmail => _repo.hasRealEmail;
  String? get currentEmail => _repo.currentEmail;
  bool get isEmailVerified => state?.emailVerified ?? false;

  Future<void> sendEmailVerification() => _repo.sendEmailVerification();

  /// Confirm the 6-digit [code]; on success flips `emailVerified` in session.
  Future<bool> confirmEmailVerification(String code) async {
    final ok = await _repo.confirmEmailVerification(code);
    if (ok) state = state?.copyWith(emailVerified: true);
    return ok;
  }

  /// Re-read the verified flag (e.g. after returning to the app).
  Future<bool> refreshEmailVerified() async {
    final ok = await _repo.refreshEmailVerified();
    if (ok && state != null) state = state!.copyWith(emailVerified: true);
    return ok;
  }

  // ---- Password & security ----------------------------------------------

  /// Rotate the account password (re-auths with the current one first).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? recoveryPhrase,
  }) => _repo.changePassword(
    currentPassword: currentPassword,
    newPassword: newPassword,
    recoveryPhrase: recoveryPhrase,
  );

  Future<bool> needsRecoveryPhraseForPasswordChange() =>
      _repo.needsRecoveryPhraseForPasswordChange();

  /// Attach / change a real recovery email; Supabase emails a confirm link.
  /// The auth-email change only finalises once the user confirms.
  Future<void> setRecoveryEmail(String email) => _repo.setRecoveryEmail(email);

  /// Sign out of every device (revokes all refresh tokens), then clear state.
  Future<void> signOutEverywhere() async {
    AnalyticsService.instance.track(Events.logout);
    try {
      await PushRegistrationService.instance.unregisterBeforeSignOut(_repo);
    } catch (_) {
      log.warn('push.signout_cleanup_failed');
    }
    try {
      await _repo.unregisterAllPushTokens();
    } catch (_) {
      log.warn('push.global_signout_cleanup_failed');
    }
    try {
      await _repo.signOutEverywhere();
    } finally {
      state = null;
      await AnalyticsService.instance.reset();
    }
  }

  /// Save edits to the signed-in user's public profile and refresh session
  /// state so every screen re-renders with the new username/photo/bio/pronouns.
  Future<void> updateProfile({
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
    final updated = await _repo.updateMyProfile(
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
    if (updated != null) state = updated;
  }

  // ---- Optional social / phone sign-in ----------------------------------

  Future<bool> signInWithGoogle() => _repo.signInWithGoogle();

  Future<void> startPhoneOtp(String phone) => _repo.startPhoneOtp(phone);

  Future<AppUser> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {
    final user = await _repo.verifyPhoneOtp(phone: phone, token: token);
    await _repo
        .reactivateMyAccount(); // restore if deactivated / cancel deletion
    state = user;
    _identifyDownstream(user);
    return user;
  }

  Future<AppUser> completeAgeVerification(DateTime birthDate) async {
    final user = await _repo.completeAgeVerification(birthDate);
    state = user;
    _identifyDownstream(user);
    return user;
  }

  /// Username + password sign-in for returning users.
  Future<AppUser> signIn({
    required String username,
    required String password,
  }) async {
    final user = await _repo.signIn(username: username, password: password);
    await _repo
        .reactivateMyAccount(); // restore if deactivated / cancel deletion
    state = user;
    _identifyDownstream(user);
    AnalyticsService.instance.track(Events.signinAnonymous);
    return user;
  }

  /// Reversible: hide the account app-wide, then sign out. Logging back in
  /// (any method) reactivates it automatically.
  Future<void> deactivateAccount() async {
    await _repo.deactivateMyAccount();
    await logout();
  }

  /// Start the 30-day deletion grace period, then sign out. Logging back in
  /// within the window cancels the deletion; after 30 days data is purged.
  Future<void> deleteAccount() async {
    await _repo.requestAccountDeletion();
    await logout();
  }

  /// Restore an account on a fresh install using the 12-word phrase.
  /// Returns null if the phrase doesn't decrypt the recovery blob.
  Future<AppUser?> recoverWithPhrase({
    required String username,
    required String phrase,
  }) async {
    final user = await _repo.recoverWithPhrase(
      username: username,
      phrase: phrase,
    );
    if (user != null) {
      state = user;
      _identifyDownstream(user);
      AnalyticsService.instance.track(Events.recoveryUsed);
    }
    return user;
  }

  Future<void> logout() async {
    AnalyticsService.instance.track(Events.logout);
    try {
      await PushRegistrationService.instance.unregisterBeforeSignOut(_repo);
    } catch (_) {
      log.warn('push.signout_cleanup_failed');
    }
    try {
      await _repo.logout();
    } finally {
      state = null;
      await AnalyticsService.instance.reset();
    }
  }
}

/// Venttly appearance — light, warm charcoal dark, or pure black (AMOLED).
/// Flutter's [ThemeMode] only knows light/dark, so black is our own third
/// option that maps to [ThemeMode.dark] with a true-black theme variant.
enum VentlyThemeMode { light, dark, black }

final themeModeProvider =
    StateNotifierProvider<ThemeModeController, VentlyThemeMode>(
      (ref) => ThemeModeController(),
    );

class ThemeModeController extends StateNotifier<VentlyThemeMode> {
  ThemeModeController() : super(VentlyThemeMode.light) {
    _restore();
  }

  static const _prefsKey = 'vently.themeMode';

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_prefsKey)) {
      case 'dark':
        state = VentlyThemeMode.dark;
      case 'black':
        state = VentlyThemeMode.black;
      case 'light':
        state = VentlyThemeMode.light;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, state.name);
  }

  void setMode(VentlyThemeMode mode) {
    state = mode;
    _persist();
  }
}

/// Data Saver — for 2G/3G networks and expensive data plans. When on:
/// smaller image decodes, no whisper autoplay, reduced list prefetch.
final dataSaverProvider = StateNotifierProvider<DataSaverController, bool>(
  (ref) => DataSaverController(),
);

class DataSaverController extends StateNotifier<bool> {
  DataSaverController() : super(false) {
    _restore();
  }

  static const _prefsKey = 'vently.dataSaver';

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_prefsKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, enabled);
  }
}

/// Remote feature flags, server-evaluated with deterministic percentage
/// rollouts (migration 0118). Updates live when an admin flips a flag.
final featureFlagsProvider = StreamProvider<Map<String, bool>>((ref) {
  final me = ref.watch(sessionProvider);
  if (me == null) return Stream.value(const <String, bool>{});
  return ref.watch(repositoryProvider).watchFeatureFlags();
});

/// One flag, with a fallback for when the row doesn't exist yet — default
/// to enabled for shipped features so a missing row can't dark-launch an
/// outage.
bool flagEnabled(WidgetRef ref, String key, {bool fallback = true}) {
  final flags = ref.watch(featureFlagsProvider).valueOrNull;
  if (flags == null) return fallback;
  return flags[key] ?? fallback;
}

/// Idle-state trending searches (24h hot categories + tribes).
final trendingSearchesProvider =
    FutureProvider.autoDispose<List<SearchSuggestion>>((ref) {
      return ref.watch(repositoryProvider).trendingSearches();
    });

/// Debounced typo-tolerant search typeahead.
final searchSuggestionsProvider = FutureProvider.autoDispose
    .family<List<SearchSuggestion>, String>((ref, prefix) async {
      if (prefix.trim().length < 2) return const <SearchSuggestion>[];
      // Debounce keystrokes — cancelled instances never hit the network.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      return ref.watch(repositoryProvider).searchSuggestions(prefix.trim());
    });

/// Feed filter state.
///
/// `scope` controls global vs local. `sort` controls foryou vs hot vs fresh.
/// `tribeSlug` overrides scope when set.
class FeedFilter {
  final String? category;
  final String? mood;
  final String? tribeSlug;
  final String scope; // 'global' | 'local'
  final String sort; // 'foryou' | 'hot' | 'fresh'
  const FeedFilter({
    this.category,
    this.mood,
    this.tribeSlug,
    this.scope = 'global',
    this.sort = 'foryou',
  });

  FeedFilter copyWith({
    Object? category = _unset,
    String? mood,
    String? tribeSlug,
    String? scope,
    String? sort,
    bool clearMood = false,
    bool clearTribe = false,
  }) {
    return FeedFilter(
      category: category == _unset ? this.category : category as String?,
      mood: clearMood ? null : (mood ?? this.mood),
      tribeSlug: clearTribe ? null : (tribeSlug ?? this.tribeSlug),
      scope: scope ?? this.scope,
      sort: sort ?? this.sort,
    );
  }

  static const Object _unset = Object();
}

final feedFilterProvider = StateProvider<FeedFilter>(
  (ref) => const FeedFilter(),
);

final feedPostsProvider = StreamProvider<List<Post>>((ref) {
  final repo = ref.watch(repositoryProvider);
  final filter = ref.watch(feedFilterProvider);
  final me = ref.watch(sessionProvider);
  final bucket = filter.scope == 'local' ? me?.localBucket : null;
  return repo.watchFeed(
    category: filter.category,
    mood: filter.mood,
    tribeSlug: filter.tribeSlug,
    locationBucket: bucket,
    sort: filter.sort,
  );
});

/// Broad hot sample for Home discovery modules. It intentionally ignores the
/// active category/mood filters so Trending Topics and Tribes keep showing the
/// whole app pulse while the main feed list can be narrowed.
final homeDiscoveryPostsProvider = FutureProvider.autoDispose<List<Post>>((
  ref,
) async {
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).feed(sort: 'hot');
});

/// Authoritative topic totals from an RLS-aware server aggregate. A feed page
/// is deliberately not used here because pagination would under-count posts
/// and replies for every category beyond the first page.
final trendingTopicStatsProvider =
    FutureProvider.autoDispose<List<TrendingTopic>>((ref) async {
      ref.watch(feedPostsProvider);
      return ref.watch(repositoryProvider).trendingTopicStats();
    });

/// Friend-scoped 24h story posts for Home + the full story viewer.
final friendStoryPostsProvider = FutureProvider.autoDispose<List<Post>>((
  ref,
) async {
  final me = ref.watch(sessionProvider);
  if (me == null) return const [];
  ref.watch(feedPostsProvider);
  final friends = await ref.watch(myFriendsProvider.future);
  final friendIds = friends.map((f) => f.userId).toSet();
  final posts = await ref.watch(repositoryProvider).friendStories(limit: 36);
  final cutoff = DateTime.now().subtract(const Duration(hours: 24));
  return posts
      .where(
        (p) =>
            p.isStory &&
            p.authorId != null &&
            p.createdAt.isAfter(cutoff) &&
            (p.authorId == me.userId || friendIds.contains(p.authorId)),
      )
      .toList();
});

/// Friend-scoped 24h stories for the Home rail (self + accepted friends).
final homeFriendStoriesProvider = FutureProvider.autoDispose<List<VentStory>>((
  ref,
) async {
  final me = ref.watch(sessionProvider);
  final friends = await ref.watch(myFriendsProvider.future);
  final posts = await ref.watch(friendStoryPostsProvider.future);
  final friendIds = friends.map((f) => f.userId).toSet();
  return HomeDiscovery.friendStories(
    posts: posts,
    myUserId: me?.userId,
    friendUserIds: friendIds,
  );
});

class StoryRepliesEnabledNotifier extends AutoDisposeAsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final me = ref.watch(sessionProvider);
    if (me == null) return true;
    return ref.watch(repositoryProvider).storyRepliesEnabled();
  }

  Future<void> setEnabled(bool enabled) async {
    final previous = state.valueOrNull ?? true;
    state = AsyncData(enabled);
    try {
      final saved = await ref
          .read(repositoryProvider)
          .setStoryRepliesEnabled(enabled);
      state = AsyncData(saved);
    } catch (error, stackTrace) {
      state = AsyncData(previous);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final storyRepliesEnabledProvider =
    AsyncNotifierProvider.autoDispose<StoryRepliesEnabledNotifier, bool>(
      StoryRepliesEnabledNotifier.new,
    );

/// True when the signed-in user may start a NEW chat with this user. False for
/// a restricted minor (13-17), who can still reply in threads that exist.
final dmInitiationAllowedProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, userId) {
      return ref.watch(repositoryProvider).canInitiateDm(userId);
    });

final storyReplyAllowedProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, postId) {
      return ref.watch(repositoryProvider).canReplyToStory(postId);
    });

final storyReactionsProvider = FutureProvider.autoDispose
    .family<List<StoryReactionUser>, String>((ref, postId) {
      ref.watch(feedPostsProvider);
      return ref.watch(repositoryProvider).storyReactions(postId);
    });

final inboxTabProvider = StateProvider<String>((ref) => 'requests');
final inboxStreamProvider = StreamProvider<List<ChatRoom>>((ref) {
  final repo = ref.watch(repositoryProvider);
  final tab = ref.watch(inboxTabProvider);
  return repo.watchInbox(tab);
});

/// Full inbox list for badges + foreground notification diffing.
final allInboxRoomsStreamProvider = StreamProvider<List<ChatRoom>>((ref) {
  return ref.watch(repositoryProvider).watchInbox('all');
});

// ----------------------------------------------------------------------
// Async read providers (used by screens that previously called the
// repository synchronously).
// ----------------------------------------------------------------------

final plugzListProvider = FutureProvider.autoDispose<List<PlugProfile>>(
  (ref) async => ref.watch(repositoryProvider).allPlugz(),
);

final plugByNameProvider = FutureProvider.autoDispose
    .family<PlugProfile?, String>(
      (ref, name) async => ref.watch(repositoryProvider).plug(name),
    );

final plugTribesProvider = FutureProvider.autoDispose
    .family<List<Tribe>, String>(
      (ref, plugId) async =>
          ref.watch(repositoryProvider).tribesByKeeper(plugId),
    );

final plugPostsProvider = FutureProvider.autoDispose.family<List<Post>, String>(
  (ref, plugId) async =>
      ref.watch(repositoryProvider).postsByKeeper(plugId, limit: 12),
);

final userPostsProvider = FutureProvider.autoDispose.family<List<Post>, String>(
  (ref, userId) async =>
      ref.watch(repositoryProvider).postsByAuthor(userId, limit: 12),
);

/// Directory of Tribes — filtered by [TribeQuery.category] / .search.
class TribeQuery {
  final String? category;
  final String? search;
  const TribeQuery({this.category, this.search});

  @override
  bool operator ==(Object other) =>
      other is TribeQuery &&
      other.category == category &&
      other.search == search;
  @override
  int get hashCode => Object.hash(category, search);
}

final tribesProvider = FutureProvider.autoDispose
    .family<List<Tribe>, TribeQuery>(
      (ref, q) async => ref
          .watch(repositoryProvider)
          .tribes(category: q.category, search: q.search),
    );

/// Ranked Tribe discovery for the Circle screen. This intentionally reuses
/// the loaded feed instead of issuing another ranking request, keeping the tab
/// responsive on slow networks while still adapting to each user's activity.
final recommendedTribesProvider = FutureProvider.autoDispose
    .family<List<TribeRecommendation>, TribeQuery>((ref, query) async {
      final posts = ref.watch(feedPostsProvider).valueOrNull ?? const <Post>[];
      final tribes = await ref.watch(tribesProvider(query).future);
      return TribeRecommendations.rank(
        tribes: tribes,
        personalizedPosts: posts,
      );
    });

final tribeBySlugProvider = FutureProvider.autoDispose.family<Tribe?, String>(
  (ref, slug) async => ref.watch(repositoryProvider).tribeBySlug(slug),
);

/// Tribes the current user keeps (manages). Plug Dashboard data source.
final tribesIKeepProvider = FutureProvider.autoDispose<List<Tribe>>(
  (ref) async => ref.watch(repositoryProvider).tribesIKeep(),
);

final tribeManagementProvider = FutureProvider.autoDispose
    .family<TribeManagementOverview, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeManagementOverview(tribeId),
    );

final tribeJoinRequestsProvider = FutureProvider.autoDispose
    .family<List<TribeJoinRequest>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeJoinRequests(tribeId),
    );

final tribeAuditLogProvider = FutureProvider.autoDispose
    .family<List<TribeAuditEvent>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeAuditLog(tribeId),
    );

final managedTribePostsProvider = FutureProvider.autoDispose
    .family<List<TribeManagedPost>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).managedTribePosts(tribeId),
    );

/// Authoritative keeper mode from `is_keeper_mode` RPC (0062).
final keeperModeProvider = FutureProvider.autoDispose<KeeperMode>((ref) async {
  ref.watch(sessionProvider);
  return ref.watch(repositoryProvider).keeperMode();
});

/// True when the user operates in Keeper / Plug / Creator mode.
///
/// Uses server RPC first; falls back to client checks if RPC unavailable.
final isKeeperProvider = FutureProvider.autoDispose<bool>((ref) async {
  final me = ref.watch(sessionProvider);
  if (me == null) return false;

  try {
    final mode = await ref.watch(keeperModeProvider.future);
    return mode.isKeeper;
  } catch (_) {
    if (me.isPlug) return true;
    final tribes = await ref.watch(tribesIKeepProvider.future);
    return tribes.isNotEmpty;
  }
});

/// Primary tribe for studio dashboards (highest member count among kept).
final primaryKeeperTribeProvider = Provider.autoDispose<Tribe?>((ref) {
  final tribes = ref.watch(tribesIKeepProvider).valueOrNull;
  if (tribes == null || tribes.isEmpty) return null;
  return tribes.first;
});

/// When true, keepers see the normal member feed instead of Control Center.
final keeperMemberViewProvider = StateProvider<bool>((ref) => false);

/// Studio stats rolled up across all kept tribes — one parallel fetch.
final keeperOverviewProvider = FutureProvider.autoDispose<KeeperOverview>((
  ref,
) async {
  final tribes = await ref.watch(tribesIKeepProvider.future);
  if (tribes.isEmpty) return KeeperOverview.empty();
  final repo = ref.read(repositoryProvider);
  final statsList = await Future.wait(
    tribes.map((t) => repo.tribeStudioStats(t.tribeId)),
  );
  final byId = <String, TribeStudioStats?>{};
  for (var i = 0; i < tribes.length; i++) {
    byId[tribes[i].tribeId] = statsList[i];
  }
  return KeeperOverview(tribes: tribes, statsByTribeId: byId);
});

final keeperModerationQueueProvider = FutureProvider.autoDispose
    .family<KeeperModerationQueue, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).keeperModerationQueue(tribeId),
    );

final keeperEngagementCalendarProvider = FutureProvider.autoDispose
    .family<KeeperEngagementCalendar, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).keeperEngagementCalendar(tribeId),
    );

final keeperAiInsightsProvider = FutureProvider.autoDispose
    .family<KeeperAiInsights, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).keeperAiInsights(tribeId),
    );

final keeperComodMatrixProvider = FutureProvider.autoDispose
    .family<KeeperComodMatrix, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).keeperComodMatrix(tribeId),
    );

// ─── Spaces (Tribe → Space → Vent, migration 0050) ───────────────────

final spacesByTribeProvider = FutureProvider.autoDispose
    .family<List<Space>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).spacesByTribe(tribeId),
    );

final spaceByIdProvider = FutureProvider.autoDispose.family<Space?, String>(
  (ref, spaceId) async => ref.watch(repositoryProvider).spaceById(spaceId),
);

class SpaceFeedQuery {
  final String spaceId;
  final String sort; // fresh | trending | helpful | unanswered
  const SpaceFeedQuery({required this.spaceId, this.sort = 'fresh'});
  @override
  bool operator ==(Object other) =>
      other is SpaceFeedQuery && other.spaceId == spaceId && other.sort == sort;
  @override
  int get hashCode => Object.hash(spaceId, sort);
}

final spacePostsProvider = FutureProvider.autoDispose
    .family<List<Post>, SpaceFeedQuery>(
      (ref, q) async => ref
          .watch(repositoryProvider)
          .postsInSpace(spaceId: q.spaceId, sort: q.sort),
    );

final spaceSummaryProvider = FutureProvider.autoDispose
    .family<SpaceSummary?, String>(
      (ref, spaceId) async =>
          ref.watch(repositoryProvider).latestSpaceSummary(spaceId),
    );

/// Transient: when set, the next compose-screen open pre-fills this Tribe.
/// Cleared by the compose screen after it picks it up.
final composeTargetTribeProvider = StateProvider<Tribe?>((ref) => null);

/// Transient: when set, the next compose-screen open pre-fills this Space
/// (and its parent Tribe). Cleared by the compose screen after it picks
/// it up. Drives the Tribe → Space → Vent flow from migration 0050.
final composeTargetSpaceProvider = StateProvider<Space?>((ref) => null);

/// When true, the next compose-screen open starts as a 24h Vent Story.
/// Cleared by the compose screen after it reads the flag.
final composeStoryModeProvider = StateProvider<bool>((ref) => false);

/// Optional category for the next compose-screen open.
final composeInitialCategoryProvider = StateProvider<String?>((ref) => null);

/// Optional draft text the next compose-screen open should pre-fill.
/// Used by the AI Space Assistant's "Use this prompt" CTA.
final composeInitialDraftProvider = StateProvider<String?>((ref) => null);

/// When true, the next compose-screen open enables the poll composer.
final composeIncludePollProvider = StateProvider<bool>((ref) => false);

/// The user's personas (alternate anonymous handles).
final myPersonasProvider = FutureProvider.autoDispose<List<Persona>>(
  (ref) async => ref.watch(repositoryProvider).myPersonas(),
);

/// Client-only: which persona (if any) the user wants their next post or
/// comment to author under. null = use the default profile. Never persisted —
/// reset on every app launch so personas are an opt-in per-session choice.
final activePersonaProvider = StateProvider<Persona?>((ref) => null);

/// Crisis helplines, region-biased by the current user's locationBucket
/// (first two characters treated as ISO country code). Falls back to the
/// global list when no session or no bucket is set.
final crisisResourcesProvider =
    FutureProvider.autoDispose<List<CrisisHelpline>>((ref) async {
      final me = ref.watch(sessionProvider);
      final bucket = me?.localBucket;
      final region = (bucket != null && bucket.length >= 2)
          ? bucket.substring(0, 2).toUpperCase()
          : null;
      return ref.watch(repositoryProvider).crisisResources(region: region);
    });

// ----------------------------------------------------------------------
// Friend graph (migration 0024)
// ----------------------------------------------------------------------

/// All accepted friendships of the current user.
final myFriendsProvider = FutureProvider.autoDispose<List<FriendSummary>>((
  ref,
) async {
  ref.watch(friendshipEventsProvider); // live: re-fetch on realtime change
  return ref.watch(repositoryProvider).myFriends();
});

/// Incoming pending requests addressed to the current user.
/// Ticks on every friendships change involving me — makes friend-request
/// lists + badges live (friendships joined the publication in 0112).
final friendshipEventsProvider = StreamProvider.autoDispose<int>(
  (ref) => ref.watch(repositoryProvider).watchFriendshipEvents(),
);

final incomingFriendRequestsProvider =
    FutureProvider.autoDispose<List<FriendRequest>>((ref) async {
      ref.watch(friendshipEventsProvider); // re-fetch on realtime change
      return ref.watch(repositoryProvider).incomingFriendRequests();
    });

/// Outgoing pending requests the current user sent.
final outgoingFriendRequestsProvider =
    FutureProvider.autoDispose<List<FriendRequest>>(
      (ref) async => ref.watch(repositoryProvider).outgoingFriendRequests(),
    );

/// Users the current user has blocked.
final myBlocksProvider = FutureProvider.autoDispose<List<BlockedUser>>(
  (ref) async => ref.watch(repositoryProvider).myBlocks(),
);

/// Friend status between the current user and a target. Used by every
/// friend-action button across the app so the chip rewrites itself
/// after each tap without screen-level state-management plumbing.
final friendStatusProvider = FutureProvider.autoDispose
    .family<FriendStatus, String>(
      (ref, otherUserId) async =>
          ref.watch(repositoryProvider).friendStatus(otherUserId),
    );

/// Single-roundtrip Friend Profile read. Null = blocked-by-them or
/// user doesn't exist; the screen renders a 404 in that case.
final userProfileProvider = FutureProvider.autoDispose
    .family<UserProfileView?, String>(
      (ref, userId) async => ref.watch(repositoryProvider).userProfile(userId),
    );

/// 🫂 total hugs received for a user (own-profile banner). Migration 0107.
final hugsReceivedProvider = FutureProvider.autoDispose.family<int, String>(
  (ref, userId) async => ref.watch(repositoryProvider).hugsReceivedFor(userId),
);

/// Caller's verification standing: 'verified' | 'pending' | 'denied' | 'none'.
/// Migration 0109 — powers the "Apply for verified" affordance.
final myVerificationStatusProvider = FutureProvider.autoDispose<String>((ref) {
  ref.watch(sessionProvider);
  return ref.watch(repositoryProvider).myVerificationStatus();
});

// ----------------------------------------------------------------------
// Plugz Creator Studio (migration 0028)
// ----------------------------------------------------------------------

final tribeStudioStatsProvider = FutureProvider.autoDispose
    .family<TribeStudioStats?, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeStudioStats(tribeId),
    );

final tribePinnedPostsProvider = FutureProvider.autoDispose
    .family<List<Post>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).pinnedPosts(tribeId),
    );

final tribePromptsProvider = FutureProvider.autoDispose
    .family<List<ScheduledPrompt>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribePrompts(tribeId),
    );

/// Reports filed against posts in a specific Tribe — Keeper-only.
final tribeReportsProvider = FutureProvider.autoDispose
    .family<List<TribeReport>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeReports(tribeId),
    );

/// Anonymous answers to a Question of the Day.
final promptAnswersProvider = FutureProvider.autoDispose
    .family<List<PromptAnswer>, String>(
      (ref, promptId) async =>
          ref.watch(repositoryProvider).promptAnswers(promptId),
    );

final promptsProvider = FutureProvider.autoDispose<List<PlugPrompt>>(
  (ref) async => ref.watch(repositoryProvider).prompts(),
);

/// Questions a given member has asked — powers the "Questions asked" section
/// on public profiles (and the caller's own list).
final userQuestionsProvider = FutureProvider.autoDispose
    .family<List<PlugPrompt>, String>(
      (ref, userId) async =>
          ref.watch(repositoryProvider).questionsByAuthor(userId),
    );

/// Live notification feed — realtime via the notifications publication
/// (migration 0113), so the bell list + badge update the instant a like,
/// reply, or friend request lands.
final notificationsProvider =
    StreamProvider.autoDispose<List<NotificationItem>>(
      (ref) => ref.watch(repositoryProvider).watchNotifications(),
    );

/// Unread notification count — derived from notificationsProvider so it
/// updates whenever the list does. Used by the bell-icon badge.
final unreadNotificationsCountProvider = Provider.autoDispose<int>((ref) {
  final items =
      ref.watch(notificationsProvider).valueOrNull ??
      const <NotificationItem>[];
  return items.where((n) => !n.isRead).length;
});

/// A poll attached to a single Post, if any.
final pollForPostProvider = FutureProvider.autoDispose
    .family<PostPoll?, String>(
      (ref, postId) async => ref.watch(repositoryProvider).pollForPost(postId),
    );

/// Pending tribe invitations waiting on the current user.
final myInvitesProvider = FutureProvider.autoDispose<List<TribeInvite>>(
  (ref) async => ref.watch(repositoryProvider).myPendingInvites(),
);

final tribeMembersProvider = FutureProvider.autoDispose
    .family<List<TribeMemberRow>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeMembers(tribeId),
    );

final badgeCatalogueProvider =
    FutureProvider.autoDispose<List<BadgeDefinition>>(
      (ref) async => ref.watch(repositoryProvider).badgeCatalogue(),
    );

final badgesForUserProvider = FutureProvider.autoDispose
    .family<List<UserBadge>, String>(
      (ref, userId) async => ref.watch(repositoryProvider).badgesFor(userId),
    );

final myStreaksProvider = FutureProvider.autoDispose<List<UserStreak>>(
  (ref) async => ref.watch(repositoryProvider).myStreaks(),
);

final myVentsProvider = FutureProvider.autoDispose<List<Post>>((ref) async {
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).myVents();
});

/// Current user's active Stories. Keep this separate from [myVentsProvider]:
/// that mixed-content query is paginated, so a valid Story could otherwise
/// disappear from the profile when enough newer vents were published.
final myStoriesProvider = FutureProvider.autoDispose<List<Post>>((ref) async {
  final me = ref.watch(sessionProvider);
  if (me == null) return const [];
  ref.watch(feedPostsProvider);
  return ref
      .watch(repositoryProvider)
      .activeStoriesByAuthor(me.userId, limit: 48);
});

final mySavedProvider = FutureProvider.autoDispose<List<Post>>((ref) async {
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).mySaved();
});

final mySavedWhispersProvider = FutureProvider.autoDispose<List<Whisper>>((
  ref,
) async {
  ref.watch(whispersFeedProvider);
  return ref.watch(repositoryProvider).mySavedWhispers();
});

/// Current user's published whispers — drives the Profile Whispers tab.
final myWhispersProvider = FutureProvider.autoDispose<List<Whisper>>((
  ref,
) async {
  final me = ref.watch(sessionProvider);
  if (me == null) return const [];
  ref.watch(whispersFeedProvider);
  return ref.watch(repositoryProvider).whispersForAuthor(me.userId, limit: 48);
});

/// Trending whispers for the home discovery rail — ranked by engagement.
final popularWhispersProvider = FutureProvider.autoDispose<List<Whisper>>((
  ref,
) async {
  ref.watch(whispersFeedProvider);
  final list = await ref.read(repositoryProvider).listWhispers(limit: 24);
  final ranked = list.toList()
    ..sort((a, b) {
      final scoreA = a.playsCount + a.likesCount * 2 + a.commentsCount;
      final scoreB = b.playsCount + b.likesCount * 2 + b.commentsCount;
      return scoreB.compareTo(scoreA);
    });
  return ranked.take(10).toList();
});

/// A post the user has already been allowed to see in the active feed.
///
/// Keeping this lookup separate gives post routes an immediate, reliable
/// fallback while the authoritative detail request refreshes in the
/// background. It also prevents a brief network/RLS mismatch from turning a
/// post that is visibly on screen into a blank thread.
final knownFeedPostProvider = Provider.family<Post?, String>((ref, postId) {
  return ref
      .watch(feedPostsProvider)
      .valueOrNull
      ?.firstWhereOrNull((post) => post.postId == postId);
});

final postByIdProvider = FutureProvider.autoDispose.family<Post?, String>((
  ref,
  postId,
) async {
  final knownPost = ref.watch(knownFeedPostProvider(postId));
  try {
    return await ref.watch(repositoryProvider).postById(postId) ?? knownPost;
  } catch (error, stackTrace) {
    if (knownPost != null) return knownPost;
    Error.throwWithStackTrace(error, stackTrace);
  }
});

final commentsProvider = FutureProvider.autoDispose
    .family<List<ThreadedComment>, String>(
      (ref, postId) async => ref.watch(repositoryProvider).comments(postId),
    );

final messagesProvider = StreamProvider.autoDispose
    .family<List<ChatMessage>, String>(
      (ref, roomId) => ref.watch(repositoryProvider).watchMessages(roomId),
    );

/// Per-user DM room preferences (mute, nickname, theme).
final dmRoomPrefsProvider = FutureProvider.autoDispose
    .family<DmRoomPrefs, String>(
      (ref, roomId) => ref.watch(repositoryProvider).dmRoomPrefs(roomId),
    );

/// Conversation-level disappearing-message TTL in seconds (0 = off, shared by
/// both participants — migration 0099).
final roomDisappearingProvider = FutureProvider.autoDispose.family<int, String>(
  (ref, roomId) =>
      ref.watch(repositoryProvider).roomDisappearingSeconds(roomId),
);

/// True while the peer in [roomId] is actively typing. Flips false ~3s
/// after the last broadcast. Pure ephemeral signal — no DB read.
final typingProvider = StreamProvider.autoDispose.family<bool, String>(
  (ref, roomId) => ref.watch(repositoryProvider).watchTyping(roomId),
);

/// Peer presence tier (online / recent / offline / hidden) — re-polled
/// every 30s while watched so the chat header stays honest.
final peerPresenceProvider = FutureProvider.autoDispose
    .family<({String state, DateTime? lastSeen}), String>((ref, userId) {
      final timer = Timer(
        const Duration(seconds: 30),
        () => ref.invalidateSelf(),
      );
      ref.onDispose(timer.cancel);
      return ref.watch(repositoryProvider).peerPresence(userId);
    });

final roomByIdProvider = FutureProvider.autoDispose.family<ChatRoom?, String>((
  ref,
  roomId,
) async {
  final repo = ref.watch(repositoryProvider);
  final rooms = [
    ...await repo.inbox('active'),
    ...await repo.inbox('requests'),
  ];
  for (final r in rooms) {
    if (r.roomId == roomId) return r;
  }
  return null;
});

final groupChatMembersProvider = FutureProvider.autoDispose
    .family<List<GroupChatMember>, String>((ref, roomId) async {
      return ref.watch(repositoryProvider).groupChatMembers(roomId);
    });

final groupAvatarUrlProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, storagePath) async {
      if (storagePath.trim().isEmpty) return null;
      return ref.watch(repositoryProvider).chatImageSignedUrl(storagePath);
    });

final groupInvitePreviewProvider = FutureProvider.autoDispose
    .family<GroupInvitePreview?, String>((ref, token) async {
      return ref.watch(repositoryProvider).groupInvitePreview(token);
    });

final inboxCountsProvider = FutureProvider.autoDispose<Map<String, int>>((
  ref,
) async {
  final repo = ref.watch(repositoryProvider);
  final pending = await repo.inbox('requests');
  final active = await repo.inbox('active');
  return {'requests': pending.length, 'active': active.length};
});

/// Aggregated inbox badge count — pending requests + unread peer messages.
/// Prefer [navInboxBadgeCountProvider] for the tab badge (also folds in
/// incoming friend requests).
final unreadInboxCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final rooms = await ref.watch(allInboxRoomsStreamProvider.future);
  final unreadChats = rooms
      .where((room) => room.roomStatus == 'active')
      .fold<int>(0, (total, room) => total + room.unreadCount);
  final pending = rooms
      .where(
        (room) => room.roomStatus == 'pending_request' && !room.initiatedByMe,
      )
      .length;
  return unreadChats + pending;
});

/// Inbox tab badge: pending chat requests + unread peer messages +
/// incoming friend requests.
final navInboxBadgeCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final rooms = await ref.watch(allInboxRoomsStreamProvider.future);
  final incoming = await ref.watch(incomingFriendRequestsProvider.future);
  final unreadChats = rooms
      .where((room) => room.roomStatus == 'active')
      .fold<int>(0, (total, room) => total + room.unreadCount);
  final pending = rooms
      .where(
        (room) => room.roomStatus == 'pending_request' && !room.initiatedByMe,
      )
      .length;
  return unreadChats + pending + incoming.length;
});

// ----------------------------------------------------------------------
// Premium home (migration 0038)
// ----------------------------------------------------------------------

final homeStatsProvider = FutureProvider.autoDispose<HomeStats>((ref) async {
  // Keep stats fresh when the feed reloads.
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).homeStats();
});

final trendingCategoriesProvider =
    FutureProvider.autoDispose<List<TrendingCategory>>((ref) async {
      ref.watch(feedPostsProvider);
      return ref.watch(repositoryProvider).trendingCategories(limit: 6);
    });

final trendingVoicesProvider = FutureProvider.autoDispose<List<TrendingVoice>>((
  ref,
) async {
  return ref.watch(repositoryProvider).trendingVoices(limit: 6);
});

/// Quick Suggestions for the Friends screen — mutual-tribe acquaintances
/// minus current friends + blocks.
final friendSuggestionsProvider =
    FutureProvider.autoDispose<List<FriendSuggestion>>((ref) async {
      ref.watch(myFriendsProvider);
      return ref.watch(repositoryProvider).friendSuggestions(limit: 8);
    });

/// Realtime stream of group-chat messages in a single tribe (migration 0041).
final tribeMessagesProvider = StreamProvider.autoDispose
    .family<List<TribeMessage>, String>(
      (ref, tribeId) =>
          ref.watch(repositoryProvider).watchTribeMessages(tribeId),
    );

/// Snapshot of how many tribe members are present (proxy: total members
/// until presence channel ships).
final tribeChatPresenceProvider = FutureProvider.autoDispose
    .family<int, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeChatPresence(tribeId),
    );

/// Online/active members for the tribe chat hub.
final tribeOnlineMembersProvider = FutureProvider.autoDispose
    .family<List<TribeOnlineMember>, String>(
      (ref, tribeId) async =>
          ref.watch(repositoryProvider).tribeOnlineMembers(tribeId),
    );

/// Who is typing in a tribe group chat (Realtime broadcast).
final tribeTypingProvider = StreamProvider.autoDispose
    .family<List<TribeTypingUser>, String>(
      (ref, tribeId) => ref.watch(repositoryProvider).watchTribeTyping(tribeId),
    );

/// Inbox summaries for joined tribe group chats (unread + preview).
final tribeChatInboxProvider =
    FutureProvider.autoDispose<List<TribeChatInboxSummary>>(
      (ref) => ref.watch(repositoryProvider).tribeChatInbox(),
    );

/// Shared media in a tribe chat (photos + voice notes).
final tribeChatMediaProvider = FutureProvider.autoDispose
    .family<List<TribeChatMediaItem>, String>(
      (ref, tribeId) => ref.watch(repositoryProvider).tribeChatMedia(tribeId),
    );

/// True when the current user can manage this tribe (keeper or mod).
final canManageTribeProvider = Provider.autoDispose.family<bool, String>((
  ref,
  tribeId,
) {
  final me = ref.watch(sessionProvider);
  if (me == null) return false;
  final members = ref.watch(tribeMembersProvider(tribeId)).valueOrNull;
  if (members != null) {
    final row = members.where((m) => m.userId == me.userId).firstOrNull;
    if (row != null && (row.role == 'keeper' || row.role == 'mod')) {
      return true;
    }
  }
  final kept = ref.watch(tribesIKeepProvider).valueOrNull ?? const [];
  return kept.any((t) => t.tribeId == tribeId);
});

/// Active category filter on the Whispers feed.
final whispersCategoryProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

/// Paginated Whispers feed — infinite vertical scroll (Reels-style).
class WhispersFeedNotifier extends AutoDisposeAsyncNotifier<List<Whisper>> {
  static const pageSize = 12;

  bool _hasMore = true;
  bool _loadingMore = false;
  String? _categoryKey;

  bool get hasMore => _hasMore;
  bool get isLoadingMore => _loadingMore;

  @override
  Future<List<Whisper>> build() async {
    final category = ref.watch(whispersCategoryProvider);
    _categoryKey = category;
    _hasMore = true;
    _loadingMore = false;
    final first = await _fetch(category: category, after: null);
    _hasMore = first.length >= pageSize;
    return first;
  }

  /// [after] is the last row already displayed — the keyset cursor. Null asks
  /// for the newest page.
  ///
  /// Deriving the cursor from what is on screen rather than tracking an offset
  /// means the two can never disagree, which is exactly how offset pagination
  /// skipped rows once new whispers shifted the window.
  Future<List<Whisper>> _fetch({
    required String? category,
    required Whisper? after,
  }) {
    return ref
        .read(repositoryProvider)
        .listWhispers(
          limit: pageSize,
          category: category,
          beforeCreatedAt: after?.createdAt,
          beforeWhisperId: after?.whisperId,
        );
  }

  Future<void> loadMore() async {
    if (!_hasMore || _loadingMore) return;
    final current = state.valueOrNull;
    // Empty means there is no cursor to seek from; refresh is the way back.
    if (current == null || current.isEmpty) return;

    _loadingMore = true;
    try {
      final category = ref.read(whispersCategoryProvider);
      if (category != _categoryKey) return;
      final next = await _fetch(category: category, after: current.last);
      if (next.isEmpty) {
        _hasMore = false;
        return;
      }
      _hasMore = next.length >= pageSize;
      final seen = current.map((w) => w.whisperId).toSet();
      final merged = [
        ...current,
        for (final w in next)
          if (!seen.contains(w.whisperId)) w,
      ];
      state = AsyncData(merged);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final whispersFeedProvider =
    AsyncNotifierProvider.autoDispose<WhispersFeedNotifier, List<Whisper>>(
      WhispersFeedNotifier.new,
    );

/// Whispers scoped to a single user — drives the "Whispers" card on
/// the friend profile screen.
final userWhispersProvider = FutureProvider.autoDispose
    .family<List<Whisper>, String>(
      (ref, userId) =>
          ref.watch(repositoryProvider).whispersForAuthor(userId, limit: 12),
    );

/// Public tribes a user belongs to — drives the "Tribes" section on the
/// friend profile screen. Private tribes are only returned to fellow members.
final userPublicTribesProvider = FutureProvider.autoDispose
    .family<List<Tribe>, String>(
      (ref, userId) => ref.watch(repositoryProvider).userPublicTribes(userId),
    );

/// Debounced @-autocomplete candidates while typing a tag (0116).
final tagCandidatesProvider = FutureProvider.autoDispose
    .family<List<TagCandidate>, String>((ref, prefix) async {
      if (prefix.trim().isEmpty) return const <TagCandidate>[];
      // Debounce keystrokes — cancelled instances never hit the network.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      return ref.watch(repositoryProvider).searchTagCandidates(prefix);
    });

/// Live comments on a Whisper (migration 0059, realtime via 0111) —
/// re-emits on every insert/soft-delete so open sheets stay current.
final whisperCommentsProvider = StreamProvider.autoDispose
    .family<List<WhisperComment>, String>(
      (ref, whisperId) =>
          ref.watch(repositoryProvider).watchWhisperComments(whisperId),
    );

/// Shared audio player for the Whispers feed — kept alive for fast return.
final whisperPlayerProvider = FutureProvider<WhisperPlayerController>((
  ref,
) async {
  final controller = await WhisperPlayerController.create();
  ref.onDispose(() {
    unawaited(controller.dispose());
  });
  return controller;
});

/// Live search query for the Discover screen. Empty / very short
/// strings short-circuit to an empty result list inside the search RPC.
final discoverSearchQueryProvider = StateProvider.autoDispose<String>(
  (ref) => '',
);

/// Debounced search results — fires the search_global RPC 280ms after
/// the user stops typing so we don't hammer the backend on every keystroke.
final discoverSearchResultsProvider =
    FutureProvider.autoDispose<List<SearchHit>>((ref) async {
      final query = ref.watch(discoverSearchQueryProvider).trim();
      if (query.length < 2) return const [];
      await Future<void>.delayed(const Duration(milliseconds: 280));
      // Bail if the query changed during the debounce window — Riverpod will
      // throw if we return for a stale state, so check via the latest read.
      if (ref.read(discoverSearchQueryProvider).trim() != query)
        return const [];
      return ref.watch(repositoryProvider).searchGlobal(query);
    });

/// Friend-scoped live 24h story posts for the story viewer.
final liveStoriesProvider = FutureProvider.autoDispose<List<Post>>((ref) async {
  return ref.watch(friendStoryPostsProvider.future);
});
