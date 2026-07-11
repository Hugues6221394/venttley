import '../entities/entities.dart';

/// Aggregated keeper metrics across every tribe the user manages.
class KeeperOverview {
  final List<Tribe> tribes;
  final Map<String, TribeStudioStats?> statsByTribeId;

  const KeeperOverview({
    required this.tribes,
    required this.statsByTribeId,
  });

  factory KeeperOverview.empty() =>
      const KeeperOverview(tribes: [], statsByTribeId: {});

  int get tribeCount => tribes.length;

  int get totalMembers =>
      tribes.fold(0, (sum, t) => sum + t.memberCount);

  int get totalOpenReports => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.openReports);

  int get totalPosts24h => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.posts24h);

  int get totalNewMembers7d => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.members7d);

  int get totalActivePosters7d => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.activePosters7d);

  int get totalScheduledPrompts => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.scheduledPrompts);

  /// Recent posts likely still needing keeper replies (proxy from studio stats).
  int get totalUnansweredPosts => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) {
        if (s.posts24h <= 0) return sum;
        if (s.comments7d >= s.posts7d) return sum;
        return sum + s.posts24h;
      });

  TribeStudioStats? statsFor(String tribeId) => statsByTribeId[tribeId];

  /// Rough engagement score 0–100 from recent activity signals.
  int engagementScoreFor(TribeStudioStats? stats) {
    if (stats == null) return 0;
    final posts = stats.posts7d.clamp(0, 50);
    final comments = stats.comments7d.clamp(0, 200);
    final posters = stats.activePosters7d.clamp(0, 30);
    final raw = (posts * 2 + comments * 0.5 + posters * 3).round();
    return raw.clamp(0, 100);
  }
}
