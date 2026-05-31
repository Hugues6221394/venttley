import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/vently_repository.dart';
import '../data/services/moderation_service.dart';
import '../domain/entities/entities.dart';

final repositoryProvider = Provider<VentlyRepository>((ref) {
  return VentlyRepository();
});

final moderationServiceProvider =
    Provider<ModerationService>((ref) => ModerationService());

/// Reactive session — null when logged out.
final sessionProvider = StateNotifierProvider<SessionController, AppUser?>((ref) {
  final repo = ref.watch(repositoryProvider);
  return SessionController(repo);
});

class SessionController extends StateNotifier<AppUser?> {
  SessionController(this._repo) : super(_repo.currentUser);
  final VentlyRepository _repo;

  Future<void> restore() async {
    state = await _repo.restoreSession();
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
    return result;
  }

  /// Username + password sign-in for returning users.
  Future<AppUser> signIn({
    required String username,
    required String password,
  }) async {
    final user = await _repo.signIn(username: username, password: password);
    state = user;
    return user;
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
    if (user != null) state = user;
    return user;
  }

  Future<void> logout() async {
    await _repo.logout();
    state = null;
  }
}

/// Brightness mode controller — defaults to system.
final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
        (ref) => ThemeModeController());

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.light);
  void toggle() {
    state = state == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
  }
  void setMode(ThemeMode mode) => state = mode;
}

