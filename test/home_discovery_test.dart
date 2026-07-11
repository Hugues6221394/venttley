import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/home/home_discovery.dart';

void main() {
  final now = DateTime(2026, 6, 14, 12);

  Post post({
    required String id,
    required String category,
    required DateTime createdAt,
    int likes = 0,
    int comments = 0,
    bool story = false,
    String content = 'A tiny story about campus life and music.',
    String? authorId,
  }) {
    return Post(
      postId: id,
      authorId: authorId,
      authorPseudonym: '@demo',
      authorAvatarSeed: 'seed',
      categoryName: category,
      postType: 'user_post',
      content: content,
      postMood: 'okay',
      likesCount: likes,
      commentsCount: comments,
      createdAt: createdAt,
      isWhisper: story,
    );
  }

  Tribe tribe({
    required String id,
    required String name,
    required int members,
    bool joined = false,
  }) {
    return Tribe(
      tribeId: id,
      name: name,
      slug: id,
      category: 'interest_group',
      memberCount: members,
      isPrivate: false,
      createdAt: now.subtract(const Duration(days: 10)),
      joinedByMe: joined,
    );
  }

  test('premium home model exposes active stories and skips expired ones', () {
    final model = HomeDiscovery.from(
      posts: [
        post(
          id: 'active-story',
          category: 'confessions',
          createdAt: now.subtract(const Duration(hours: 3)),
          story: true,
        ),
        post(
          id: 'expired-story',
          category: 'confessions',
          createdAt: now.subtract(const Duration(hours: 25)),
          story: true,
        ),
      ],
      tribes: const [],
      now: now,
    );

    expect(model.activeStories.map((s) => s.postId), ['active-story']);
    expect(model.activeStories.single.expiresAt, now.add(const Duration(hours: 21)));
  });

  test('premium home model ranks trending topics and tribes', () {
    final model = HomeDiscovery.from(
      posts: [
        post(
          id: 'p1',
          category: 'campus',
          createdAt: now.subtract(const Duration(hours: 1)),
          likes: 8,
          comments: 6,
        ),
        post(
          id: 'p2',
          category: 'campus',
          createdAt: now.subtract(const Duration(hours: 2)),
          likes: 4,
          comments: 3,
        ),
        post(
          id: 'p3',
          category: 'relationships',
          createdAt: now.subtract(const Duration(hours: 1)),
          likes: 12,
          comments: 2,
        ),
      ],
      tribes: [
        tribe(id: 'music', name: 'Late Night Music', members: 4200),
        tribe(id: 'campus', name: 'Campus Unfiltered', members: 9800),
        tribe(id: 'quiet', name: 'Small Table', members: 12, joined: true),
      ],
      now: now,
    );

    expect(model.kpis.first.label, 'Live posts');
    expect(model.kpis.first.value, '3');
    expect(model.trendingTopics.first.category, 'campus');
    expect(model.trendingTopics.first.score, greaterThan(model.trendingTopics.last.score));
    // Joined tribes get pushed to the top of the rail so people see the
    // communities they already belong to first; remaining order falls
    // back to member count.
    expect(
      model.trendingTribes.map((t) => t.tribeId),
      ['quiet', 'campus', 'music'],
    );
  });

  test('friend stories include only self and accepted friends', () {
    final stories = HomeDiscovery.friendStories(
      posts: [
        post(
          id: 'self-story',
          category: 'confessions',
          createdAt: now.subtract(const Duration(hours: 2)),
          story: true,
          authorId: 'me',
        ),
        post(
          id: 'friend-story',
          category: 'campus',
          createdAt: now.subtract(const Duration(hours: 1)),
          story: true,
          authorId: 'friend-1',
        ),
        post(
          id: 'stranger-story',
          category: 'campus',
          createdAt: now.subtract(const Duration(hours: 1)),
          story: true,
          authorId: 'stranger',
        ),
        post(
          id: 'normal-post',
          category: 'campus',
          createdAt: now.subtract(const Duration(minutes: 30)),
          authorId: 'friend-1',
        ),
        post(
          id: 'expired-friend-story',
          category: 'campus',
          createdAt: now.subtract(const Duration(hours: 26)),
          story: true,
          authorId: 'friend-1',
        ),
        post(
          id: 'anonymous-author-story',
          category: 'campus',
          createdAt: now.subtract(const Duration(minutes: 15)),
          story: true,
        ),
      ],
      myUserId: 'me',
      friendUserIds: {'friend-1'},
      now: now,
    );

    expect(
      stories.map((story) => story.postId),
      ['friend-story', 'self-story'],
    );
  });
}
