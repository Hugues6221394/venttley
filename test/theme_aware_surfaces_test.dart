import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screens written light-first, found one at a time.
///
/// The shape is always identical: a hardcoded white surface — `Colors.white`
/// as a BoxDecoration fill, a Material colour, or an input fillColor — with
/// `context.ink` drawn on it. `context.ink` is an off-white on the dark
/// themes, so the card comes out white-on-white: perfect in light, invisible
/// in dark.
///
/// It was the welcome trust panel, then the story composer, then Discover and
/// the whisper composer. Each was reported separately as "this looks faint",
/// and each needed the same one-line answer, because nobody was checking.
///
/// This checks. It is scoped to the screens that have been swept rather than
/// to all of lib/presentation, because a hardcoded white is *correct* in
/// plenty of places — on artwork, on a black scrim, on a berry fill, and
/// throughout the immersive whisper player, where the surface is the same
/// colour whatever theme the app is in. A blanket ban would be wrong and
/// would get switched off. This list grows as the sweep does.
const _swept = <String>[
  'lib/presentation/screens/discover/discover_screen.dart',
  'lib/presentation/screens/whispers/create_whisper_screen.dart',
  'lib/presentation/screens/compose/create_story_screen.dart',
  'lib/presentation/screens/onboarding/welcome_screen.dart',
];

void main() {
  test('swept screens do not paint surfaces white by hand', () {
    final offenders = <String>[];

    for (final path in _swept) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path has moved or gone');
      final lines = file.readAsStringSync().split('\n');

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();

        // A fill, not a foreground: the line that opens a decoration, or an
        // input's fill. Text and icons name their colour inside TextStyle(…)
        // and Icon(…), which this deliberately does not match.
        final isFill =
            line == 'color: Colors.white,' &&
            _previousCode(lines, i).endsWith('BoxDecoration(');
        final isInputFill = line.startsWith('fillColor: Colors.white');
        final isMaterial = line.startsWith('color: Colors.white') &&
            _previousCode(lines, i).endsWith('Material(');

        if (isFill || isInputFill || isMaterial) {
          offenders.add('$path:${i + 1}  ${lines[i].trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these paint a surface white regardless of theme, and the ink drawn '
          'on them comes from the theme — which is white-on-white in dark:\n'
          '${offenders.join('\n')}',
    );
  });
}

/// The last line above [i] that is not blank and not a comment.
String _previousCode(List<String> lines, int i) {
  for (var j = i - 1; j >= 0; j--) {
    final line = lines[j].trim();
    if (line.isEmpty || line.startsWith('//')) continue;
    return line;
  }
  return '';
}
