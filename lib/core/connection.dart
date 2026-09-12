import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/draft_store.dart';
import '../data/services/outbox.dart';
import 'providers.dart';

/// What the app should assume about the network right now.
enum ConnectionStatus { online, offline, reconnecting }

/// Crash-safe draft persistence, ready before any composer opens.
final draftStoreProvider = FutureProvider<DraftStore>((ref) {
  final userId = ref.watch(sessionProvider.select((user) => user?.userId));
  if (userId == null) throw StateError('Sign in before opening drafts');
  return DraftStore.open(userId: userId);
});

/// The offline retry queue. Lives for the whole session.
final outboxProvider = FutureProvider<OutboxService>((ref) async {
  final userId = ref.watch(sessionProvider.select((user) => user?.userId));
  final outbox = await OutboxService.open(
    ref.watch(repositoryProvider),
    userId: userId,
  );
  ref.onDispose(outbox.dispose);
  return outbox;
});

/// Count of queued sends, for badges/banners. Rebuilds when the outbox
/// changes.
final outboxPendingCountProvider = Provider<int>((ref) {
  final outbox = ref.watch(outboxProvider).valueOrNull;
  if (outbox == null) return 0;
  // Re-run this provider whenever the outbox notifies.
  final sub = _ListenableSub(outbox, () => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return outbox.pendingCount;
});

/// Sends that exhausted the automatic retry window. Their encrypted payloads
/// remain on-device until the user retries them.
final outboxFailedCountProvider = Provider<int>((ref) {
  final outbox = ref.watch(outboxProvider).valueOrNull;
  if (outbox == null) return 0;
  final sub = _ListenableSub(outbox, () => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return outbox.failedCount;
});

class _ListenableSub {
  _ListenableSub(this._listenable, this._onChange) {
    _listenable.addListener(_onChange);
  }
  final OutboxService _listenable;
  final void Function() _onChange;
  void cancel() => _listenable.removeListener(_onChange);
}

/// Live connection state from the OS network stack. `reconnecting` is the
/// short window right after connectivity returns, while we resync.
final connectionStatusProvider =
    StateNotifierProvider<ConnectionController, ConnectionStatus>((ref) {
      return ConnectionController(ref);
    });

class ConnectionController extends StateNotifier<ConnectionStatus> {
  ConnectionController(this._ref, {bool listenToConnectivity = true})
    : super(ConnectionStatus.online) {
    if (listenToConnectivity) {
      _sub = Connectivity().onConnectivityChanged.listen(_onChange);
    }
  }

  /// Whether a reachability probe is already running, so a burst of
  /// connectivity events cannot start several at once.
  bool _probing = false;

  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _reconnectSettle;

  void _onChange(List<ConnectivityResult> results) {
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (offline) {
      // Verify before telling anybody.
      //
      // connectivity_plus reports which network INTERFACES exist, not whether
      // the internet is reachable, and on the iOS simulator it reports none or
      // an empty list while the app is demonstrably loading feeds, stories and
      // profiles from Supabase. The banner then sat on screen for entire
      // sessions saying "You're offline — drafts are saved" while everything
      // worked, which is worse than useless: it trains people to ignore the
      // one message that should mean something, and on a support platform it
      // says "your words may not have sent" when they did.
      //
      // So a no-interfaces report is now a hint that triggers a real check,
      // not a verdict. Nothing else changes: the reconnect path, the resync
      // and the outbox flush are untouched.
      _reconnectSettle?.cancel();
      _confirmOffline();
      return;
    }
    if (state == ConnectionStatus.offline) {
      // Back online: resync everything realtime might have missed while
      // the socket was down, and drain the outbox.
      if (mounted) state = ConnectionStatus.reconnecting;
      _resync();
      _reconnectSettle?.cancel();
      _reconnectSettle = Timer(const Duration(seconds: 3), () {
        if (mounted && state == ConnectionStatus.reconnecting) {
          state = ConnectionStatus.online;
        }
      });
    } else if (mounted) {
      state = ConnectionStatus.online;
    }
  }

  /// Ask the network directly before declaring the app offline.
  Future<void> _confirmOffline() async {
    if (_probing) return;
    _probing = true;
    try {
      // checkConnectivity is the same plugin, but it answers now rather than
      // replaying a stale event — enough to catch the case where the stream
      // fired once during startup and never corrected itself.
      final now = await Connectivity().checkConnectivity();
      final reallyOffline =
          now.isEmpty || now.every((r) => r == ConnectivityResult.none);
      if (!mounted) return;
      if (!reallyOffline) {
        state = ConnectionStatus.online;
        return;
      }
      state = ConnectionStatus.offline;
    } catch (_) {
      // A failed probe is not evidence of anything. Leaving the status alone
      // is the honest answer, and it keeps a plugin error from producing a
      // banner that contradicts what the person can plainly see working.
    } finally {
      _probing = false;
    }
  }

  void _resync() {
    // Postgres-changes events that fired while offline are gone forever —
    // refetch the streams' sources instead of trusting the socket.
    _ref.invalidate(feedPostsProvider);
    _ref.invalidate(inboxStreamProvider);
    _ref.invalidate(allInboxRoomsStreamProvider);
    _ref.invalidate(notificationsProvider);
    _ref.read(outboxProvider).valueOrNull?.flush();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _reconnectSettle?.cancel();
    super.dispose();
  }
}
