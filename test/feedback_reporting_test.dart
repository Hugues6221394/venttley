import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reporting a bug or asking for a feature.
///
/// There was no in-app route for either. Somebody who hit a bug could open a
/// support case — a moderation surface, read by moderators, routing to nothing
/// that fixes software — or say nothing. Most say nothing, so the reports that
/// matter most, from the people who hit them first, never arrived.
///
/// The server rules are covered by pgTAP (0048). These are the three things
/// about the client that would otherwise be easy to lose.
void main() {
  final screen = File(
    'lib/presentation/screens/settings/feedback_screen.dart',
  ).readAsStringSync();
  final router = File(
    'lib/presentation/router/app_router.dart',
  ).readAsStringSync();
  final settings = File(
    'lib/presentation/screens/settings/settings_screen.dart',
  ).readAsStringSync();

  test('it is reachable, and from the place people look', () {
    expect(router, contains("path: '/settings/feedback'"));
    expect(
      settings,
      contains("context.push('/settings/feedback')"),
      reason: 'a screen nobody can find is the same as no screen',
    );
  });

  test('the build and device are attached without asking', () {
    // A bug report you cannot reproduce is barely a bug report, and nobody
    // types their build number correctly.
    expect(screen, contains('PackageInfo.fromPlatform()'));
    expect(screen, contains('Platform.operatingSystem'));
    expect(
      screen,
      contains('appVersion: version'),
      reason: 'gathering the version and not sending it is worse than neither',
    );
  });

  test('both kinds are offered, and the reporter can see what happened', () {
    expect(screen, contains("value: 'bug'"));
    expect(screen, contains("value: 'suggestion'"));

    // Status alone is a word with no consequence attached. The staff note is
    // the only reply anybody gets, so it is shown verbatim when present.
    expect(screen, contains('myFeedbackProvider'));
    expect(screen, contains('report.staffNote'));
  });
}
