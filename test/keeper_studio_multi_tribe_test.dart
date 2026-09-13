import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/keeper/keeper_overview.dart';
import 'package:vently_app/domain/tribe/tribe_management.dart';
import 'package:vently_app/presentation/screens/home/keeper_members_screen.dart';
import 'package:vently_app/presentation/widgets/studio_tribe_selector.dart';

Tribe _tribe(String id, String name, int members) => Tribe(
  tribeId: id,
  name: name,
  slug: name.toLowerCase(),
  category: 'support',
  memberCount: members,
  isPrivate: false,
  createdAt: DateTime(2026, 1, 1),
  keeperId: 'me',
);

TribeStudioStats _stats(
  String id, {
  int members = 0,
  int active = 0,
  int pending = 0,
  int mods = 0,
  int banned = 0,
}) => TribeStudioStats(
  tribeId: id,
  memberCount: members,
  members7d: 0,
  members30d: 0,
  posts24h: 0,
  posts7d: 0,
  comments7d: 0,
  activePosters7d: 0,
  pinnedCount: 0,
  scheduledPrompts: 0,
  openReports: 0,
  membersActive24h: active,
  moderatorCount: mods,
  pendingRequests: pending,
  bannedCount: banned,
);

TribeMemberRow _member(
  String id, {
  String role = 'member',
  String? name,
  int warnings = 0,
}) => TribeMemberRow(
  userId: id,
  pseudonym: id,
  displayName: name ?? id,
  avatarSeed: 'rose-orb-0001',
  role: role,
  joinedAt: DateTime(2026, 6, 1),
  warningCount: warnings,
);

class _FakeRepo extends VentlyRepository {
  _FakeRepo({
    this.kept = const [],
    this.statsById = const {},
    this.membersById = const {},
    this.requestsById = const {},
  }) : super(forceMock: true);

  final List<Tribe> kept;
  final Map<String, TribeStudioStats> statsById;
  final Map<String, List<TribeMemberRow>> membersById;
  final Map<String, List<TribeJoinRequest>> requestsById;

  final List<({String action, String tribeId, String userId})> calls = [];

  @override
  Future<List<Tribe>> tribesIKeep() async => kept;

  @override
  Future<TribeStudioStats?> tribeStudioStats(String tribeId) async =>
      statsById[tribeId];

  @override
  Future<List<TribeMemberRow>> tribeMembers(String tribeId) async =>
      membersById[tribeId] ?? const [];

  @override
  Future<List<TribeJoinRequest>> tribeJoinRequests(String tribeId) async =>
      requestsById[tribeId] ?? const [];

  @override
  Future<List<Map<String, dynamic>>> tribeBans(String tribeId) async =>
      const [];

  @override
  Future<void> promoteToMod({
    required String tribeId,
    required String userId,
  }) async => calls.add((
    action: 'promote',
    tribeId: tribeId,
    userId: userId,
  ));

  @override
  Future<void> kickMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) async => calls.add((action: 'kick', tribeId: tribeId, userId: userId));

  @override
  Future<void> banMember({
    required String tribeId,
    required String userId,
    String? reason,
  }) async => calls.add((action: 'ban', tribeId: tribeId, userId: userId));
}

