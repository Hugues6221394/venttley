// The notification centre, opened cold, on a device.
//
// Reported from the phone: open Notifications and it says "All quiet for now",
// pull to refresh and everything is there. An empty state that is wrong is
// worse than a spinner — it tells somebody nobody has replied to them.
//
//   flutter test integration_test/notifications_arrive_test.dart -d <device> \
//     --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/screens/notifications/notifications_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Put the two accounts back to strangers.
///
/// `unfriend` only deletes an accepted row, so a pending request outlives every
/// teardown — and a second request between the same two people is refused,
/// which is how this test passed once and failed on every run afterwards.
/// `decline_friend_request` deletes a pending row from either side.
Future<void> clearFriendship(SupabaseClient client, String other) async {
  await client.rpc('unfriend', params: {'p_target': other});
  final rows = await client
      .from('friendships')
      .select('friendship_id, status')
      .or('user_a.eq.$other,user_b.eq.$other');
  for (final row in rows) {
    if (row['status'] == 'pending') {
      await client.rpc(
        'decline_friend_request',
        params: {'p_friendship': row['friendship_id']},
      );
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'what is waiting is on screen without being asked twice',
    (tester) async {
      expect(_url.isNotEmpty && _anonKey.isNotEmpty, isTrue);

      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;
      await client.auth.signInWithPassword(
        email: 'tester_user@id.venttly.app',
        password: 'TestPass123!',
      );
      final uid = client.auth.currentUser!.id;

      final waiting = await client
          .from('notifications')
          .select('notification_id')
          .eq('user_id', uid);
      expect(
        waiting,
        isNotEmpty,
        reason:
            'tester_user needs at least one notification for this to mean '
            'anything — seed one before running',
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).restore();

      final router = GoRouter(
        initialLocation: '/notifications',
        routes: [
          GoRoute(
            path: '/notifications',
            builder: (_, __) => const NotificationsScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: VentlyTheme.light(),
            routerConfig: router,
          ),
        ),
      );

      // Ten seconds of ordinary waiting — no pull, no tap, nothing a person
      // should have to do to see what is already theirs.
      var settled = false;
      for (var i = 0; i < 40 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        settled = container.read(notificationsProvider).hasValue;
      }

      expect(
        container.read(notificationsProvider).valueOrNull,
        isNotEmpty,
        reason: 'the stream must deliver the list on its first emission',
      );
      expect(
        find.text('All quiet for now'),
        findsNothing,
        reason: 'this is the reported bug: an empty state over a full inbox',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'and arrives when the session does, not only when asked again',
    (tester) async {
      // The order the app actually starts in.
      //
      // The bell badge on the feed watches this provider, so it is subscribed
      // during the first frame — which on a cold start can be before the session
      // has been restored. The stream then had no user to read as and no channel
      // to subscribe to, and nothing retried either. This test signs out first
      // so that ordering is guaranteed rather than hoped for.
      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;
      await client.auth.signOut();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Subscribed while signed out. This is the whole point.
      final sub = container.listen(notificationsProvider, (_, __) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        container.read(notificationsProvider).valueOrNull ?? const [],
        isEmpty,
        reason: 'nothing is owed to nobody',
      );

      await client.auth.signInWithPassword(
        email: 'tester_user@id.venttly.app',
        password: 'TestPass123!',
      );
      await container.read(sessionProvider.notifier).restore();

      var items = const <dynamic>[];
      for (var i = 0; i < 40 && items.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        items = container.read(notificationsProvider).valueOrNull ?? const [];
      }

      expect(
        items,
        isNotEmpty,
        reason:
            'signing in must bring the list with it — this is the bug: the '
            'stream was bound to whoever was signed in when it was created, and '
            'only a manual refresh ever rebuilt it',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'and a new one lands without anybody refreshing',
    (tester) async {
      // "In real time" is the other half of the report, and it is a different
      // mechanism from the first: the postgres_changes channel on notifications,
      // filtered to this user. This drives it from a second account over the
      // network — a friend request from somebody else — and waits for the row to
      // arrive on its own.
      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;
      await client.auth.signInWithPassword(
        email: 'tester_user@id.venttly.app',
        password: 'TestPass123!',
      );
      final me = client.auth.currentUser!.id;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).restore();

      final sub = container.listen(notificationsProvider, (_, __) {});
      addTearDown(sub.close);

      var before = const <dynamic>[];
      for (var i = 0; i < 40 && before.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        before = container.read(notificationsProvider).valueOrNull ?? const [];
      }
      expect(before, isNotEmpty, reason: 'the list should have loaded by now');

      // A second client, so the first one is genuinely told rather than told by
      // itself.
      final other = SupabaseClient(_url, _anonKey);
      addTearDown(() async {
        await clearFriendship(other, me);
        await other.dispose();
      });
      await other.auth.signInWithPassword(
        email: 'tester_keeper2@id.venttly.app',
        password: 'TestPass123!',
      );
      // Whatever an earlier run left behind: a repeated request between the
      // same two people is refused, and this needs a genuinely new row.
      await clearFriendship(other, me);
      await other.rpc(
        'send_friend_request',
        params: {'p_target': me, 'p_note': 'realtime check'},
      );

      var after = before;
      for (var i = 0; i < 60 && after.length <= before.length; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        after = container.read(notificationsProvider).valueOrNull ?? const [];
      }

      expect(
        after.length,
        greaterThan(before.length),
        reason:
            'a notification must arrive on its own, with no pull to refresh',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
