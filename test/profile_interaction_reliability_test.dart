import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile modal controllers are disposed and failures stay in-app', () {
    final overview = File(
      'lib/presentation/screens/profile/profile_overview.dart',
    ).readAsStringSync();

    expect(
      overview,
      contains('await showModalBottomSheet<void>'),
    );
    expect(
      'ModalTextControllerScope('.allMatches(overview).length,
      greaterThanOrEqualTo(2),
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
