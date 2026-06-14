import '../entities/entities.dart';

class HomeDiscovery {
  final List<HomeKpi> kpis;
  final List<TrendingTopic> trendingTopics;
  final List<Tribe> trendingTribes;
  final List<VentStory> activeStories;

  const HomeDiscovery({
    required this.kpis,
    required this.trendingTopics,
    required this.trendingTribes,
    required this.activeStories,
  });

  factory HomeDiscovery.from({
    required List<Post> posts,
    required List<Tribe> tribes,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final livePosts = posts
        .where((p) => !p.isWhisper || p.createdAt.add(const Duration(hours: 24)).isAfter(clock))
        .toList();
    final stories = livePosts
        .where((p) => p.isWhisper)
        .map((p) => VentStory.fromPost(p, now: clock))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final topicScores = <String, _TopicAccumulator>{};
    for (final p in livePosts.where((p) => !p.isWhisper)) {
      final acc = topicScores.putIfAbsent(
        p.categoryName,
        () => _TopicAccumulator(p.categoryName),
      );
      acc.count += 1;
      acc.score += _postTrendScore(p, clock);
      acc.reactions += p.likesCount;
      acc.comments += p.commentsCount;
    }
    final topics = topicScores.values
        .map((a) => TrendingTopic(
              category: a.category,
              postCount: a.count,
              reactionCount: a.reactions,
              commentCount: a.comments,
              score: a.score,
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final rankedTribes = tribes.toList()
      ..sort((a, b) {
        final joinedBoost = (b.joinedByMe ? 500 : 0) - (a.joinedByMe ? 500 : 0);
        if (joinedBoost != 0) return joinedBoost;
        return b.memberCount.compareTo(a.memberCount);
      });

    final comments = livePosts.fold<int>(0, (sum, p) => sum + p.commentsCount);
    final reactions = livePosts.fold<int>(0, (sum, p) => sum + p.likesCount);
    return HomeDiscovery(
      kpis: [
        HomeKpi(label: 'Live posts', value: _compact(livePosts.length), icon: 'bolt'),
        HomeKpi(label: 'Stories', value: _compact(stories.length), icon: 'story'),
        HomeKpi(label: 'Replies', value: _compact(comments), icon: 'chat'),
        HomeKpi(label: 'Reactions', value: _compact(reactions), icon: 'spark'),
      ],
      trendingTopics: topics.take(8).toList(),
      trendingTribes: rankedTribes.take(8).toList(),
      activeStories: stories.take(12).toList(),
    );
  }

  static double _postTrendScore(Post p, DateTime now) {
    final ageHours = now.difference(p.createdAt).inMinutes / 60.0;
    final engagement = 1 + p.likesCount + (p.commentsCount * 1.6);
    return engagement / ((ageHours + 2) * 0.55);
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
    return '$n';
  }
}

class HomeKpi {
  final String label;
  final String value;
  final String icon;

  const HomeKpi({
    required this.label,
    required this.value,
    required this.icon,
  });
}

class TrendingTopic {
  final String category;
  final int postCount;
  final int reactionCount;
  final int commentCount;
  final double score;

  const TrendingTopic({
    required this.category,
    required this.postCount,
    required this.reactionCount,
    required this.commentCount,
    required this.score,
  });
}

class VentStory {
  final String postId;
  final String? authorId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String? authorProfilePhotoUrl;
  final String content;
  final String category;
  final String mood;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int reactionsCount;
  final int repliesCount;
  final String? myReaction;

  const VentStory({
    required this.postId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.content,
    required this.category,
    required this.mood,
    required this.createdAt,
    required this.expiresAt,
    required this.reactionsCount,
    required this.repliesCount,
    this.authorId,
    this.authorProfilePhotoUrl,
    this.myReaction,
  });

  factory VentStory.fromPost(Post post, {DateTime? now}) {
    return VentStory(
      postId: post.postId,
      authorId: post.authorId,
      authorPseudonym: post.authorPseudonym,
      authorAvatarSeed: post.authorAvatarSeed,
      authorProfilePhotoUrl: post.authorProfilePhotoUrl,
      content: post.content,
      category: post.categoryName,
      mood: post.postMood,
      createdAt: post.createdAt,
      expiresAt: post.createdAt.add(const Duration(hours: 24)),
      reactionsCount: post.likesCount,
      repliesCount: post.commentsCount,
      myReaction: post.myReaction,
    );
  }

  Duration remaining({DateTime? now}) {
    final left = expiresAt.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

class _TopicAccumulator {
  _TopicAccumulator(this.category);
  final String category;
  int count = 0;
  int reactions = 0;
  int comments = 0;
  double score = 0;
}
