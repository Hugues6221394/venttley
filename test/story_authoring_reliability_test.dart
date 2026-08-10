import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text-only Stories cannot upload stale image bytes', () {
    final source = File(
      'lib/presentation/screens/compose/create_story_screen.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        '_mode == _StoryMode.photo && _imageBytes != null',
      ),
    );
    expect(source, contains('if (_shouldUploadImage)'));
    expect(source, contains('if (!_shouldUploadImage || stagedMedia != null)'));
    expect(source, contains('_mode = _StoryMode.text;'));
    expect(source, contains('_imageBytes = null;'));
  });

  test('Story owners can delete and physical post media is cleaned up', () {
    final viewer = File(
      'lib/presentation/screens/feed/story_viewer_screen.dart',
    ).readAsStringSync();
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260722010000_post_media_owner_cleanup.sql',
    ).readAsStringSync();

    expect(viewer, contains("story.authorId == authenticatedUserId"));
    expect(viewer, contains(".deletePost(story.postId)"));
    expect(viewer, contains('Delete story'));
    expect(backend, contains(".select('image_path')"));
    expect(backend, contains(".from('post-media').remove([imagePath])"));
    expect(migration, contains('"post media owner read"'));
    expect(migration, contains('owner = (SELECT auth.uid())'));
  });

  test('Story reply privacy is persisted and enforced by an atomic RPC', () {
    final migration = File(
      'supabase/migrations/'
      '20260727165500_story_reply_privacy_and_activity.sql',
    ).readAsStringSync();
    final settings = File(
      'lib/presentation/screens/settings/settings_screen.dart',
    ).readAsStringSync();
    final repository = File(
      'lib/data/repositories/vently_repository.dart',
    ).readAsStringSync();

    expect(migration, contains('story_replies_enabled BOOLEAN'));
    expect(migration, contains('public.can_reply_to_story'));
    expect(migration, contains('public.reply_to_story'));
    expect(migration, contains('story replies are disabled'));
    expect(migration, contains('public.send_chat_message'));
    expect(settings, contains("'Story replies'"));
    expect(repository, contains('live.replyToStory('));
  });

  test('Story owners can see real reaction totals and reactor profiles', () {
    final migration = File(
      'supabase/migrations/'
      '20260727165500_story_reply_privacy_and_activity.sql',
    ).readAsStringSync();
    final viewer = File(
      'lib/presentation/screens/feed/story_viewer_screen.dart',
    ).readAsStringSync();

    expect(migration, contains('story_reactions_for_owner'));
    expect(migration, contains('p.author_id = v_me'));
    expect(viewer, contains("'Story activity'"));
    expect(viewer, contains('storyReactionsProvider'));
    expect(viewer, contains('UserProfileLink('));
    expect(viewer, contains('reactionCount'));
  });

  test('distinct Story activity RPCs authorize is_story rows', () {
    final migration = File(
      'supabase/migrations/'
      '20260727225500_restore_distinct_story_activity_contract.sql',
    ).readAsStringSync();

    expect(migration, contains('p.is_story = TRUE'));
    expect(migration, isNot(contains('p.is_whisper = TRUE')));
    expect(migration, contains('can_reply_to_story'));
    expect(migration, contains('reply_to_story'));
    expect(migration, contains('story_reactions_for_owner'));
  });

  test('Stories have a distinct server type and enforced audience', () {
    final migration = File(
      'supabase/migrations/'
      '20260727184849_distinct_stories_and_audience.sql',
    ).readAsStringSync();
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();
    final composer = File(
      'lib/presentation/screens/compose/create_story_screen.dart',
    ).readAsStringSync();
    final profile = File(
      'lib/presentation/screens/profile/profile_screen.dart',
    ).readAsStringSync();

    expect(migration, contains('is_story BOOLEAN NOT NULL DEFAULT FALSE'));
    expect(migration, contains("story_audience IN ('everyone', 'friends')"));
    expect(migration, contains('CREATE POLICY "posts readable"'));
    expect(migration, contains("story_audience = 'everyone'"));
    expect(migration, contains("f.status = 'accepted'"));
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.create_post_idempotent_v2'),
      reason: 'Installed clients need a safe rolling-upgrade adapter.',
    );
    expect(backend, contains("'create_post_idempotent_v3'"));
    expect(backend, contains("'p_is_story': isStory"));
    expect(composer, contains('isStory: true'));
    expect(
      composer,
      contains("storyAudience: _friendsOnly ? 'friends' : 'everyone'"),
    );
    expect(profile, contains('post.isStory'));
    expect(profile, contains('!post.isWhisper && !post.isStory'));
    expect(
      profile,
      isNot(contains('myVents.where((p) => p.isWhisper).toList()')),
    );
  });

  test('profile Stories use a dedicated active Story provider', () {
    final providers = File('lib/core/providers.dart').readAsStringSync();
    final backend =
        File('lib/data/services/supabase_backend.dart').readAsStringSync();
    final profile = File('lib/presentation/screens/profile/profile_screen.dart')
        .readAsStringSync();
    final expiry = File(
      'supabase/migrations/'
      '20260728171259_enforce_story_expiry_at_database_boundary.sql',
    ).readAsStringSync();

    expect(providers, contains('final myStoriesProvider'));
    expect(providers, contains('.activeStoriesByAuthor(me.userId, limit: 48)'));
    expect(backend, contains('Future<List<Post>> activeStoriesByAuthor('));
    expect(backend, contains(".eq('is_story', true)"));
    expect(backend, contains(".gte('created_at'"));
    expect(profile, contains('ref.watch(myStoriesProvider)'));
    // No leading `const`: the tab list is a `const <_ProfileTab>[...]`
    // literal, so the elements do not repeat the keyword.
    expect(profile, contains("_ProfileTab('Stories', null)"));
    expect(profile, contains("Couldn't load your stories."));
    expect(profile, contains('ref.invalidate(myStoriesProvider)'));
    expect(expiry, contains('AS RESTRICTIVE'));
    expect(expiry, contains("created_at > now() - INTERVAL '24 hours'"));
  });
}