/// Feed filter state.
///
/// `scope` controls global vs local. `sort` controls fresh vs hot.
/// `tribeSlug` overrides scope when set.
class FeedFilter {
  final String? category;
  final String? mood;
  final String? tribeSlug;
  final String scope; // 'global' | 'local'
  final String sort;  // 'fresh'  | 'hot'
  const FeedFilter({
    this.category = 'confessions',
    this.mood,
    this.tribeSlug,
    this.scope = 'global',
    this.sort = 'fresh',
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

final feedFilterProvider =
    StateProvider<FeedFilter>((ref) => const FeedFilter());

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

final inboxTabProvider = StateProvider<String>((ref) => 'requests');
final inboxStreamProvider = StreamProvider<List<ChatRoom>>((ref) {
  final repo = ref.watch(repositoryProvider);
  final tab = ref.watch(inboxTabProvider);
  return repo.watchInbox(tab);
});

// ----------------------------------------------------------------------
// Async read providers (used by screens that previously called the
// repository synchronously).
// ----------------------------------------------------------------------

final plugzListProvider = FutureProvider.autoDispose<List<PlugProfile>>(
    (ref) async => ref.watch(repositoryProvider).allPlugz());

final plugByNameProvider =
    FutureProvider.autoDispose.family<PlugProfile?, String>(
        (ref, name) async => ref.watch(repositoryProvider).plug(name));

/// Directory of Tribes — filtered by [TribeQuery.category] / .search.
class TribeQuery {
  final String? category;
  final String? search;
  const TribeQuery({this.category, this.search});

  @override
  bool operator ==(Object other) =>
      other is TribeQuery && other.category == category && other.search == search;
  @override
  int get hashCode => Object.hash(category, search);
}

final tribesProvider =
    FutureProvider.autoDispose.family<List<Tribe>, TribeQuery>(
        (ref, q) async => ref
            .watch(repositoryProvider)
            .tribes(category: q.category, search: q.search));

final tribeBySlugProvider =
    FutureProvider.autoDispose.family<Tribe?, String>(
        (ref, slug) async => ref.watch(repositoryProvider).tribeBySlug(slug));

/// Transient: when set, the next compose-screen open pre-fills this Tribe.
/// Cleared by the compose screen after it picks it up.
final composeTargetTribeProvider = StateProvider<Tribe?>((ref) => null);

/// The user's personas (alternate anonymous handles).
final myPersonasProvider = FutureProvider.autoDispose<List<Persona>>(
    (ref) async => ref.watch(repositoryProvider).myPersonas());

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
final myFriendsProvider = FutureProvider.autoDispose<List<FriendSummary>>(
    (ref) async => ref.watch(repositoryProvider).myFriends());

/// Incoming pending requests addressed to the current user.
final incomingFriendRequestsProvider =
    FutureProvider.autoDispose<List<FriendRequest>>(
        (ref) async => ref.watch(repositoryProvider).incomingFriendRequests());

/// Outgoing pending requests the current user sent.
final outgoingFriendRequestsProvider =
    FutureProvider.autoDispose<List<FriendRequest>>(
        (ref) async => ref.watch(repositoryProvider).outgoingFriendRequests());

/// Users the current user has blocked.
final myBlocksProvider = FutureProvider.autoDispose<List<BlockedUser>>(
    (ref) async => ref.watch(repositoryProvider).myBlocks());

/// Friend status between the current user and a target. Used by every
/// friend-action button across the app so the chip rewrites itself
/// after each tap without screen-level state-management plumbing.
final friendStatusProvider =
    FutureProvider.autoDispose.family<FriendStatus, String>(
        (ref, otherUserId) async =>
            ref.watch(repositoryProvider).friendStatus(otherUserId));

/// Single-roundtrip Friend Profile read. Null = blocked-by-them or
/// user doesn't exist; the screen renders a 404 in that case.
final userProfileProvider =
    FutureProvider.autoDispose.family<UserProfileView?, String>(
        (ref, userId) async =>
            ref.watch(repositoryProvider).userProfile(userId));

/// Reports filed against posts in a specific Tribe — Keeper-only.
final tribeReportsProvider =
    FutureProvider.autoDispose.family<List<TribeReport>, String>(
        (ref, tribeId) async =>
            ref.watch(repositoryProvider).tribeReports(tribeId));

/// Anonymous answers to a Question of the Day.
final promptAnswersProvider =
    FutureProvider.autoDispose.family<List<PromptAnswer>, String>(
        (ref, promptId) async =>
            ref.watch(repositoryProvider).promptAnswers(promptId));

final promptsProvider = FutureProvider.autoDispose<List<PlugPrompt>>(
    (ref) async => ref.watch(repositoryProvider).prompts());

final notificationsProvider = FutureProvider.autoDispose<List<NotificationItem>>(
    (ref) async => ref.watch(repositoryProvider).notifications());

/// Unread notification count — derived from notificationsProvider so it
/// updates whenever the list does. Used by the bell-icon badge.
final unreadNotificationsCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
  final items = await ref.watch(notificationsProvider.future);
  return items.where((n) => !n.isRead).length;
});

/// A poll attached to a single Post, if any.
final pollForPostProvider =
    FutureProvider.autoDispose.family<PostPoll?, String>(
        (ref, postId) async =>
            ref.watch(repositoryProvider).pollForPost(postId));

/// Pending tribe invitations waiting on the current user.
final myInvitesProvider = FutureProvider.autoDispose<List<TribeInvite>>(
    (ref) async => ref.watch(repositoryProvider).myPendingInvites());

final tribeMembersProvider =
    FutureProvider.autoDispose.family<List<TribeMemberRow>, String>(
        (ref, tribeId) async =>
            ref.watch(repositoryProvider).tribeMembers(tribeId));

final badgeCatalogueProvider =
    FutureProvider.autoDispose<List<BadgeDefinition>>(
        (ref) async => ref.watch(repositoryProvider).badgeCatalogue());

final badgesForUserProvider =
    FutureProvider.autoDispose.family<List<UserBadge>, String>(
        (ref, userId) async =>
            ref.watch(repositoryProvider).badgesFor(userId));

final myStreaksProvider = FutureProvider.autoDispose<List<UserStreak>>(
    (ref) async => ref.watch(repositoryProvider).myStreaks());

final myVentsProvider = FutureProvider.autoDispose<List<Post>>((ref) async {
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).myVents();
});

final mySavedProvider = FutureProvider.autoDispose<List<Post>>((ref) async {
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).mySaved();
});

final postByIdProvider =
    FutureProvider.autoDispose.family<Post?, String>((ref, postId) async {
  ref.watch(feedPostsProvider);
  return ref.watch(repositoryProvider).postById(postId);
});

final commentsProvider =
    FutureProvider.autoDispose.family<List<ThreadedComment>, String>(
        (ref, postId) async =>
            ref.watch(repositoryProvider).comments(postId));

final messagesProvider =
    StreamProvider.autoDispose.family<List<ChatMessage>, String>(
        (ref, roomId) =>
            ref.watch(repositoryProvider).watchMessages(roomId));

final roomByIdProvider =
    FutureProvider.autoDispose.family<ChatRoom?, String>((ref, roomId) async {
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

final inboxCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
  final repo = ref.watch(repositoryProvider);
  final pending = await repo.inbox('requests');
  final active = await repo.inbox('active');
  return {
    'requests': pending.length,
    'active': active.length,
  };
});
