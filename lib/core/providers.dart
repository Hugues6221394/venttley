import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/vently_repository.dart';
import '../data/services/crypto_service.dart';
import '../data/services/moderation_service.dart';
import '../data/services/voice_mask_service.dart';
import '../domain/entities/entities.dart';

final repositoryProvider = Provider<VentlyRepository>((ref) {
  return VentlyRepository();
});

final cryptoServiceProvider = Provider<CryptoService>((ref) => CryptoService());
final moderationServiceProvider =
    Provider<ModerationService>((ref) => ModerationService());
final voiceMaskServiceProvider =
    Provider<VoiceMaskService>((ref) => VoiceMaskService());

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

  Future<AppUser> register({
    required DateTime birthDate,
    required String pseudonym,
    required String avatarSeed,
  }) async {
    final user = await _repo.bootstrapAccount(
      birthDate: birthDate,
      pseudonym: pseudonym,
      avatarSeed: avatarSeed,
    );
    state = user;
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
  final String? spaceName;
  const FeedFilter({this.category = 'confessions', this.mood, this.spaceName});

  FeedFilter copyWith({Object? category = _unset, String? mood, String? spaceName, bool clearMood = false, bool clearSpace = false}) {
    return FeedFilter(
      category: category == _unset ? this.category : category as String?,
      mood: clearMood ? null : (mood ?? this.mood),
      spaceName: clearSpace ? null : (spaceName ?? this.spaceName),
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
    spaceName: filter.spaceName,
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

final spacesProvider = FutureProvider.autoDispose<List<Space>>(
    (ref) async => ref.watch(repositoryProvider).spaces());

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
    FutureProvider.autoDispose.family<List<ChatMessage>, String>(
        (ref, roomId) async =>
            ref.watch(repositoryProvider).messages(roomId));

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
