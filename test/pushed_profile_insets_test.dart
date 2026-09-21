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
  test('the pushed profile has no bar to float over it', () {
    final src = File(
      'lib/presentation/screens/profile/profile_screen.dart',
    ).readAsStringSync();

    // Zero height unconditionally. A real bar here meant two bugs at once:
    // with extendBodyBehindAppBar it floated over the scroll view and ate the
    // touches in its band, and reserving room for it pushed the hero a third
    // of the way down an empty screen.
    expect(
      src,
      contains('toolbarHeight: 0'),
      reason: 'a real app bar here floats over the scroll view and eats taps',
    );
    expect(
      src,
      isNot(contains('toolbarHeight: widget.showBackButton')),
      reason: 'the two entry points must not disagree about the bar',
    );

    // One inset, the status bar, so the hero starts in the same place however
    // you arrived at the screen.
    expect(
      src,
      contains('SizedBox(height: MediaQuery.of(ctx).padding.top + 8)'),
      reason: 'the pushed profile should start where the tab profile starts',
    );

    // And the back affordance survived the bar being removed.
    expect(src, contains('if (widget.showBackButton)'));
    expect(src, contains('Icons.arrow_back_rounded'));
  });
}
