import 'dart:math' as math;

import '../entities/entities.dart';

class TribeRecommendation {
  const TribeRecommendation({
    required this.tribe,
    required this.score,
    required this.reason,
  });

  final Tribe tribe;
  final double score;
  final String reason;
}

/// Lightweight recommendation ranker built from data already available in
/// the app. The personalized feed provides affinity and recency signals while
/// member count supplies a stable cold-start fallback.
abstract final class TribeRecommendations {
  static List<TribeRecommendation> rank({
    required List<Tribe> tribes,
    required List<Post> personalizedPosts,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final signals = <String, _TribeSignals>{};

    for (var index = 0; index < personalizedPosts.length; index++) {
      final post = personalizedPosts[index];
      final tribeId = post.tribeId;
      if (tribeId == null) continue;

      final signal = signals.putIfAbsent(tribeId, _TribeSignals.new);
      final feedPosition = personalizedPosts.isEmpty
          ? 0.0
          : (personalizedPosts.length - index) / personalizedPosts.length;
      final ageHours = clock.difference(post.createdAt).inMinutes / 60.0;
      final freshness = ageHours < 0 ? 1.0 : 1 / (1 + (ageHours / 24));
      final socialProof =
          math.log(1 + post.likesCount + (post.commentsCount * 1.5));

      signal.score += (feedPosition * 9) + (freshness * 5) + socialProof;
      signal.posts += 1;
      if (post.myReaction != null || post.savedByMe) {
        signal.personalActions += 1;
        signal.score += post.savedByMe ? 18 : 12;
      }
    }

    final ranked = tribes.map((tribe) {
      final signal = signals[tribe.tribeId];
      final momentum = math.log(1 + math.max(0, tribe.memberCount)) * 4;
      final score = momentum + (signal?.score ?? 0);
      final reason = switch (signal) {
        _TribeSignals(personalActions: > 0) => 'Matches your activity',
        _TribeSignals(posts: > 0) => 'Active in your feed',
        _ when tribe.memberCount >= 10 => 'Trending now',
        _ => 'Growing community',
      };
      return TribeRecommendation(
        tribe: tribe,
        score: score,
        reason: reason,
      );
    }).toList()
      ..sort((a, b) {
        // Discovery prioritizes communities the user can still join. Joined
        // tribes remain available below them for quick access.
        if (a.tribe.joinedByMe != b.tribe.joinedByMe) {
          return a.tribe.joinedByMe ? 1 : -1;
        }
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.tribe.name.toLowerCase().compareTo(
              b.tribe.name.toLowerCase(),
            );
      });

    return ranked;
  }
}

class _TribeSignals {
  double score = 0;
  int posts = 0;
  int personalActions = 0;
}
