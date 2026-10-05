import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// Posting behind a persona must not say who you are.
///
/// Two defects this locks shut. A persona post used to print the author's REAL
/// handle to every reader — personas carry one owner-only RLS policy, so the
/// display-name COALESCE fell through for everybody else and landed on the
/// account. And posts.author_id was readable straight off the table, so the
/// account's own posts and its persona's posts shared a join key.
/// Any fixed instant; none of these assertions depend on it.
final _epoch = DateTime.utc(2026, 1, 1);

void main() {
  String read(String path) => File(path).readAsStringSync();

  final migration = read(
    'supabase/migrations/20261077090000_a_persona_is_a_different_person.sql',
  );

  group('the database', () {
    test('the readable author is the voice, not the account', () {
      expect(migration, contains('feed_author_key'));
      expect(migration, contains('p.feed_author_key AS author_id'));
      expect(migration, contains('COALESCE(persona_id, author_id)'));
    });

    test('a persona post cannot be joined to an account', () {
      // display_author_id is NULL for persona posts, so the users join finds
      // nothing to fall through to.
      expect(
        migration,
        contains('CASE WHEN persona_id IS NULL THEN author_id END'),
      );
      expect(migration, contains('u.user_id = p.display_author_id'));
    });

    test('the raw column is revoked, not merely unselected', () {
      // Masking the view alone is theatre: PostgREST serves the table too. And
      // a column-level REVOKE does nothing while a table-wide grant stands,
      // which is why the grant is replaced by a column list.
      expect(migration, contains('REVOKE SELECT ON public.posts'));
      expect(migration, contains("column_name <> 'author_id'"));
    });

    test('the view stays security_invoker', () {
      // CREATE OR REPLACE VIEW silently resets reloptions. The last time that
      // was forgotten, row level security came off for eight readers.
      expect(migration, contains('WITH (security_invoker = true)'));
    });

    test('a persona carries no tick and no karma', () {
      // Both narrow the author: a tick to the handful of verified accounts, a
      // karma score to a near-unique number.
      expect(migration, contains('ELSE FALSE END AS author_is_verified'));
      expect(migration, contains('ELSE 0 END AS author_karma'));
    });

    test('the persona card hands over display fields and nothing else', () {
      final start = migration.indexOf('FUNCTION private.persona_card');
      final body = migration.substring(start, start + 500);
      expect(body, contains('pseudonym'));
      expect(body, contains('avatar_seed'));
      expect(
        body.contains('user_id'),
        isFalse,
        reason: 'the card must not carry the link it exists to hide',
      );
    });

    test('muting a persona mutes the persona', () {
      // post_not_interested is a row the muter owns and can read back, so
      // storing the account there was another way to unmask one.
      expect(migration, contains('mark_not_interested'));
      expect(migration, contains('IF v_mine THEN'));
    });
  });

  group('the client', () {
    test('a persona post is not a link to a profile', () {
      final persona = Post(
        postId: 'p1',
        authorId: 'persona-uuid',
        personaId: 'persona-uuid',
        authorPseudonym: '@quietcorner',
        authorAvatarSeed: 's',
        categoryName: 'vent_zone',
        postType: 'user_post',
        content: 'x',
        postMood: 'hopeful',
        isWhisper: false,
        isStory: false,
        storyAudience: 'everyone',
        likesCount: 0,
        commentsCount: 0,
        createdAt: _epoch,
      );
      expect(persona.opensUserProfile, isFalse);
    });

    test('an ordinary post still opens one', () {
      final mine = Post(
        postId: 'p2',
        authorId: 'account-uuid',
        authorPseudonym: '@someone',
        authorAvatarSeed: 's',
        categoryName: 'vent_zone',
        postType: 'user_post',
        content: 'x',
        postMood: 'hopeful',
        isWhisper: false,
        isStory: false,
        storyAudience: 'everyone',
        likesCount: 0,
        commentsCount: 0,
        createdAt: _epoch,
      );
      expect(mine.opensUserProfile, isTrue);
    });

    test('ownership comes from the server, not from comparing ids', () {
      // On a post behind my own persona the author id is the persona's, so
      // comparing it to my account id says "not mine" on my own post.
      final behindMyPersona = Post(
        postId: 'p3',
        authorId: 'persona-uuid',
        personaId: 'persona-uuid',
        isMine: true,
        authorPseudonym: '@quietcorner',
        authorAvatarSeed: 's',
        categoryName: 'vent_zone',
        postType: 'user_post',
        content: 'x',
        postMood: 'hopeful',
        isWhisper: false,
        isStory: false,
        storyAudience: 'everyone',
        likesCount: 0,
        commentsCount: 0,
        createdAt: _epoch,
      );
      expect(behindMyPersona.ownedBy('my-account-uuid'), isTrue);
      expect(behindMyPersona.opensUserProfile, isFalse);
    });

    test('the parser reads is_mine, and defaults it to false', () {
      final backend = read('lib/data/services/supabase_backend.dart');
      expect(backend, contains("isMine: (r['is_mine'] as bool?) ?? false"));
    });
  });
}
