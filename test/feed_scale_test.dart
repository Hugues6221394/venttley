import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/models/feed_page.dart';

void main() {
  test('FeedCursor carries tuple fields for keyset pagination', () {
    final cursor = FeedCursor(
      createdAt: DateTime.utc(2026, 9, 1, 12),
      postId: '72000000-0000-4000-8000-000000000001',
      personalScore: 4.2,
      hotScore: 9.1,
    );

    expect(cursor.postId, '72000000-0000-4000-8000-000000000001');
    expect(cursor.personalScore, 4.2);
    expect(cursor.hotScore, 9.1);
  });

  test('FeedPage exposes next cursor for load-more', () {
    final page = FeedPage(
      posts: const [],
      nextCursor: FeedCursor(
        createdAt: DateTime.utc(2026, 9, 1),
        postId: 'abc',
        personalScore: 1,
      ),
    );

    expect(page.nextCursor?.postId, 'abc');
  });
}
