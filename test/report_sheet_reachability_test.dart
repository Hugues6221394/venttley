import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/widgets/report_reason_sheet.dart';

/// Every report reason has to be reachable, on the smallest phone we support.
///
/// `openReportPostSheet` in post_card.dart built its own sheet: a plain Column
/// of eight ListTiles in a showModalBottomSheet with no isScrollControlled and
/// nothing scrollable inside. On a 402x874 device it overflowed by 198 pixels,
/// so "Spam or scam" and "Something else" sat below the bottom edge with no
/// way to scroll to them. Found on device while reporting a vent.
///
/// The part worth remembering is why the existing coverage missed it. There
/// was already a test called "report reasons remain usable on a compact phone"
/// — it exercised `showReportReasonSheet`, the shared helper, which handles
/// this correctly and is used by both chats, group settings and chat options.
/// post_card was the one caller that had rolled its own, so the helper was
/// tested and the screen was not.
///
/// So this file tests the property at both levels: the helper behaves, and no
/// caller quietly reimplements it.
void main() {
  testWidgets('every reason can be reached on a small screen', (tester) async {
    tester.view.physicalSize = const Size(402, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                chosen = await showReportReasonSheet(
                  context,
                  title: 'Report this post',
                );
              },
              child: const Text('Report'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    expect(find.text('Report this post'), findsOneWidget);

    // The first reason is self-harm, deliberately, and it must be visible
    // without any scrolling at all.
    expect(find.text('Self-harm or suicide concern'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // And the last one is reachable rather than clipped. This is the exact
    // assertion the old sheet failed: it rendered them, off the bottom, with
    // no scrollable to bring them up.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Something else'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Something else'));
    await tester.pumpAndSettle();
    expect(
      chosen,
      'other',
      reason: 'the chosen key must reach the caller, not just close the sheet',
    );
  });

  test('report sheets go through the shared helper', () {
    // The rule the bug broke. A second hand-built reason list is not only a
    // layout risk — kReportReasons documents itself as matching the CHECK on
    // reports.reason, and post_card's copy had already drifted into a
    // different order.
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.endsWith('report_reason_sheet.dart')) continue;
      final src = file.readAsStringSync();
      // A local list of report reason keys is the fingerprint of a copy.
      if (src.contains("('self_harm'") && src.contains("('harassment'")) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'These build their own report reasons instead of calling '
          'showReportReasonSheet, which is how one of them ended up '
          'unscrollable:\n  ${offenders.join('\n  ')}',
    );
  });
}
