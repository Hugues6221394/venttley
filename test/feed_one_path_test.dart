import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';

/// A fake that records what was sent instead of sending it.
class _RecordingRepository extends VentlyRepository {
  // forceMock keeps the constructor away from Supabase.instance, which no
  // unit test has initialised.
  _RecordingRepository() : super(forceMock: true);

  final List<List<String>> batches = <List<String>>[];

  @override
  Future<void> noteFeedImpressions(List<String> postIds) async {
    batches.add(List<String>.from(postIds));
  }
}

void main() {
  group('impressions are batched, not one request per card', () {
    test('a full viewport goes out as one call', () {
      final repo = _RecordingRepository();
      final reporter = FeedImpressionReporter(repo);

      for (var i = 0; i < 25; i++) {
        reporter.saw('post-$i');
      }

      expect(repo.batches, hasLength(1));
      expect(repo.batches.single, hasLength(25));
    });

    test('a post scrolled past twice is reported once', () {
      final repo = _RecordingRepository();
      final reporter = FeedImpressionReporter(repo);

      for (var i = 0; i < 25; i++) {
        reporter.saw('post-$i');
      }
      // The same cards again, as a rebuild would.
      for (var i = 0; i < 25; i++) {
        reporter.saw('post-$i');
      }
      reporter.flush();

      expect(repo.batches, hasLength(1));
    });

    test('leaving the screen does not lose what was on it', () {
      final repo = _RecordingRepository();
      final reporter = FeedImpressionReporter(repo);

      reporter.saw('post-a');
      reporter.saw('post-b');
      expect(repo.batches, isEmpty, reason: 'still waiting on the timer');

      reporter.dispose();

      expect(repo.batches, hasLength(1));
      expect(repo.batches.single, containsAll(<String>['post-a', 'post-b']));
    });

    test('nothing seen means nothing sent', () {
      final repo = _RecordingRepository();
      FeedImpressionReporter(repo).dispose();
      expect(repo.batches, isEmpty);
    });
  });

  test('the feed has one path, and no client reads feed_hot', () {
    // feed_hot is security_invoker over a materialized view that was revoked
    // from authenticated, so every signed-in client asking for the Hot sort
    // got "permission denied for materialized view mv_hot_posts" — the sort
    // pill and the cold-start fallback both. It is gone; Hot is a mode of
    // personal_feed. This fails if anything reaches for the view again.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      if (!text.contains('feed_hot')) continue;
      for (final line in text.split('\n')) {
        final code = line.trim();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        if (code.contains('feed_hot')) {
          offenders.add('${entity.path}: $code');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
