import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/core/connection.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/data/services/mock_backend.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/feed/feed_screen.dart';
import 'package:vently_app/presentation/screens/friends/friends_screen.dart';
import 'package:vently_app/presentation/screens/home/home_shell.dart';
import 'package:vently_app/presentation/screens/inbox/inbox_screen.dart';
import 'package:vently_app/presentation/screens/notifications/notifications_screen.dart';
import 'package:vently_app/presentation/screens/whispers/whispers_screen.dart';
import 'package:vently_app/presentation/router/app_router.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/post_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    MockBackend.instance.registerSession(_user);
  });

  test('member footer keeps Friends among all six destinations', () {
    expect(
      HomeShell.memberDestinationLabels,
      equals(const [
        'Home',
        'Whispers',
        'Post',
        'Friends',
        'Inbox',
        'Profile',
      ]),
    );
  });

  testWidgets('premium feed stays composed on a compact phone', (tester) async {
    await _pumpScreen(tester, const FeedScreen());

    expect(find.text('Venttly'), findsOneWidget);
    expect(find.text('Take a breath. You’re safe here.'), findsOneWidget);
    expect(find.byKey(const Key('home-add-story')), findsOneWidget);
    expect(find.text('Your story'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/premium_feed.png'),
    );
  });

  testWidgets('empty personal feed falls back to community conversations',
      (tester) async {
    await _pumpScreen(
      tester,
      const FeedScreen(),
      feedPosts: const <Post>[],
      discoveryPosts: _posts,
    );
    await tester.scrollUntilVisible(
      find.text('Recommended from Venttly'),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Recommended from Venttly'), findsOneWidget);
    expect(find.textContaining('accounting course'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty Whispers keeps real community discovery visible',
      (tester) async {
    await _pumpScreen(tester, const WhispersScreen());

    expect(find.text('Be the first voice today'), findsOneWidget);
    expect(find.text('Conversations for you'), findsOneWidget);
    expect(find.byType(PostCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('premium notifications stay scannable on a compact phone',
      (tester) async {
    await _pumpScreen(
      tester,
      NotificationsScreen(referenceTime: _notificationReferenceTime),
    );

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Unread  2'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/premium_notifications.png'),
    );
  });

  testWidgets('premium footer renders all six member actions', (tester) async {
    await _pumpMemberShell(tester);

    for (final label in HomeShell.memberDestinationLabels) {
      expect(
        find.byKey(ValueKey('member-nav-${label.toLowerCase()}')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const ValueKey('member-nav-friends')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('member-bottom-navigation')),
      matchesGoldenFile('goldens/premium_member_footer.png'),
    );
  });

  testWidgets('premium chats stay composed on a compact phone', (tester) async {
    await _pumpScreen(tester, const InboxScreen());

    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/premium_chats.png'),
    );
  });

  testWidgets('premium circle stays composed on a compact phone',
      (tester) async {
    await _pumpScreen(tester, const FriendsScreen());

    expect(find.text('Your circle'), findsOneWidget);
    expect(find.text('Instant connect'), findsOneWidget);
    final exception = tester.takeException();
    expect(exception, isNull);
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/premium_circle.png'),
    );
  });

  testWidgets('circle exposes fast Tribe discovery without leaving the tab',
      (tester) async {
    await _pumpScreen(tester, const FriendsScreen());

    await tester.tap(find.text('Explore Tribes'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('Recommended Tribes'), findsOneWidget);
    expect(find.text('Search Tribes'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/premium_circle_tribes.png'),
    );
  });
}

const _surfaceKey = Key('premium-member-surface');

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen, {
  List<Post>? feedPosts,
  List<Post>? discoveryPosts,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repository = VentlyRepository(forceMock: true);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => RepaintBoundary(
          key: _surfaceKey,
          child: screen,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repository),
        feedPostsProvider.overrideWith(
          (_) => Stream.value(feedPosts ?? _posts),
        ),
        if (discoveryPosts != null)
          homeDiscoveryPostsProvider.overrideWith(
            (_) async => discoveryPosts,
          ),
        myFriendsProvider.overrideWith((_) async => _friends),
        incomingFriendRequestsProvider.overrideWith((_) async => _requests),
        outgoingFriendRequestsProvider.overrideWith((_) async => const []),
        friendSuggestionsProvider.overrideWith((_) async => const []),
        inboxCountsProvider.overrideWith((_) async => const {
              'requests': 1,
              'active': 3,
            }),
        tribeChatInboxProvider.overrideWith((_) async => const []),
        inboxTimestampFormatterProvider.overrideWithValue((timestamp) {
          final age = DateTime.now().difference(timestamp);
          return age.inHours < 4 ? '2h ago' : 'Yesterday';
        }),
        notificationsProvider.overrideWith((_) => Stream.value(_notifications)),
        myInvitesProvider.overrideWith((_) async => const []),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: VentlyTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _pumpMemberShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repository = VentlyRepository(forceMock: true);
  GoRouter? router;
  addTearDown(() => router?.dispose());

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repository),
        feedPostsProvider.overrideWith((_) => Stream.value(_posts)),
        homeDiscoveryPostsProvider.overrideWith((_) async => _posts),
        homeFriendStoriesProvider.overrideWith((_) async => const []),
        myFriendsProvider.overrideWith((_) async => _friends),
        incomingFriendRequestsProvider.overrideWith((_) async => _requests),
        outgoingFriendRequestsProvider.overrideWith((_) async => const []),
        friendSuggestionsProvider.overrideWith((_) async => const []),
        inboxCountsProvider.overrideWith((_) async => const {
              'requests': 1,
              'active': 3,
            }),
        navInboxBadgeCountProvider.overrideWith((_) async => 1),
        isKeeperProvider.overrideWith((_) async => false),
        connectionStatusProvider.overrideWith(
          (ref) => ConnectionController(ref, listenToConnectivity: false),
        ),
        outboxPendingCountProvider.overrideWith((_) => 0),
        outboxFailedCountProvider.overrideWith((_) => 0),
        notificationsProvider.overrideWith((_) => Stream.value(_notifications)),
        myInvitesProvider.overrideWith((_) async => const []),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          router = ref.watch(routerProvider);
          return MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: VentlyTheme.light(),
            routerConfig: router!,
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

List<NotificationItem> get _notifications {
  final now = _notificationReferenceTime;
  return [
    NotificationItem(
      id: 'notification-1',
      kind: 'post_like',
      title: 'LonelyPetal688',
      body: 'liked your vent “We are testing.”',
      createdAt: now.subtract(const Duration(minutes: 18)),
      isRead: false,
      payload: const {'post_id': 'post-1'},
    ),
    NotificationItem(
      id: 'notification-2',
      kind: 'comment_reply',
      title: 'GoldenHour',
      body: 'replied to your confession.',
      createdAt: now.subtract(const Duration(hours: 2)),
      isRead: false,
      payload: const {'post_id': 'post-1'},
    ),
    NotificationItem(
      id: 'notification-3',
      kind: 'tribe_prompt',
      title: 'New prompt in Quiet Mornings',
      body: 'What does your perfect quiet morning look like?',
      createdAt: now.subtract(const Duration(days: 2)),
      isRead: true,
      payload: const {'tribe_slug': 'quiet-mornings'},
    ),
  ];
}

final _notificationReferenceTime = DateTime(2026, 7, 16, 14);

const _user = AppUser(
  userId: 'me',
  anonymousPseudonym: 'SoftSignal',
  avatarSeed: 'v2:silhouette=orb;palette=berry',
  currentMood: 'hopeful',
  userRole: 'normal',
  isVerified: true,
  safetyTier: 'standard',
  accountStatus: 'active',
  emailVerified: true,
);

final _posts = <Post>[
  Post(
    postId: 'post-1',
    authorId: 'friend-1',
    authorPseudonym: '@WanderSoul',
    authorAvatarSeed: 'wander-purple',
    categoryName: 'confessions',
    postType: 'user_post',
    content:
        "I've been pretending to understand my accounting course for a whole semester. Exams are in 3 weeks. Pray for me.",
    postMood: 'anxious',
    likesCount: 10,
    commentsCount: 3,
    createdAt: DateTime(2026, 7, 8),
  ),
  Post(
    postId: 'post-2',
    authorId: 'friend-2',
    authorPseudonym: '@BrokenCompass',
    authorAvatarSeed: 'compass-blue',
    categoryName: 'adulting',
    postType: 'user_post',
    content:
        'Does anyone else feel like the library is a competitive stress arena? I walked in to study and left with anxiety.',
    postMood: 'exhausted',
    likesCount: 7,
    commentsCount: 5,
    createdAt: DateTime(2026, 7, 8),
  ),
];

final _friends = <FriendSummary>[
  FriendSummary(
    friendshipId: 'friendship-1',
    userId: 'friend-1',
    pseudonym: 'GoldenHour',
    avatarSeed: 'golden-blue',
    karma: 84,
    isVerified: false,
    acceptedAt: DateTime(2026, 7, 13),
    isFavorite: true,
  ),
  FriendSummary(
    friendshipId: 'friendship-2',
    userId: 'friend-2',
    pseudonym: 'HopeDealer',
    avatarSeed: 'hope-purple',
    karma: 112,
    isVerified: true,
    acceptedAt: DateTime(2026, 7, 12),
  ),
  FriendSummary(
    friendshipId: 'friendship-3',
    userId: 'friend-3',
    pseudonym: 'tester_user',
    avatarSeed: 'tester-green',
    karma: 39,
    isVerified: false,
    acceptedAt: DateTime(2026, 6, 3),
  ),
];

final _requests = <FriendRequest>[
  FriendRequest(
    friendshipId: 'request-1',
    otherUserId: 'friend-4',
    otherPseudonym: 'HealingSlow',
    otherAvatarSeed: 'healing-orange',
    otherKarma: 62,
    createdAt: DateTime(2026, 7, 9),
    isOutgoing: false,
  ),
];
