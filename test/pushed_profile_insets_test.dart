import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Profile is unresponsive from the Keeper Studio, fine from the member feed."
///
/// One screen, two entry points. As a tab it has a zero-height app bar, so
/// nothing floats over it. Pushed from the Studio it gets a real app bar for
/// the back chip — and the Scaffold sets extendBodyBehindAppBar, so that bar
/// does not push the body down, it sits on top of it. The hero rendered under
/// the notch, and the transparent bar swallowed every touch in the first
/// kToolbarHeight of the scroll view. Wrong-looking and dead to the finger.
///
/// A source check rather than a pumped one: ProfileScreen pulls session,
/// vents, whispers and tribes, and a test that fakes four providers to measure
/// one SizedBox would fail for reasons that have nothing to do with the inset.
/// The two facts below are what makes the bug, so the two facts are what is
/// pinned.
void main() {
  test('a pushed profile clears the bar that floats over it', () {
    final src = File(
      'lib/presentation/screens/profile/profile_screen.dart',
    ).readAsStringSync();

    expect(
      src,
      contains('extendBodyBehindAppBar: true'),
      reason:
          'if this goes, the inset below is double-counting and the profile '
          'gains a band of dead space instead',
    );
    expect(
      src,
      contains('(widget.showBackButton ? kToolbarHeight : 0)'),
      reason:
          'the pushed profile must reserve the app bar it is rendering behind, '
          'or its header sits under the bar and under the notch',
    );
  });
}
