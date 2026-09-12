import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The badge that blanked Manage Tribe.
///
/// `_ManagementTile` put a badge in `ListTile.trailing` as a Container with
/// `alignment: Alignment.center` and no width bound. A Container with an
/// alignment wraps its child in an Align, and an Align with no widthFactor
/// expands to the biggest size its constraints allow. ListTile lays trailing
/// out with LOOSE constraints — 0 to the full tile width — so the badge took
/// the whole tile and ListTile threw inside performLayout:
///
///   Trailing widget consumes the entire tile width (including
///   ListTile.contentPadding).
///
/// Throwing during layout leaves the subtree unlaid-out. On device that
/// cascaded into "RenderBox was not laid out" seventeen levels up, a null
/// check on a null value, and then '!semantics.parentDataDirty' repeating for
/// as long as the screen stayed open. The keeper saw a blank white page.
///
/// What made it survive so long is the trigger: the badge is
/// pendingJoinRequests and openReports, so the screen worked perfectly until
/// there was something to manage and broke the moment a report or join request
/// arrived. Two Tribes side by side — one with 1 open report, one with 0 — the
/// first blank, the second fine.
///
/// These tests are geometric, not visual: they reproduce ListTile's loose
/// trailing constraints and assert the tile lays out.
void main() {
  /// The badge exactly as the tile builds it.
  Widget badge(int count) => Container(
    constraints: const BoxConstraints(
      minWidth: 24,
      maxWidth: 46,
      minHeight: 24,
      maxHeight: 24,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFFD81B60),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      count > 99 ? '99+' : '$count',
      maxLines: 1,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.w900,
      ),
    ),
  );

  Future<void> pumpTile(WidgetTester tester, Widget trailing) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // The width the real tile gets: a 402pt phone less the section's
            // 20pt padding on each side.
            child: SizedBox(
              width: 362,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                leading: const SizedBox(width: 36, height: 36),
                title: const Text('Members and requests'),
                subtitle: const Text('3 members · 1 waiting'),
                trailing: trailing,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final count in [1, 9, 12, 99, 100, 4821]) {
    testWidgets('a badge of $count lays out instead of blanking the screen', (
      tester,
    ) async {
      await pumpTile(tester, badge(count));

      // The assertion fired during performLayout, so a failure surfaces here.
      expect(tester.takeException(), isNull);

      // And the tile is actually on screen at its real width, not collapsed.
      expect(find.text('Members and requests'), findsOneWidget);
      expect(tester.getSize(find.byType(ListTile)).width, 362);

      // The badge stays a badge on BOTH axes. Align expands in whichever
      // direction its constraints allow, so bounding only the width left a
      // pill stretched to the full height of the tile — the crash was gone and
      // the shape was still wrong.
      final size = tester.getSize(find.byType(Container));
      expect(size.width, lessThanOrEqualTo(46));
      expect(size.width, greaterThanOrEqualTo(24));
      expect(size.height, 24);
    });
  }

  testWidgets('an unbounded alignment badge is what broke it', (tester) async {
    // The bug itself, pinned. If this ever stops throwing, Flutter changed the
    // rule and the comment above needs revisiting — but while it does throw,
    // it is the proof that maxWidth is what fixes it rather than a coincidence.
    //
    // Errors are collected through FlutterError.onError rather than
    // takeException(), because one bad badge does not raise one error: it
    // raises a cascade, and takeException() then returns a "Multiple
    // exceptions were detected" summary instead of the error that started it.
    // That cascade is the whole mechanism by which a 24-pixel badge turned
    // into a blank page, so it is worth asserting directly.
    final errors = <FlutterErrorDetails>[];
    final prior = FlutterError.onError;
    FlutterError.onError = errors.add;
    await pumpTile(
      tester,
      Container(
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        child: const Text('1'),
      ),
    );
    FlutterError.onError = prior;

    expect(
      errors.first.exceptionAsString(),
      contains('Trailing widget consumes the entire tile width'),
    );
    // One layout throw, many casualties: this is why the screen went blank
    // rather than showing a broken row.
    expect(
      errors.length,
      greaterThan(1),
      reason: 'the layout failure should cascade through the subtree',
    );
    expect(
      errors.any((e) => e.exceptionAsString().contains('was not laid out')),
      isTrue,
    );

    tester.takeException();
  });

  testWidgets('a large count is capped rather than overflowing its box', (
    tester,
  ) async {
    await pumpTile(tester, badge(4821));
    expect(find.text('99+'), findsOneWidget);
    expect(find.text('4821'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
