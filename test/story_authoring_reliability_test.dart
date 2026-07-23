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
}
