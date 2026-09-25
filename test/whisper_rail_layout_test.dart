import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The rail beside a whisper, and the player it used to sit on top of.
///
/// Photographed on a Pixel 8a: the player ran the full width of the page while
/// the action rail floated over its right edge, so "Share" printed across the
/// clip's duration — "0:4Share" — and "Save" and "More" sat on the caption.
/// Three of the five buttons printed a word and two printed a number, which
/// read as a list of labels with two stray figures in it.
///
/// Both are layout decisions rather than behaviour, so this is a source test:
/// it holds the two constants that keep them apart and the shape of the
/// button, and it costs nothing to run.
void main() {
  test('the content column reserves the rail its own width', () {
    final source = File(
      'lib/presentation/screens/whispers/whispers_screen.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('const double _railInset = 72'),
      reason: 'the rail is 44 wide at right: 12, so 72 clears it with air',
    );
    expect(
      source,
      contains('EdgeInsets.fromLTRB(20, 70, _railInset, 28)'),
      reason:
          'the player and the caption are padded off the rail rather than '
          'painted underneath it',
    );
  });

  test('a rail button prints a count and speaks its action', () {
    // Reaching the private widget through the screen would need a whole feed;
    // what matters here is the rule it now follows, which is stated in one
    // place: a count is drawn, an action is announced.
    final source = File(
      'lib/presentation/screens/whispers/whispers_screen.dart',
    ).readAsStringSync();

    expect(source, contains('if (count != null) ...['));
    expect(
      source,
      contains("label: count == null ? action : '\$action, \$count'"),
      reason: 'the word still reaches anybody using a screen reader',
    );
    expect(
      source,
      isNot(contains("label: 'Share'")),
      reason: 'the words under Share, Save and More are gone from the page',
    );
  });
}