Future<void> _pumpMembers(WidgetTester tester, _FakeRepo repo) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const KeeperMembersScreen()),
      GoRoute(
        path: '/user/:id',
        builder: (_, __) => const Scaffold(body: Text('a profile')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the scope is what every Studio page reads', () {
    // The bug being fixed: nine screens watched primaryKeeperTribeProvider,
    // which returns tribes.first, so a keeper of three tribes could reach
    // exactly one of them and was never told the others existed.
    test('no Studio page reads primaryKeeperTribeProvider any more', () {
      final offenders = <String>[];
      for (final dir in const [
        'lib/presentation/screens/keeper',
        'lib/presentation/screens/home',
        'lib/presentation/widgets',
      ]) {
        for (final entity in Directory(dir).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final src = entity.readAsStringSync();
          // Comments explaining the migration mention it on purpose.
          final uses = RegExp(
            r'ref\.(read|watch)\(primaryKeeperTribeProvider\)',
          ).hasMatch(src);
          if (uses) offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These read the single-tribe provider and will only ever show a '
            'keeper their largest tribe. Use studioSelectedTribeProvider / '
            'studioScopedTribesProvider, or resolveStudioTargetTribe for a '
            'write: $offenders',
      );
    });
  });

  group('KeeperOverview.scopedTo', () {
    final overview = KeeperOverview(
      tribes: [_tribe('a', 'Alpha', 100), _tribe('b', 'Beta', 7)],
      statsByTribeId: {
        'a': _stats('a', members: 100, active: 40, pending: 3, mods: 5),
        'b': _stats('b', members: 7, active: 2, pending: 1, mods: 1),
      },
    );

    test('null scope keeps every tribe', () {
      final all = overview.scopedTo(null);
      expect(all.tribeCount, 2);
      expect(all.totalMembers, 107);
      expect(all.totalActiveToday, 42);
      expect(all.totalPendingRequests, 4);
      expect(all.totalModerators, 6);
    });

    test('a scoped id narrows every total, not just the tribe list', () {
      // The whole point: a narrowed overview must not still report the other
      // tribe's numbers, because the page renders them under one tribe's name.
      final beta = overview.scopedTo('b');
      expect(beta.tribeCount, 1);
      expect(beta.tribes.single.name, 'Beta');
      expect(beta.totalMembers, 7);
      expect(beta.totalActiveToday, 2);
      expect(beta.totalPendingRequests, 1);
      expect(beta.totalModerators, 1);
    });

    test('an id that is not here yields nothing, not the unscoped totals', () {
      // Falling back to "all" would print 107 members under the name of a
      // tribe that has 7, or one that no longer exists.
      final gone = overview.scopedTo('deleted');
      expect(gone.tribeCount, 0);
      expect(gone.totalMembers, 0);
      expect(gone.totalPendingRequests, 0);
    });
  });

  group('studioSelectedTribeProvider', () {
    test('is null for All Tribes', () async {
      final repo = _FakeRepo(kept: [_tribe('a', 'Alpha', 3)]);
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      await container.read(tribesIKeepProvider.future);
      expect(container.read(studioSelectedTribeProvider), isNull);
      expect(container.read(studioScopedTribesProvider), hasLength(1));
    });

    test('resolves the scoped id to its tribe', () async {
      final repo = _FakeRepo(
        kept: [_tribe('a', 'Alpha', 3), _tribe('b', 'Beta', 9)],
      );
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      await container.read(tribesIKeepProvider.future);

      container.read(studioTribeScopeProvider.notifier).state = 'b';
      expect(container.read(studioSelectedTribeProvider)?.name, 'Beta');
      expect(container.read(studioScopedTribesProvider), hasLength(1));
    });

    test('self-heals when the scoped tribe is gone', () async {
      // A deleted or transferred tribe must read as All Tribes rather than
      // pinning a stale row — otherwise every page shows numbers for a tribe
      // the keeper no longer has, with no way to notice.
      final repo = _FakeRepo(kept: [_tribe('a', 'Alpha', 3)]);
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      await container.read(tribesIKeepProvider.future);

      container.read(studioTribeScopeProvider.notifier).state = 'deleted';
      expect(container.read(studioSelectedTribeProvider), isNull);
      expect(
        container.read(studioScopedTribesProvider).single.name,
        'Alpha',
        reason: 'a stale scope falls back to every kept tribe',
      );
    });

    test('the selector hides itself for a keeper with one tribe', () async {
      final one = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(
            _FakeRepo(kept: [_tribe('a', 'Alpha', 3)]),
          ),
        ],
      );
      addTearDown(one.dispose);
      await one.read(tribesIKeepProvider.future);
      expect(one.read(studioHasMultipleTribesProvider), isFalse);

      final two = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(
            _FakeRepo(
              kept: [_tribe('a', 'Alpha', 3), _tribe('b', 'Beta', 4)],
            ),
          ),
        ],
      );
      addTearDown(two.dispose);
      await two.read(tribesIKeepProvider.future);
      expect(two.read(studioHasMultipleTribesProvider), isTrue);
    });
  });

  group('Members — All Tribes', () {
    testWidgets('rolls up across every kept tribe and lists them all', (
      tester,
    ) async {
      final repo = _FakeRepo(
        kept: [
          _tribe('a', 'Alpha', 100),
          _tribe('b', 'Beta', 7),
          _tribe('c', 'Gamma', 1),
        ],
        statsById: {
          'a': _stats('a', members: 100, active: 40, pending: 3, mods: 5),
          'b': _stats('b', members: 7, active: 2, pending: 1, mods: 1),
          'c': _stats('c', members: 1, active: 1, mods: 1),
        },
      );
      await _pumpMembers(tester, repo);

      // The roll-up, not one tribe's numbers.
      expect(find.text('108'), findsOne, reason: 'members 100 + 7 + 1');
      expect(find.text('43'), findsOne, reason: 'active today 40 + 2 + 1');
      expect(find.text('4'), findsOne, reason: 'pending 3 + 1');
      expect(find.text('7'), findsOne, reason: 'moderators 5 + 1 + 1');

      // Every tribe is reachable. This is the regression that mattered: a
      // keeper of three used to see one.
      expect(find.text('Alpha'), findsOne);
      expect(find.text('Beta'), findsOne);
      expect(find.text('Gamma'), findsOne);
      expect(find.textContaining('Across 3 tribes'), findsOne);
    });

    testWidgets('"Active today" says what it counts', (tester) async {
      // In this schema every membership is active, so an unqualified "Active"
      // beside "Members" reads as a status breakdown that does not exist.
      final repo = _FakeRepo(
        kept: [_tribe('a', 'Alpha', 10), _tribe('b', 'Beta', 2)],
        statsById: {
          'a': _stats('a', members: 10, active: 4),
          'b': _stats('b', members: 2, active: 1),
        },
      );
      await _pumpMembers(tester, repo);

      expect(find.text('Active today'), findsOne);
      expect(find.text('seen in 24h'), findsOne);
      expect(find.text('Active'), findsNothing);
    });

    testWidgets('tapping a tribe scopes the whole Studio to it', (
      tester,
    ) async {
      final repo = _FakeRepo(
        kept: [_tribe('a', 'Alpha', 100), _tribe('b', 'Beta', 7)],
        statsById: {
          'a': _stats('a', members: 100),
          'b': _stats('b', members: 7, active: 2, pending: 1, mods: 1),
        },
        membersById: {
          'b': [_member('kai', role: 'keeper'), _member('rae')],
        },
      );
      await _pumpMembers(tester, repo);

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();

      // Now the roster for Beta, not the roll-up.
      expect(find.text('Search members'), findsOne);
      expect(find.text('kai'), findsOne);
      expect(find.text('rae'), findsOne);
      expect(find.textContaining('Across 2 tribes'), findsNothing);
    });
  });

  group('Members — one tribe', () {
    Future<void> pumpBeta(WidgetTester tester, _FakeRepo repo) async {
      await _pumpMembers(tester, repo);
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
    }

    _FakeRepo betaRepo() => _FakeRepo(
      kept: [_tribe('a', 'Alpha', 100), _tribe('b', 'Beta', 4)],
      statsById: {
        'a': _stats('a', members: 100),
        'b': _stats('b', members: 4, active: 2, pending: 1, mods: 2),
      },
      membersById: {
        'b': [
          _member('kai', role: 'keeper', name: 'Kai'),
          _member('mod1', role: 'mod', name: 'Sam'),
          _member('rae', name: 'Rae'),
          _member('lex', name: 'Lex', warnings: 2),
        ],
      },
      requestsById: {
        'b': [
          TribeJoinRequest(
            requestId: 'r1',
            userId: 'hope',
            pseudonym: 'hopeful',
            avatarSeed: 'rose-orb-0001',
            createdAt: DateTime(2026, 8, 1),
            note: 'I could use somewhere like this.',
          ),
        ],
      },
    );

    testWidgets('search matches handle and display name', (tester) async {
      await pumpBeta(tester, betaRepo());

      // Asserted on the "@handle · joined" line rather than on the display
      // name: the search field itself renders the query, so find.text('Sam')
      // matches the EditableText too and says nothing about the roster.
      await tester.enterText(find.byType(TextField), 'rae');
      await tester.pumpAndSettle();
      expect(find.textContaining('@rae ·'), findsOne);
      expect(find.textContaining('@kai ·'), findsNothing);

      // Display name, which is not the handle and is what a keeper is more
      // likely to remember. 'Sam' is @mod1.
      await tester.enterText(find.byType(TextField), 'Sam');
      await tester.pumpAndSettle();
      expect(find.textContaining('@mod1 ·'), findsOne);
      expect(find.textContaining('@rae ·'), findsNothing);
    });

    testWidgets('an empty search result explains itself', (tester) async {
      await pumpBeta(tester, betaRepo());
      await tester.enterText(find.byType(TextField), 'nobodyhere');
      await tester.pumpAndSettle();
      expect(find.textContaining('Nobody matches'), findsOne);
    });

    testWidgets('the Moderators filter shows keeper and mods only', (
      tester,
    ) async {
      await pumpBeta(tester, betaRepo());
      // 'Moderators' is both a KPI label and a filter chip; the chip is the
      // later of the two in the tree.
      await tester.tap(find.text('Moderators').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('@kai ·'), findsOne);
      expect(find.textContaining('@mod1 ·'), findsOne);
      expect(find.textContaining('@rae ·'), findsNothing);
      expect(find.textContaining('@lex ·'), findsNothing);
    });

    testWidgets('warnings surface on the row', (tester) async {
      await pumpBeta(tester, betaRepo());
      expect(find.text('2 warnings'), findsOne);
    });

    testWidgets('pending requests show the note and can be acted on', (
      tester,
    ) async {
      await pumpBeta(tester, betaRepo());
      await tester.tap(find.text('Pending').last);
      await tester.pumpAndSettle();

      expect(find.text('@hopeful'), findsOne);
      // The note is the only thing a keeper has to decide on, so it is not
      // hidden behind a tap.
      expect(find.textContaining('I could use somewhere like this'), findsOne);
      expect(find.text('Approve'), findsOne);
      expect(find.text('Decline'), findsOne);
    });

    testWidgets('removing a member confirms first, and can be cancelled', (
      tester,
    ) async {
      final repo = betaRepo();
      await pumpBeta(tester, repo);

      // Rae's own card, found from her handle line so the menu tapped is
      // hers and not the header's or a neighbour's.
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.textContaining('@rae ·'),
            matching: find.byType(Container),
          ).last,
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from tribe'));
      await tester.pumpAndSettle();

      expect(find.text('Remove Rae?'), findsOne);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        repo.calls,
        isEmpty,
        reason: 'cancelling a destructive action must not call the server',
      );
    });

    testWidgets('the keeper cannot be removed or demoted from the roster', (
      tester,
    ) async {
      final repo = betaRepo();
      await pumpBeta(tester, repo);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.textContaining('@kai ·'),
            matching: find.byType(Container),
          ).last,
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pumpAndSettle();

      // Server-side `can_manage_tribe` is the real guard; hiding these is the
      // courtesy of not offering what the database will refuse.
      expect(find.text('Remove from tribe'), findsNothing);
      expect(find.text('Ban from tribe'), findsNothing);
    });

    testWidgets('switching tribe clears the previous search', (tester) async {
      final repo = betaRepo();
      await pumpBeta(tester, repo);
      await tester.enterText(find.byType(TextField), 'Rae');
      await tester.pumpAndSettle();
      expect(find.textContaining('@rae ·'), findsOne);

      // Back to All Tribes, then into Alpha. Carrying "Rae" across would make
      // Alpha's roster look empty for a reason nothing on screen explains.
      await tester.tap(find.byType(StudioTribeSelector));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All Tribes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Across 2 tribes'), findsOne);
    });
  });

  group('resolveStudioTargetTribe', () {
    // Reading under All Tribes can be a sum. Writing cannot: an announcement
    // has to land in one community, and choosing the largest on the keeper's
    // behalf is how a message for a small support tribe reaches a big one.
    testWidgets('a keeper with one tribe is never asked', (tester) async {
      final repo = _FakeRepo(kept: [_tribe('a', 'Alpha', 3)]);
      Tribe? resolved;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async =>
                      resolved = await resolveStudioTargetTribe(context, ref),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      // Let tribesIKeep land before resolving.
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(resolved?.name, 'Alpha');
      expect(find.text('Post to'), findsNothing);
    });

    testWidgets('an ambiguous target asks, and offers no All Tribes', (
      tester,
    ) async {
      final repo = _FakeRepo(
        kept: [_tribe('a', 'Alpha', 100), _tribe('b', 'Beta', 7)],
      );
      Tribe? resolved;
      var returned = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    resolved = await resolveStudioTargetTribe(context, ref);
                    returned = true;
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('Post to'), findsOne);
      expect(
        find.text('All Tribes'),
        findsNothing,
        reason: 'there is no such destination to publish to',
      );

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(resolved?.name, 'Beta');
      expect(returned, isTrue);
    });

    testWidgets('dismissing the picker cancels rather than defaulting', (
      tester,
    ) async {
      final repo = _FakeRepo(
        kept: [_tribe('a', 'Alpha', 100), _tribe('b', 'Beta', 7)],
      );
      Tribe? resolved;
      var returned = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    resolved = await resolveStudioTargetTribe(context, ref);
                    returned = true;
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // Tap the scrim to dismiss.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(
        resolved,
        isNull,
        reason: 'a dismissed picker must not publish to a default tribe',
      );
    });
  });
}
