import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Snackbars that offer an action, and used to stay forever.
///
/// Reported from the inbox: archive a chat and "Archived. Undo" never leaves.
/// It is not a race and not a stuck timer — it is the default:
///
/// ```dart
/// // flutter/lib/src/material/snack_bar.dart
/// persist = persist ?? action != null;
/// ```
///
/// A SnackBar carrying a SnackBarAction persists until somebody taps the
/// action or a close icon. The dismissal timer does fire; it reads `persist`
/// and returns without hiding. So every "Undo" and "Open chat" bar in the app
/// sat on screen over whatever the person did next, and the only offered way
/// out of it was to undo the thing they had just chosen to do.
void main() {
  testWidgets('a bar with an action stays up unless persist is false', (
    tester,
  ) async {
    // The default, held here so the reason for every `persist: false` in lib/
    // is legible without going to read the framework.
    await _pumpBar(
      tester,
      SnackBar(
        content: const Text('Archived.'),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ),
    );

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('Archived.'), findsOneWidget);
  });

  testWidgets('and leaves on its own when it is', (tester) async {
    await _pumpBar(
      tester,
      SnackBar(
        content: const Text('Archived.'),
        persist: false,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ),
    );

    expect(find.text('Archived.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(
      find.text('Archived.'),
      findsOneWidget,
      reason: 'six seconds, because an offer to undo is worth reading twice',
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Archived.'), findsNothing);
  });

  test('no snackbar in the app offers an action and forgets to say so', () {
    // A source scan rather than a widget test, because the fault is invisible
    // until somebody sits and watches a bar for a minute, and it comes back
    // every time anybody adds an Undo.
    final offenders = <String>[];

    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();

      for (final match in RegExp(r'SnackBar\(').allMatches(source)) {
        // The constructor's own arguments: everything up to its closing paren.
        var depth = 1;
        var i = match.end;
        while (i < source.length && depth > 0) {
          if (source[i] == '(') depth++;
          if (source[i] == ')') depth--;
          i++;
        }
        final arguments = source.substring(match.end, i);
        if (!arguments.contains('SnackBarAction(')) continue;
        if (arguments.contains('persist:')) continue;

        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${file.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these snackbars offer an action, so they will stay on screen until '
          'it is tapped. Add `persist: false` unless that is genuinely wanted:'
          '\n  ${offenders.join('\n  ')}',
    );
  });
}

Future<void> _pumpBar(WidgetTester tester, SnackBar bar) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(bar),
            child: const Text('Archive'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Archive'));
  await tester.pumpAndSettle();
}
