import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/home/keeper_home_screen.dart';

/// The Keeper Studio home.
///
/// Two rounds of "it still looks awkward and there is no change" came back on
/// this screen, and the cause was not styling. It had grown eight stacked
/// sections that each restated the ones above: open reports appeared five
/// times, in five different card shapes, all reading one field. And the
/// numbers were inert — a keeper who saw "3 reports" had no way to act on
/// them from the number itself.
///
/// So the tests are about those two things, not about pixels: every number is
/// stated once, and every number is a button.

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
  int posts24h = 0,
  int reports = 0,
  int pending = 0,
  int members7d = 0,
  int mods = 0,
}) => TribeStudioStats(
  tribeId: id,
  memberCount: 0,
  members7d: members7d,
  members30d: 0,
  posts24h: posts24h,
  posts7d: 0,
  comments7d: 0,
  activePosters7d: 0,
  pinnedCount: 0,
  scheduledPrompts: 0,
  openReports: reports,
  membersActive24h: 0,
  moderatorCount: mods,
  pendingRequests: pending,
  bannedCount: 0,
);

class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.kept = const [], this.statsById = const {}})
    : super(forceMock: true);

  final List<Tribe> kept;
  final Map<String, TribeStudioStats> statsById;

  @override
  Future<List<Tribe>> tribesIKeep() async => kept;

  @override
  Future<TribeStudioStats?> tribeStudioStats(String tribeId) async =>
      statsById[tribeId];
}

/// Where the last navigation landed, so a tap can be checked by destination
/// rather than by whatever the destination screen happens to render.
late List<String> _visited;

