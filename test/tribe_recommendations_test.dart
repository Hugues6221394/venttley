import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/tribe/tribe_recommendations.dart';

void main() {
  final now = DateTime(2026, 7, 16, 1);

  Tribe tribe(String id, int members, {bool joined = false}) => Tribe(
        tribeId: id,
        name: 'Tribe $id',
        slug: id,
        category: 'support',
        memberCount: members,
        isPrivate: false,
        createdAt: now.subtract(const Duration(days: 30)),
        joinedByMe: joined,
      );

  Post post(String id, String tribeId, {bool saved = false}) => Post(
        postId: id,
        authorPseudonym: '@Signal',
        authorAvatarSeed: 'berry',
        tribeId: tribeId,
        categoryName: 'support',
        postType: 'user_post',
        content: 'A relevant conversation.',
        postMood: 'hopeful',
        likesCount: 8,
        commentsCount: 4,
        createdAt: now.subtract(const Duration(hours: 2)),
        savedByMe: saved,
      );

  test('personal activity can outrank generic community size', () {
    final ranked = TribeRecommendations.rank(
      tribes: [
        tribe('large', 10000),
        tribe('relevant', 24),
      ],
      personalizedPosts: [post('p1', 'relevant', saved: true)],
      now: now,
    );

    expect(ranked.first.tribe.tribeId, 'relevant');
    expect(ranked.first.reason, 'Matches your activity');
  });

  test('joinable recommendations appear before already joined Tribes', () {
    final ranked = TribeRecommendations.rank(
      tribes: [
        tribe('joined', 1000000, joined: true),
        tribe('discoverable', 8),
      ],
      personalizedPosts: const [],
      now: now,
    );

    expect(ranked.map((item) => item.tribe.tribeId), [
      'discoverable',
      'joined',
    ]);
  });
}
