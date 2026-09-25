// The comment sheet on a whisper, on a device, against a real stack.
//
// Two reports in one:
//
//   "its showing data that are not there, ex: 3 comments and when you open the
//    comment section you find there is no comment at all"
//   "ensure in comment section people can share GIFs, emojis, you can like or
//    reply"
//
// The count was kept by hand from two of the four events that change it, so a
// hard delete left it high and anything that wrote the column was believed.
// It is recomputed now. GIFs needed a column and a picker.
//
//   flutter test integration_test/whisper_comments_test.dart -d <device> \
//     --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the number on a whisper is the number of comments',
    (tester) async {
      expect(_url.isNotEmpty && _anonKey.isNotEmpty, isTrue);

      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;
      await client.auth.signInWithPassword(
        email: 'tester_user@id.venttly.app',
        password: 'TestPass123!',
      );

      final whispers = await client
          .from('whispers')
          .select('whisper_id, comments_count')
          .isFilter('deleted_at', null)
          .limit(20);
      expect(whispers, isNotEmpty, reason: 'seed at least one whisper');

      // Every whisper on the stack, not only the one this test writes to: the
      // report was about a whisper nobody had commented on at all.
      for (final whisper in whispers) {
        final rows = await client
            .from('whisper_comments')
            .select('comment_id')
            .eq('whisper_id', whisper['whisper_id'])
            .isFilter('deleted_at', null);
        expect(
          whisper['comments_count'],
          rows.length,
          reason:
              'whisper ${whisper['whisper_id']} says ${whisper['comments_count']} '
              'and has ${rows.length}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'a GIF is a comment, and the count follows it',
    (tester) async {
      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      final client = Supabase.instance.client;
      await client.auth.signInWithPassword(
        email: 'tester_user@id.venttly.app',
        password: 'TestPass123!',
      );

      final whisper =
          (await client
                  .from('whispers')
                  .select('whisper_id, comments_count')
                  .isFilter('deleted_at', null)
                  .limit(1))
              .first;
      final whisperId = whisper['whisper_id'] as String;
      final before = whisper['comments_count'] as int;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).restore();
      final repo = container.read(repositoryProvider);

      // A GIF with nothing written beside it, which is how most people answer.
      const gif = 'https://media.tenor.com/venttly-integration-test.gif';
      final commentId = await repo.addWhisperComment(
        whisperId,
        '',
        imageUrl: gif,
      );
      addTearDown(() async {
        await client.rpc(
          'delete_whisper_comment',
          params: {'p_comment_id': commentId},
        );
      });

      final listed = await repo.listWhisperComments(whisperId);
      final mine = listed.where((c) => c.commentId == commentId);
      expect(mine, hasLength(1), reason: 'the comment must come back');
      expect(
        mine.first.imageUrl,
        gif,
        reason: 'and carry its GIF, or the sheet has nothing to draw',
      );
      expect(mine.first.content, isEmpty);

      final after =
          (await client
                  .from('whispers')
                  .select('comments_count')
                  .eq('whisper_id', whisperId)
                  .single())['comments_count']
              as int;
      expect(after, before + 1, reason: 'a GIF counts as a comment');

      // And the count comes back down when it goes away — the half the old
      // counter never did.
      await client.rpc(
        'delete_whisper_comment',
        params: {'p_comment_id': commentId},
      );
      final afterDelete =
          (await client
                  .from('whispers')
                  .select('comments_count')
                  .eq('whisper_id', whisperId)
                  .single())['comments_count']
              as int;
      expect(afterDelete, before, reason: 'and stops counting when deleted');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
