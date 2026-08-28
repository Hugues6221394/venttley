import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/notification_routing.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  test('post detail falls back to a post already visible in the feed',
      () async {
    final visiblePost = Post(
      postId: 'feed-only-post',
      authorPseudonym: '@ReliableSignal',
      authorAvatarSeed: 'berry',
      categoryName: 'confessions',
      postType: 'user_post',
      content: 'This post must keep opening from the feed.',
      postMood: 'hopeful',
      likesCount: 4,
      commentsCount: 2,
      createdAt: DateTime(2026, 7, 16),
    );
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(
          VentlyRepository(forceMock: true),
        ),
        feedPostsProvider.overrideWith(
          (_) => Stream.value([visiblePost]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(feedPostsProvider.future);
    final resolved =
        await container.read(postByIdProvider(visiblePost.postId).future);

    expect(resolved, same(visiblePost));
  });

  testWidgets('notification navigation carries a known post into its route',
      (tester) async {
    final post = Post(
      postId: 'notification-post',
      authorPseudonym: '@ReliableSignal',
      authorAvatarSeed: 'berry',
      categoryName: 'confessions',
      postType: 'user_post',
      content: 'Notification route seed.',
      postMood: 'hopeful',
      likesCount: 1,
      commentsCount: 1,
      createdAt: DateTime(2026, 7, 16),
    );
    late GoRouter router;
    router = GoRouter(
      initialLocation: '/notifications',
      routes: [
        GoRoute(
          path: '/notifications',
          builder: (context, _) => Material(
            child: Center(
              child: TextButton(
                onPressed: () => navigateFromNotificationPayload(
                  router,
                  NotificationPayload.post(post.postId),
                  extra: post,
                ),
                child: const Text('Open notification'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (_, state) {
            final seeded = state.extra as Post?;
            return Material(child: Text(seeded?.content ?? 'Missing seed'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Open notification'));
    await tester.pumpAndSettle();

    expect(find.text(post.content), findsOneWidget);
    expect(find.text('Missing seed'), findsNothing);
  });

  testWidgets('post notifications stay on the root navigator from chat',
      (tester) async {
    late GoRouter router;
    router = GoRouter(
      initialLocation: '/chat/room-id',
      routes: [
        GoRoute(
          path: '/chat/:roomId',
          builder: (context, _) => Material(
            child: Center(
              child: TextButton(
                onPressed: () => navigateFromNotificationPayload(
                  router,
                  NotificationPayload.post('shared-post'),
                ),
                child: const Text('Open shared post'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/post-preview/:id',
          builder: (_, state) => Material(
            child: Text('Preview ${state.pathParameters['id']}'),
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (_, state) => Material(
            child: Text('Shell ${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Open shared post'));
    await tester.pumpAndSettle();

    expect(find.text('Preview shared-post'), findsOneWidget);
    expect(find.text('Shell shared-post'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