Future<void> _pumpStudio(
  WidgetTester tester,
  _FakeRepo repo, {
  Size size = const Size(520, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  _visited = <String>[];
  Widget landing(GoRouterState state) {
    _visited.add(state.uri.path);
    return Scaffold(body: Text('at ${state.uri.path}'));
  }

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const KeeperHomeScreen()),
      GoRoute(path: '/keeper/:page', builder: (_, s) => landing(s)),
      GoRoute(path: '/tribe/:slug/manage', builder: (_, s) => landing(s)),
      GoRoute(
        path: '/tribe/:slug/manage/settings',
        builder: (_, s) => landing(s),
      ),
      GoRoute(
        path: '/tribe/:slug/manage/settings/members',
        builder: (_, s) => landing(s),
      ),
      GoRoute(
        path: '/tribe/:slug/manage/settings/rules',
        builder: (_, s) => landing(s),
      ),
      GoRoute(path: '/tribes/new', builder: (_, s) => landing(s)),
      GoRoute(path: '/notifications', builder: (_, s) => landing(s)),
      GoRoute(path: '/profile/me', builder: (_, s) => landing(s)),
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
  testWidgets('every number is a button that opens where you act on it', (
    tester,
  ) async {
    await _pumpStudio(
      tester,
      _FakeRepo(
        kept: [_tribe('a', 'Alpha', 120)],
        statsById: {'a': _stats('a', posts24h: 9, reports: 3, pending: 2)},
      ),
    );

    // The four numbers, once each.
    expect(find.text('120'), findsOne);
    expect(find.text('3'), findsOne);
    expect(find.text('9'), findsOne);
    expect(find.text('2'), findsOne);

    // Reports is the one that mattered: a keeper who saw a count had to hunt
    // for Moderation in a tile further down the same screen.
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();
    expect(_visited, contains('/keeper/moderation'));
  });

  testWidgets('a KPI with one tribe never stops to ask which tribe', (
    tester,
  ) async {
    await _pumpStudio(
      tester,
      _FakeRepo(
        kept: [_tribe('a', 'Alpha', 120)],
        statsById: {'a': _stats('a')},
      ),
    );

    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    expect(_visited, contains('/tribe/alpha/manage/settings/members'));
  });

  testWidgets('switching tribe is one tap, and the numbers follow', (
    tester,
  ) async {
    await _pumpStudio(
      tester,
      _FakeRepo(
        kept: [_tribe('a', 'Alpha', 120), _tribe('b', 'Beta', 8)],
        // Split across the two tribes rather than piled on one, so the
        // roll-up (3) is a number neither tribe card also shows — otherwise
        // the assertion cannot tell a total from a breakdown.
        statsById: {
          'a': _stats('a', reports: 2),
          'b': _stats('b', reports: 1),
        },
      ),
    );

    // All tribes: the roll-up.
    expect(find.text('128'), findsOne, reason: '120 + 8');
    expect(find.text('3'), findsOne, reason: 'reports 3 + 0');

    // One tap on the rail — not a pill, a sheet, a row and a dismiss.
    // `.first` is the rail chip; the name also appears further down on Beta's
    // own card in the list below.
    await tester.tap(find.text('Beta').first);
    await tester.pumpAndSettle();

    expect(find.text('8'), findsOne, reason: "Beta's members");
    expect(find.text('128'), findsNothing, reason: 'still showing the roll-up');
    expect(find.text('1'), findsOne, reason: "Beta's one report, not Alpha's");
    expect(find.text('2'), findsNothing, reason: "Alpha's reports leaked in");
  });

  testWidgets('a keeper of one tribe is told whose numbers these are', (
    tester,
  ) async {
    await _pumpStudio(
      tester,
      _FakeRepo(
        kept: [_tribe('a', 'Alpha', 120)],
        statsById: {'a': _stats('a')},
      ),
    );
    // No rail — a row of one option is furniture — but the tribe is named,
    // because the four numbers below belong to it. Twice, deliberately: once
    // in the scope header, and once under Manage Tribe, which is naming what
    // it will open rather than repeating a statistic.
    expect(find.text('Alpha'), findsNWidgets(2));

    // The member count is the scope header's own line, so finding it is how
    // we know the header rendered rather than the rail.
    expect(find.text('120 members'), findsOne);
  });

  testWidgets('the whole panel still lays out on a small phone', (tester) async {
    // The quick-link panel is grids of six, and a grid that does not fit does
    // not shrink — it overflows, and on a sliver it can throw outright.
    // 375x667 is the smallest screen the app supports, and the test font is
    // wider than the real one, so clearing it here means clearing it there.
    await _pumpStudio(
      tester,
      _FakeRepo(
        kept: [_tribe('a', 'Alpha', 120)],
        statsById: {'a': _stats('a')},
      ),
      size: const Size(375, 667),
    );

    expect(tester.takeException(), isNull);

    // And the links are really there, not clipped out of the tree.
    for (final label in const [
      'Vent',
      'Announce',
      'Queue',
      'Insights',
      'Co-mods',
    ]) {
      expect(find.text(label), findsOne, reason: '$label went missing');
    }
  });

  testWidgets('the panel stays at two groups', (tester) async {
    // Thirty tiles in five labelled grids was most of a screen of icons, and
    // by the third heading it read as a directory rather than something to
    // reach into. The other eighteen destinations live in the drawer, which is
    // the right shape for a complete index. This fails if a third group grows
    // back here rather than going there.
    await _pumpStudio(
      tester,
      _FakeRepo(
        kept: [_tribe('a', 'Alpha', 120)],
        statsById: {'a': _stats('a')},
      ),
    );

    for (final heading in const ['CREATE', 'RUN YOUR TRIBE']) {
      expect(find.text(heading), findsOne);
    }
    for (final gone in const ['SAFETY', 'COMMUNITY', 'GROW', 'SET UP']) {
      expect(
        find.text(gone),
        findsNothing,
        reason: '$gone belongs in the drawer now',
      );
    }
  });

  test('no number is rendered twice on the Studio home', () {
    // The actual defect behind "so much AI vibe". Each section had been
    // written complete in itself and never reconciled with the ones above it,
    // so totalOpenReports was read in five places and totalScheduledPrompts in
    // three. A reader cannot tell repetition from disagreement.
    final src = File(
      'lib/presentation/screens/home/keeper_home_screen.dart',
    ).readAsStringSync();

    for (final field in const [
      'totalOpenReports',
      'totalScheduledPrompts',
      'totalNewMembers7d',
      'totalPosts24h',
      'totalPendingRequests',
      'totalMembers',
    ]) {
      final uses = RegExp('overview\\.$field').allMatches(src).length;
      expect(
        uses,
        lessThanOrEqualTo(1),
        reason:
            '$field is read $uses times on one screen — state it once, or the '
            'screen is telling the reader the same thing in several voices',
      );
    }
  });
}
