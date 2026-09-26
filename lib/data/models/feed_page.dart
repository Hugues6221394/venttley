import '../../domain/entities/entities.dart';

/// Where the last page stopped, so the next one can carry on from there.
///
/// The ranked feed pages by position inside a candidate pool that is frozen at
/// [anchor]: the server re-ranks the same pool for every page of a session, so
/// position 21 always means the twenty-first post of the feed you started
/// reading, even if somebody posts while you scroll. [createdAt] and [postId]
/// still drive the plain chronological view a signed-out reader gets.
class FeedCursor {
  const FeedCursor({
    required this.createdAt,
    required this.postId,
    this.hotScore,
    this.personalScore,
    this.anchor,
    this.position,
  });

  final DateTime createdAt;
  final String postId;
  final double? hotScore;
  final double? personalScore;
  final DateTime? anchor;
  final int? position;
}

class FeedPage {
  const FeedPage({required this.posts, this.nextCursor});

  final List<Post> posts;
  final FeedCursor? nextCursor;
}
