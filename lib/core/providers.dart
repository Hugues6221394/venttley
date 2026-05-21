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
class FeedFilter {
  final String? category;
  final String? mood;
  final String? tribeSlug;
  const FeedFilter({this.category = 'confessions', this.mood, this.tribeSlug});

  FeedFilter copyWith({Object? category = _unset, String? mood, String? tribeSlug, bool clearMood = false, bool clearTribe = false}) {
    return FeedFilter(
      category: category == _unset ? this.category : category as String?,
      mood: clearMood ? null : (mood ?? this.mood),
      tribeSlug: clearTribe ? null : (tribeSlug ?? this.tribeSlug),
    );
  }
  static const Object _unset = Object();
}

final feedFilterProvider =
    StateProvider<FeedFilter>((ref) => const FeedFilter());

final feedPostsProvider = StreamProvider<List<Post>>((ref) {
  final repo = ref.watch(repositoryProvider);
  final filter = ref.watch(feedFilterProvider);
  return repo.watchFeed(
    category: filter.category,
    mood: filter.mood,
    tribeSlug: filter.tribeSlug,
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

final promptsProvider = FutureProvider.autoDispose<List<PlugPrompt>>(
    (ref) async => ref.watch(repositoryProvider).prompts());

final notificationsProvider = FutureProvider.autoDispose<List<NotificationItem>>(
    (ref) async => ref.watch(repositoryProvider).notifications());

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
