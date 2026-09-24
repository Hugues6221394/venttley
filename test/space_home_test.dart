import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/theme/colors.dart';
import 'package:vently_app/presentation/screens/tribes/space_home_screen.dart';

/// A Space that says whether it is open.
///
/// A keeper can set a Space read-only, restrict it to mods or to themselves,
/// and schedule it to open on Monday and shut on Friday. All four were
/// enforced by the guard trigger on posts, and none of them was visible: the
/// screen drew "Start a Vent" regardless, so the way anybody learned a Space
/// was closed was writing a vent and having the insert throw
/// space_is_read_only at them.

Space _space({
  String permission = 'members',
  DateTime? archivedAt,
  DateTime? activatesAt,
  DateTime? deactivatesAt,
  String? themeColor,
}) => Space(
  spaceId: 's1',
  tribeId: 't1',
  tribeSlug: 'quiet-tribe',
  tribeName: 'Quiet Tribe',
  slug: 'open',
  name: 'Open Room',
  isDefault: false,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  ventCount: 0,
  ventsToday: 0,
  postingPermission: permission,
  archivedAt: archivedAt,
  activatesAt: activatesAt,
  deactivatesAt: deactivatesAt,
  themeColor: themeColor,
);

Future<void> _pump(
  WidgetTester tester, {
  required Space space,
  required String state,
  List<Post> posts = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        spaceByIdProvider('s1').overrideWith((ref) async => space),
        spacePostingStateProvider('s1').overrideWith((ref) async => state),
        spaceSummaryProvider('s1').overrideWith((ref) async => null),
        for (final sort in const [
          'fresh',
          'trending',
          'helpful',
          'unanswered',
          'keeper',
        ])
          spacePostsProvider(
            SpaceFeedQuery(spaceId: 's1', sort: sort),
          ).overrideWith((ref) async => posts),
      ],
      child: MaterialApp(
        theme: VentlyTheme.dark(pureBlack: true),
        home: const SpaceHomeScreen(spaceId: 's1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Post _post(String id, String content, String who) => Post(
  postId: id,
  authorId: 'u1',
  authorPseudonym: who,
  authorAvatarSeed: 'seed',
  categoryName: 'support',
  postType: 'user_post',
  content: content,
  postMood: 'hopeful',
  likesCount: 0,
  commentsCount: 0,
  createdAt: DateTime(2026, 2, 1),
);

void main() {
  testWidgets('an open Space offers the button', (tester) async {
    await _pump(tester, space: _space(), state: 'open');
    expect(find.text('Start a Vent'), findsOneWidget);
  });

  testWidgets('a read-only Space says so instead', (tester) async {
    await _pump(
      tester,
      space: _space(permission: 'read_only'),
      state: 'read_only',
    );
    expect(find.text('Start a Vent'), findsNothing);
    expect(find.textContaining('for reading'), findsOneWidget);
  });

  testWidgets('a keeper-only Space names who posts in it', (tester) async {
    await _pump(
      tester,
      space: _space(permission: 'keeper'),
      state: 'keeper_only',
    );
    expect(find.text('Only the Keeper posts in this Space.'), findsOneWidget);
  });

  testWidgets('a Space that has not opened gives the date', (tester) async {
    await _pump(
      tester,
      space: _space(activatesAt: DateTime(2026, 3, 9, 12)),
      state: 'not_open_yet',
    );
    expect(find.textContaining('opens on 9 March'), findsOneWidget);
  });

  testWidgets('an archived Space says you can still read it', (tester) async {
    await _pump(
      tester,
      space: _space(archivedAt: DateTime(2026, 2, 1)),
      state: 'archived',
    );
    expect(find.textContaining('still read it'), findsOneWidget);
  });

  testWidgets('somebody outside the tribe is pointed at joining', (
    tester,
  ) async {
    // A different answer from the closed states, because the next step is a
    // different screen.
    await _pump(tester, space: _space(), state: 'not_a_member');
    expect(find.text('Join the Tribe to vent here.'), findsOneWidget);
  });

  testWidgets('the search box replaces the apology', (tester) async {
    // The button used to answer "Space search is coming next."
    await _pump(tester, space: _space(), state: 'open');
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.textContaining('coming next'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Open Room'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  test('searching a Space matches content and author', () {
    // Tested as a function rather than through the list, because PostCard
    // reads Supabase directly and cannot be built under flutter test — so
    // driving the real list would be testing the card, not the filter.
    final posts = [
      _post('p1', 'I could not sleep again', 'nightowl'),
      _post('p2', 'Exams are going fine actually', 'sunnyday'),
    ];

    expect(ventsMatching(posts, '').length, 2, reason: 'empty shows all');
    expect(ventsMatching(posts, 'sleep').single.postId, 'p1');
    expect(
      ventsMatching(posts, 'SLEEP').single.postId,
      'p1',
      reason: 'nobody types their search in the right case',
    );
    expect(
      ventsMatching(posts, 'sunny').single.postId,
      'p2',
      reason: 'the author is worth matching too',
    );
    expect(ventsMatching(posts, 'zzzz'), isEmpty);
  });

  test('a malformed accent colour falls back instead of throwing', () {
    // int.parse(value.replaceFirst('#', '0xff')) was inlined at three call
    // sites, all inside build, none guarded — so one bad row took the screen
    // down rather than the colour.
    const fallback = VentlyColors.berryMagenta;
    expect(parseAccent('#112233', fallback), const Color(0xFF112233));
    expect(parseAccent(null, fallback), fallback);
    expect(parseAccent('rebeccapurple', fallback), fallback);
    expect(parseAccent('#abc', fallback), fallback);
    expect(parseAccent('#gggggg', fallback), fallback);
  });
}
