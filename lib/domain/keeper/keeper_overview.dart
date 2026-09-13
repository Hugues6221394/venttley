import '../entities/entities.dart';

/// Aggregated keeper metrics across every tribe the user manages.
class KeeperOverview {
  final List<Tribe> tribes;
  final Map<String, TribeStudioStats?> statsByTribeId;

  const KeeperOverview({required this.tribes, required this.statsByTribeId});

  factory KeeperOverview.empty() =>
      const KeeperOverview(tribes: [], statsByTribeId: {});

  int get tribeCount => tribes.length;

  int get totalMembers => tribes.fold(0, (sum, t) => sum + t.memberCount);

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

  /// Members seen in the last 24 hours across the scope.
  ///
  /// A person who keeps two of the keeper's tribes counts in both, because the
  /// question this answers is "how much of my community showed up today", per
  /// tribe, summed — not "how many distinct humans". Distinct-across-tribes
  /// would need a query, not a fold, and is not what a keeper is asking.
  int get totalActiveToday => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.membersActive24h);

  /// Join requests awaiting a decision across the scope. The one number here
  /// that is a to-do rather than a statistic.
  int get totalPendingRequests => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.pendingRequests);

  int get totalModerators => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.moderatorCount);

  int get totalBanned => statsByTribeId.values
      .whereType<TribeStudioStats>()
      .fold(0, (sum, s) => sum + s.bannedCount);

  /// Recent posts likely still needing keeper replies (proxy from studio stats).
  int get totalUnansweredPosts =>
      statsByTribeId.values.whereType<TribeStudioStats>().fold(0, (sum, s) {
        if (s.posts24h <= 0) return sum;
        if (s.comments7d >= s.posts7d) return sum;
        return sum + s.posts24h;
      });

  TribeStudioStats? statsFor(String tribeId) => statsByTribeId[tribeId];

  /// The same overview narrowed to one tribe, or unchanged for All Tribes.
  ///
  /// Every total on this class is a fold over [tribes] / [statsByTribeId], so
  /// narrowing both is enough to make `totalMembers`, `totalOpenReports` and
  /// the rest answer for the scope. That keeps one implementation of each
  /// metric instead of a scoped and an unscoped version that drift.
  ///
  /// An id that is not in this overview yields an empty overview rather than
  /// the unscoped totals — showing every tribe's numbers under one tribe's
  /// name is the failure mode worth avoiding here.
  KeeperOverview scopedTo(String? tribeId) {
    if (tribeId == null) return this;
    final tribe = tribes.where((t) => t.tribeId == tribeId).toList();
    return KeeperOverview(
      tribes: tribe,
      statsByTribeId: {
        if (statsByTribeId.containsKey(tribeId))
          tribeId: statsByTribeId[tribeId],
      },
    );
  }

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
