import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile modal controllers are disposed and failures stay in-app', () {
    final overview = File(
      'lib/presentation/screens/profile/profile_overview.dart',
    ).readAsStringSync();

    // One, not two. This asked for at least two ModalTextControllerScope
    // wrappers, because the profile had two sheets with text fields in them:
    // the persona creator, and an apply-for-verification box.
    //
    // The verification sheet is gone on purpose — the pill now opens the full
    // application form, which is a route rather than a sheet. What this test
    // is actually about is that a sheet with a controller in it disposes that
    // controller, so it should count the sheets that exist rather than a
    // number that happened to be right once.
    expect(
      overview,
      contains('showModalBottomSheet<'),
      reason: 'the persona sheet is gone too, which this test cannot see',
    );
    expect(
      'ModalTextControllerScope('.allMatches(overview).length,
      greaterThanOrEqualTo(1),
    );
    expect(
      overview,
      contains("Couldn\\'t create that persona. Please try again."),
    );
  });

  test('profile data failures are not rendered as genuine empty states', () {
    final profile = File(
      'lib/presentation/screens/profile/profile_screen.dart',
    ).readAsStringSync();

    expect(profile, contains('myVentsAsync.when('));
    expect(profile, contains('myWhispersAsync.when('));
    expect(profile, contains("Couldn't load your vents."));
    expect(profile, contains("Couldn't load your whispers."));
    expect(profile, contains("Couldn't load your media."));
    expect(profile, contains("Couldn't load your saved posts."));
    expect(profile, contains('class _ProfileLoading'));
  });
}
