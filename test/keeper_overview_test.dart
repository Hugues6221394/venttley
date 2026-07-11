import 'package:flutter_test/flutter_test.dart';

import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/keeper/keeper_overview.dart';

void main() {
  test('KeeperOverview aggregates studio stats', () {
    final tribe = Tribe(
      tribeId: 't1',
      name: 'Test',
      slug: 'test',
      category: 'confessions',
      memberCount: 100,
      isPrivate: false,
      createdAt: DateTime(2024, 1, 1),
    );
    const stats = TribeStudioStats(
      tribeId: 't1',
      memberCount: 100,
      members7d: 5,
      members30d: 20,
      posts24h: 3,
      posts7d: 12,
      comments7d: 40,
      activePosters7d: 8,
      pinnedCount: 1,
      scheduledPrompts: 2,
      openReports: 4,
    );
    final overview = KeeperOverview(
      tribes: [tribe],
      statsByTribeId: const {'t1': stats},
    );

    expect(overview.totalMembers, 100);
    expect(overview.totalOpenReports, 4);
    expect(overview.totalPosts24h, 3);
    expect(overview.totalNewMembers7d, 5);
    expect(overview.totalUnansweredPosts, 3);
    expect(overview.engagementScoreFor(stats), greaterThan(0));
  });
}
