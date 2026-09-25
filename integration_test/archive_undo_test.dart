// Archiving a chat, on a device, and watching the bar afterwards.
//
// Reported from the phone: archive a conversation and "Archived. Undo" never
// goes away. It sits over the inbox, over the next screen, over everything,
// and the only exit it offers is undoing the thing you just chose to do.
//
// The cause is a default. SnackBar sets `persist = persist ?? action != null`,
// so any bar carrying a SnackBarAction stays until the action or a close icon
// is tapped. The dismissal timer does fire — it reads `persist` and returns
// without hiding, which is why every reading of the timer code looked correct.
//
// A widget test can prove the default (test/snack_bars_leave_test.dart does).
// This proves the fix where it was reported: the real inbox, a real archive
// through the real RPC, and a bar that leaves by itself.
//
//   flutter test integration_test/archive_undo_test.dart -d <device> \
//     --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/screens/inbox/inbox_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the archive bar leaves on its own',
    (tester) async {
      expect(
        _url.isNotEmpty && _anonKey.isNotEmpty,
        isTrue,
        reason: 'pass --dart-define=SUPABASE_URL and SUPABASE_ANON_KEY',
      );

      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;

      // This test brings its own conversation.
      //
      // The first run of it died looking for a row to swipe, because no seeded
      // account has a DM — chat_room_members was empty on a freshly reset
      // stack. A test that depends on somebody else's leftovers reports the
      // state of the database, not the state of the code, so this one makes a
      // friendship and a thread, uses them, and takes them away again.
      Future<String> signIn(String who) async {
        final res = await client.auth.signInWithPassword(
          email: '$who@id.venttly.app',
          password: 'TestPass123!',
        );
        return res.user!.id;
      }

      final me = await signIn('tester_user');
      final peer = await signIn('tester_keeper2');

      // Accepted from the other side, so the friendship is real rather than
      // written past the RPCs that guard it.
      await signIn('tester_user');
      await client.rpc('send_friend_request', params: {'p_target': peer});
      await signIn('tester_keeper2');
      final inbox = await client
          .from('friend_requests_inbox')
          .select('friendship_id, from_user_id')
          .eq('from_user_id', me);
      expect(inbox, isNotEmpty, reason: 'the request should be waiting');
      await client.rpc(
        'accept_friend_request',
        params: {'p_friendship': inbox.first['friendship_id']},
      );

      await signIn('tester_user');
      final rooms =
          await client.rpc(
                'start_chat_room',
                params: {
                  'p_target': peer,
                  'p_preview': 'A thread for the archive test.',
                  'p_origin_post_id': null,
                },
              )
              as List;
      expect(rooms, isNotEmpty, reason: 'the test needs a thread to archive');

      addTearDown(() async {
        await signIn('tester_user');
        final archived = await client
            .from('dm_room_prefs')
            .select('room_id')
            .eq('user_id', me)
            .not('archived_at', 'is', null);
        for (final row in archived) {
          await client.rpc(
            'set_chat_room_archived',
            params: {'p_room_id': row['room_id'], 'p_archived': false},
          );
        }
        // And the friendship this run invented.
        await client.rpc('unfriend', params: {'p_target': peer});
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).restore();
      expect(
        container.read(sessionProvider),
        isNotNull,
        reason: 'the session must be restored or the inbox renders signed-out',
      );

      final router = GoRouter(
        initialLocation: '/inbox',
        routes: [
          GoRoute(path: '/inbox', builder: (_, __) => const InboxScreen()),
          GoRoute(
            path: '/chat/:id',
            builder: (_, __) => const Scaffold(body: Text('thread')),
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

      // Let the inbox arrive.
      for (
        var i = 0;
        i < 60 && find.byType(Dismissible).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        find.byType(Dismissible),
        findsWidgets,
        reason: 'tester_user needs at least one conversation to archive',
      );

      // Swipe right, which is archive.
      await tester.drag(find.byType(Dismissible).first, const Offset(600, 0));
      for (
        var i = 0;
        i < 40 && find.text('Archived.').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        find.text('Archived.'),
        findsOneWidget,
        reason: 'archiving should say so, and offer the way back',
      );
      expect(find.text('Undo'), findsOneWidget);

      // The reported bug, at the place it was reported. Six seconds of display
      // plus the exit animation; ten is generous and still nothing like forever.
      for (
        var i = 0;
        i < 40 && find.text('Archived.').evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        find.text('Archived.'),
        findsNothing,
        reason: 'the bar must leave without being tapped — this is the bug',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
