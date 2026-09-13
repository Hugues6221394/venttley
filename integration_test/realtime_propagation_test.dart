// Realtime propagation, on a real device, against a real Supabase stack.
//
// Every other test in this repository stops at the database or at a mocked
// backend. This one covers the hop nothing else does: a row changes, and the
// websocket delivers it to a signed-in client on an iOS simulator. That is the
// path the feed, the inbox badge and the notification bell all depend on, and
// until now the only evidence it worked was that the app appeared to work.
//
// Deliberately NOT mock mode. It needs the live local stack:
//
//   supabase start
//   psql "$DB" -f supabase/seed/test_accounts.sql
//   flutter test integration_test/realtime_propagation_test.dart -d <simulator-id> \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>
//
// The insert is made by a SECOND client signed in as a different person, so
// what is proven is genuinely "someone else's change reached me" rather than
// "my own write echoed back", which would pass even with realtime switched off.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a Vent created by another account arrives over realtime', (
    tester,
  ) async {
    expect(
      _url.isNotEmpty && _anonKey.isNotEmpty,
      isTrue,
      reason:
          'Pass --dart-define=SUPABASE_URL and --dart-define=SUPABASE_ANON_KEY. '
          'This test talks to a real stack on purpose; silently falling back to '
          'a default would test a different database than the one being changed.',
    );

    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    final listener = Supabase.instance.client;

    await listener.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );
    expect(listener.auth.currentUser, isNotNull, reason: 'listener signed in');

    // A separate client for the author, so the change genuinely originates
    // somewhere else rather than echoing back down the same connection.
    final author = SupabaseClient(_url, _anonKey);
    addTearDown(() async => author.dispose());
    await author.auth.signInWithPassword(
      email: 'tester_keeper2@id.venttly.app',
      password: 'TestPass123!',
    );
    expect(author.auth.currentUser, isNotNull, reason: 'author signed in');

    // Letters only. A UUID's digit runs read as a phone number to
    // private.server_text_safety, which refuses the write with
    // content_blocked_privacy — correctly, and nothing to do with realtime.
    final suffix = const Uuid().v4().replaceAll(RegExp('[^a-z]'), '');
    final marker = 'realtime probe ${suffix.substring(0, 10)}';
    final delivered = Completer<Map<String, dynamic>>();

    final channel = listener.channel('integration:posts')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'posts',
        callback: (payload) {
          final row = payload.newRecord;
          if (row['content'] == marker && !delivered.isCompleted) {
            delivered.complete(row);
          }
        },
      );

    final subscribed = Completer<void>();
    channel.subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.subscribed &&
          !subscribed.isCompleted) {
        subscribed.complete();
      } else if (error != null && !subscribed.isCompleted) {
        subscribed.completeError(error);
      }
    });
    addTearDown(() async => listener.removeChannel(channel));

    await subscribed.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException(
        'the realtime channel never reached SUBSCRIBED — is the realtime '
        'container running? `docker ps | grep realtime`',
      ),
    );

    // Give the subscription a moment to be live server-side before the write,
    // otherwise a fast insert can land before the listener is registered and
    // the test fails for a reason that has nothing to do with the product.
    await Future<void>.delayed(const Duration(seconds: 2));

    await author.rpc(
      'create_post_idempotent_v4',
      params: {
        'p_mutation_id': const Uuid().v4(),
        'p_content': marker,
        'p_category_name': 'vent_zone',
        'p_post_mood': 'angry',
      },
    );

    final row = await delivered.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw TimeoutException(
        'the insert never arrived over realtime. The row was created — check '
        'that `posts` is in the supabase_realtime publication and that RLS '
        'lets this account read it.',
      ),
    );

    expect(row['content'], marker);
    expect(
      row['author_id'],
      author.auth.currentUser!.id,
      reason: 'the payload carries the real author, not the listener',
    );

    // Clean up so repeated runs do not accumulate probe Vents. Through the
    // RPC, because `authenticated` has no DELETE on posts — deletion is an
    // authored action with its own rules, not a row removal.
    await author.rpc(
      'delete_post',
      params: {'p_post_id': row['post_id']},
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
