import '../../domain/entities/entities.dart';

/// Keyset cursor for feed pagination. Tuple order matches the active sort:
/// - foryou: (personalScore, createdAt, postId)
/// - hot: (hotScore, createdAt, postId)
/// - fresh: (createdAt, postId)
class FeedCursor {
  const FeedCursor({
    required this.createdAt,
    required this.postId,
    this.hotScore,
    this.personalScore,
  });

  final DateTime createdAt;
  final String postId;
  final double? hotScore;
  final double? personalScore;
}

class FeedPage {
  const FeedPage({required this.posts, this.nextCursor});

  final List<Post> posts;
  final FeedCursor? nextCursor;
}
