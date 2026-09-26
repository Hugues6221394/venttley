import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/friends/friend_profile_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/profile_stats_panel.dart';

/// Somebody else's profile, as a visitor sees it.
///
/// Reported as immature and unprofessional, with a screenshot: a centred
/// column of a circle, a name, a handle, a pill, a sentence, three shadowed
/// boxes and a full-width button — then four large cards reading 0, 0, 0, 1.
///
/// These are the decisions that fixed it, held so the next edit has to mean to
/// undo them.
UserProfileView _profile({
  FriendStatus relation = FriendStatus.none,
  String? bio = 'Keeper of Night Owls. I read everything that lands here.',
  int? reactions,
  int? comments,
  int? streak,
  int? badges,
}) => UserProfileView(
  relation: relation,
  userId: 'u1',
  pseudonym: 'tester_keeper',
  displayName: 'tester_keeper',
  avatarSeed: 'seed',
  karma: 0,
  isVerified: true,
  joinedAt: DateTime(2026, 9, 1),
  accountStatus: 'active',
  safetyTier: 'standard',
  vents: 0,
  activeTribes: 1,
  mutualFriendsCount: 0,
  mutualFriendSample: const [],
  mutualTribes: const [],
  connectionsCount: 0,
  topMoods: const [],
  recentPosts: const [],
  badges: const [],
  currentMood: 'healing',
  pronouns: 'she/her',
  bio: bio,
  reactionsReceived: reactions,
  comments: comments,
  currentStreak: streak,
  badgesCount: badges,
);

Future<void> _open(WidgetTester tester, UserProfileView profile) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final router = GoRouter(
    initialLocation: '/user/u1',
    routes: [
      GoRoute(
        path: '/user/:id',
        builder: (_, __) => const FriendProfileScreen(userId: 'u1'),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Mock rather than live: the screen reads the session, which builds a
        // repository, which asserts on an uninitialised Supabase in a test.
        repositoryProvider.overrideWithValue(VentlyRepository(forceMock: true)),
        userProfileProvider('u1').overrideWith((ref) async => profile),
        friendStatusProvider(
          'u1',
        ).overrideWith((ref) async => profile.relation),
      ],
      child: MaterialApp.router(
        theme: VentlyTheme.light(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the name, handle and bio share one left margin', (tester) async {
    await _open(tester, _profile());

    // Left-aligned, on the same line, is what makes it read as a page rather
    // than a poster. Centred text was the loudest part of the report.
    final name = tester.getTopLeft(find.text('tester_keeper'));
    final handle = tester.getTopLeft(find.text('@tester_keeper'));
    final bio = tester.getTopLeft(find.textContaining('Keeper of Night Owls'));
    expect(name.dx, closeTo(handle.dx, 1));
    expect(name.dx, closeTo(bio.dx, 1));
    expect(
      name.dx,
      lessThan(40),
      reason: 'anchored to the page margin, not centred',
    );
  });

  testWidgets('a visitor sees the bio without being a friend', (tester) async {
    await _open(tester, _profile(relation: FriendStatus.none));

    expect(find.textContaining('Keeper of Night Owls'), findsOneWidget);
  });

  testWidgets('the three numbers sit beside the avatar, not under it', (
    tester,
  ) async {
    await _open(tester, _profile());

    final connections = tester.getCenter(find.text('Connections'));
    final name = tester.getTopLeft(find.text('tester_keeper'));
    expect(
      connections.dy,
      lessThan(name.dy),
      reason: 'the numbers share the avatar row, above the name block',
    );
    for (final label in ['Connections', 'Vents', 'Tribes']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('a stranger is not shown four zeros for hidden numbers', (
    tester,
  ) async {
    // The server withholds these from non-friends, so they arrive null. They
    // used to render as "0" — a page saying this person has done nothing, about
    // numbers that are none of the visitor's business.
    await _open(tester, _profile(relation: FriendStatus.none));

    expect(find.byType(ProfileStatsPanel), findsNothing);
    expect(find.text('Reactions received'), findsNothing);
    expect(find.text('Streak'), findsNothing);
  });

  testWidgets('and is told plainly what friendship would open', (tester) async {
    await _open(tester, _profile(relation: FriendStatus.none));

    expect(find.text('The rest is friends-only'), findsOneWidget);
    expect(find.text('Messages open once you are friends.'), findsOneWidget);
  });

  testWidgets('a friend sees the numbers, in one strip', (tester) async {
    await _open(
      tester,
      _profile(
        relation: FriendStatus.friends,
        reactions: 12,
        comments: 4,
        streak: 0,
        badges: 1,
      ),
    );

    expect(find.byType(ProfileStatsPanel), findsOneWidget);
    // One row: every label on the same baseline. The grid put two of them a
    // card-height below the others.
    final reactions = tester.getCenter(find.text('Reactions received'));
    final badges = tester.getCenter(find.text('Badges'));
    expect(
      reactions.dy,
      closeTo(badges.dy, 12),
      reason: 'four columns, not a two-by-two grid of cards',
    );
  });
}
