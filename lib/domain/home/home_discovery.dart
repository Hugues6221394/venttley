import 'dart:math' as math;

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
        .where(
          (p) =>
              (!p.isStory && !p.isWhisper) ||
              p.createdAt.add(const Duration(hours: 24)).isAfter(clock),
        )
        .toList();
    final stories =
        livePosts
            .where((p) => p.isStory)
            .map((p) => VentStory.fromPost(p, now: clock))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final topics = topicStatsFromPosts(livePosts, now: clock);

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
        HomeKpi(
          label: 'Live posts',
          value: _compact(livePosts.length),
          icon: 'bolt',
        ),
        HomeKpi(
          label: 'Stories',
          value: _compact(stories.length),
          icon: 'story',
        ),
        HomeKpi(label: 'Replies', value: _compact(comments), icon: 'chat'),
        HomeKpi(label: 'Reactions', value: _compact(reactions), icon: 'spark'),
      ],
      trendingTopics: topics.take(8).toList(),
      trendingTribes: rankedTribes.take(8).toList(),
      activeStories: stories.take(12).toList(),
    );
  }

  /// Exact local/mock equivalent of the `trending_topic_stats` RPC.
  ///
  /// Production totals come from the server because a paginated feed cannot
  /// represent a category's complete post and reply counts.
  static List<TrendingTopic> topicStatsFromPosts(
    List<Post> posts, {
    DateTime? now,
    int limit = 8,
  }) {
    final clock = now ?? DateTime.now();
    final activeCutoff = clock.subtract(const Duration(days: 30));
    final topicScores = <String, _TopicAccumulator>{};
    for (final post in posts.where(
      (post) => !post.isStory && !post.isWhisper,
    )) {
      final category = post.categoryName.trim();
      if (category.isEmpty) continue;
      final accumulator = topicScores.putIfAbsent(
        category,
        () => _TopicAccumulator(category),
      );
      accumulator.count += 1;
      accumulator.reactions += post.likesCount;
      accumulator.comments += post.commentsCount;
      if (!post.createdAt.isBefore(activeCutoff)) {
        accumulator.hasRecentPost = true;
        accumulator.score += _postTrendScore(post, clock);
      }
    }
    final topics =
        topicScores.values
            .where((accumulator) => accumulator.hasRecentPost)
            .map(
              (accumulator) => TrendingTopic(
                category: accumulator.category,
                postCount: accumulator.count,
                reactionCount: accumulator.reactions,
                commentCount: accumulator.comments,
                score: accumulator.score,
              ),
            )
            .toList()
          ..sort((a, b) {
            final score = b.score.compareTo(a.score);
            if (score != 0) return score;
            final replies = b.commentCount.compareTo(a.commentCount);
            if (replies != 0) return replies;
            return b.postCount.compareTo(a.postCount);
          });
    return topics.take(limit.clamp(1, 20)).toList(growable: false);
  }

  static double _postTrendScore(Post p, DateTime now) {
    final ageHours = now.difference(p.createdAt).inMinutes / 60.0;
    final engagement = 1 + p.likesCount + (p.commentsCount * 1.6);
    return engagement / math.pow(math.max(ageHours + 2, 2), 0.55);
  }

  static String _compact(int n) {
    if (n >= 1000000) {
      return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
    }
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
    return '$n';
  }

  /// 24h stories from self + accepted friends only (no demo content).
  static List<VentStory> friendStories({
    required List<Post> posts,
    required String? myUserId,
    required Set<String> friendUserIds,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    return posts
        .where(
          (p) =>
              p.isStory &&
              p.createdAt.add(const Duration(hours: 24)).isAfter(clock),
        )
        .where((p) {
          if (p.authorId == null) return false;
          if (p.authorId == myUserId) return true;
          return friendUserIds.contains(p.authorId);
        })
        .map((p) => VentStory.fromPost(p, now: clock))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
}

class HomeKpi {
  final String label;
  final String value;
  final String icon;

  const HomeKpi({required this.label, required this.value, required this.icon});
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
  final String authorDisplayName;
  final String authorAvatarSeed;
  final String? authorProfilePhotoUrl;
  final String content;
  final String category;
  final String mood;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int reactionsCount;
  final int repliesCount;
  final int viewCount;
  final String? imageUrl;
  final String? audioUrl;
  final int? audioDurationSeconds;
  final bool authorIsVerified;
  final String? myReaction;
  final MusicTrack? musicTrack;
  final int? musicStartMs;
  final int? musicDurationMs;
  final double? musicVolume;

  const VentStory({
    required this.postId,
    required this.authorPseudonym,
    required this.authorDisplayName,
    required this.authorAvatarSeed,
    required this.content,
    required this.category,
    required this.mood,
    required this.createdAt,
    required this.expiresAt,
    required this.reactionsCount,
    required this.repliesCount,
    this.viewCount = 0,
    this.authorId,
    this.authorProfilePhotoUrl,
    this.imageUrl,
    this.audioUrl,
    this.audioDurationSeconds,
    this.authorIsVerified = false,
    this.myReaction,
    this.musicTrack,
    this.musicStartMs,
    this.musicDurationMs,
    this.musicVolume,
  });

  factory VentStory.fromPost(Post post, {DateTime? now}) {
    return VentStory(
      postId: post.postId,
      authorId: post.authorId,
      authorPseudonym: post.authorPseudonym,
      authorDisplayName: post.authorDisplayName,
      authorAvatarSeed: post.authorAvatarSeed,
      authorProfilePhotoUrl: post.authorProfilePhotoUrl,
      content: post.content,
      category: post.categoryName,
      mood: post.postMood,
      createdAt: post.createdAt,
      expiresAt: post.createdAt.add(const Duration(hours: 24)),
      reactionsCount: post.likesCount,
      repliesCount: post.commentsCount,
      viewCount: post.viewCount,
      imageUrl: post.imageUrl,
      audioUrl: post.audioUrl,
      audioDurationSeconds: post.audioDurationSeconds,
      authorIsVerified: post.authorIsVerified,
      myReaction: post.myReaction,
      musicTrack: post.musicTrack,
      musicStartMs: post.musicStartMs,
      musicDurationMs: post.musicDurationMs,
      musicVolume: post.musicVolume,
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
  bool hasRecentPost = false;
}
