// Tagging somebody in a chat, on a device, against a real stack.
//
// Asked for: "@ for tagging people on vents, 24 hr stories, comments, in
// spaces, group chats — everywhere a tag can be useful". Vents, stories and
// space posts are all rows in `posts`, so one trigger already covered them.
// Tribe chat and the inbox's group chats had nothing at all.
//
// This drives the two new paths through the real RPCs, and checks the thing
// that matters more than either: that naming somebody is not a way to post
// them sixty characters of a room they are not in.
//
//   flutter test integration_test/mentions_reach_chats_test.dart -d <device> \
//     --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a tag in a group chat reaches the person in the room',
    (tester) async {
      expect(_url.isNotEmpty && _anonKey.isNotEmpty, isTrue);

      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;

      Future<String> signIn(String who) async {
        final res = await client.auth.signInWithPassword(
          email: '$who@id.venttly.app',
          password: 'TestPass123!',
        );
        return res.user!.id;
      }

      // Handles written out rather than looked up: `users` is not readable by
      // a client at all (42501, and rightly), and on this stack the seeded
      // handle is the account name.
      const peerHandle = 'tester_keeper2';
      const outsiderHandle = 'tester_verified';

      final me = await signIn('tester_user');
      final peer = await signIn('tester_keeper2');
      // Signed into as well, so the account exists and its handle resolves;
      // the id itself is only needed for the group it is kept out of.
      await signIn('tester_verified');

      // A group of two: me and the peer. The outsider is deliberately not in it.
      // A group needs a friend to start it with, and these two are friends by
      // the time this runs — the archive test makes them and this one keeps
      // them, or makes them itself.
      await _befriend(client, signIn, me, peer);
      await signIn('tester_user');
      final roomId =
          await client.rpc(
                'create_group_chat',
                params: {'p_title': 'Mentions check', 'p_friend_id': peer},
              )
              as String;
      addTearDown(() async {
        await signIn('tester_user');
        await client.rpc('clear_chat_room', params: {'p_room_id': roomId});
      });

      final before = await _mentionCounts(client, signIn, [
        'tester_keeper2',
        'tester_verified',
      ]);
      await signIn('tester_user');

      await client.rpc(
        'send_chat_message',
        params: {
          'p_room_id': roomId,
          'p_payload': 'are you around @$peerHandle and @$outsiderHandle',
          'p_attached_post_id': null,
        },
      );

      // Give the trigger's notification a moment to land.
      await Future<void>.delayed(const Duration(seconds: 1));
      final after = await _mentionCounts(client, signIn, [
        'tester_keeper2',
        'tester_verified',
      ]);

      expect(
        after['tester_keeper2'],
        before['tester_keeper2']! + 1,
        reason: 'somebody in the group is told they were named',
      );
      expect(
        after['tester_verified'],
        before['tester_verified'],
        reason:
            'and somebody outside it is not — a mention notification carries the '
            'first sixty characters of what was written',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Make the two accounts friends, whatever state an earlier run left.
///
/// `unfriend` only deletes an accepted row, so a pending request outlives a
/// teardown and a second request between the same two people is refused.
Future<void> _befriend(
  SupabaseClient client,
  Future<String> Function(String) signIn,
  String me,
  String peer,
) async {
  await signIn('tester_user');
  final existing = await client
      .from('friendships')
      .select('friendship_id, status')
      .or('user_a.eq.$peer,user_b.eq.$peer');
  if (existing.any((row) => row['status'] == 'accepted')) return;
  for (final row in existing) {
    if (row['status'] == 'pending') {
      await client.rpc(
        'decline_friend_request',
        params: {'p_friendship': row['friendship_id']},
      );
    }
  }
  await client.rpc('send_friend_request', params: {'p_target': peer});
  await signIn('tester_keeper2');
  final inbox = await client
      .from('friend_requests_inbox')
      .select('friendship_id')
      .eq('from_user_id', me);
  await client.rpc(
    'accept_friend_request',
    params: {'p_friendship': inbox.first['friendship_id']},
  );
}

/// How many mention notifications each account can see, asked of each account.
///
/// Not a single query: notifications are RLS'd to their owner, so counting
/// somebody else's from one session returns zero for everybody and the test
/// passes for the wrong reason. Signing in as each of them is the only honest
/// reading, and it is also what proves the row really reached them.
Future<Map<String, int>> _mentionCounts(
  SupabaseClient client,
  Future<String> Function(String) signIn,
  List<String> accounts,
) async {
  final counts = <String, int>{};
  for (final account in accounts) {
    final id = await signIn(account);
    final rows = await client
        .from('notifications')
        .select('notification_id')
        .eq('user_id', id)
        .eq('kind', 'mention');
    counts[account] = rows.length;
  }
  return counts;
}
