import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Nothing in the app prints an exception at a person.
///
/// WHY THIS EXISTS
///
/// "Continue with email" showed a stranger this, on the screen where they were
/// deciding whether to trust Venttly with an account:
///
///   AuthWeakPasswordException(message: Password should be at least 12
///   characters., statusCode: 422, reasons: [length])
///
/// and, when the handle was already taken, this:
///
///   AuthRetryableFetchException(message: {"code":"unexpected_failure",
///   "message":"Database error saving new user"}, statusCode: 500)
///
/// Neither was a one-off. Ninety-two places across thirty-nine files
/// interpolated a caught error straight into a SnackBar or a Text, because
/// `Text('Could not save: $e')` is the shortest thing to type and reads fine
/// in review -- the damage is only visible once a real backend fails.
///
/// UserFriendlyErrors exists to turn those into sentences, so the rule is not
/// "write better copy" but "route it through the mapper", which this asserts
/// mechanically. It reads source rather than rendering screens because the
/// failures are spread across the whole presentation layer and most need a
/// live backend error to reproduce -- a widget test per screen would be a
/// hundred tests that each prove less than one grep.
void main() {
  final dartFiles = Directory('lib/presentation')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('presentation code exists to scan', () {
    // Guards the guard: a bad path here would make every test below pass by
    // scanning nothing.
    expect(dartFiles.length, greaterThan(50));
  });

  test('no screen interpolates a caught error into what it shows', () {
    // `$e`, `${e}`, `$error`, `$err` inside a Text(...) on one line. The
    // offenders were all written this way; a multi-line one would read
    // differently enough to notice in review.
    final offender = RegExp(r'Text\([^)]*\$\{?(e|error|err)\b');
    final found = <String>[];

    for (final file in dartFiles) {
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (offender.hasMatch(lines[i])) {
          found.add('${file.path}:${i + 1}  ${lines[i].trim()}');
        }
      }
    }

    expect(
      found,
      isEmpty,
      reason:
          'These show a raw exception to a person. Wrap them:\n'
          '  Text(UserFriendlyErrors.message(e, fallback: \'Could not …\'))\n\n'
          '${found.join('\n')}',
    );
  });

  test('no screen assigns a raw error to the string it displays', () {
    // The other shape the signup form used: stash `e.toString()` in state,
    // render it later. AgeGateBlocked and friends are exempt by name -- their
    // toString *is* the copy, written to be read.
    // The `;` matters: `_error = e.toString().contains(...) ? … : …` is a
    // decision about the error, not a display of it, and policy_consent_screen
    // legitimately does exactly that before handing the rest to the mapper.
    final offender = RegExp(
      r'_(error|err|errorText|message)\s*=\s*(e|error|err)\.toString\(\)\s*;',
    );
    final found = <String>[];

    for (final file in dartFiles) {
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (offender.hasMatch(lines[i])) {
          found.add('${file.path}:${i + 1}  ${lines[i].trim()}');
        }
      }
    }

    expect(
      found,
      isEmpty,
      reason:
          'These store a raw exception for display. Use '
          'UserFriendlyErrors.message(e, fallback: …):\n\n${found.join('\n')}',
    );
  });

  test('both signup doors answer the handle question while it is typed', () {
    // The anonymous form has checked availability as you type for a while.
    // The email form did not, so the first word that a handle was gone was a
    // 500 after the whole form was filled in -- and the 500 says "Database
    // error saving new user", which mentions neither handles nor what to do.
    final identity = File(
      'lib/presentation/screens/onboarding/identity_screen.dart',
    ).readAsStringSync();
    final email = File(
      'lib/presentation/screens/onboarding/email_signup_screen.dart',
    ).readAsStringSync();

    for (final source in [identity, email]) {
      expect(source, contains('usernameAvailabilityProvider'));
      expect(source, contains('UsernameAvailabilityHint'));
    }
  });

  test('the email form will not submit a handle known to be taken', () {
    final email = File(
      'lib/presentation/screens/onboarding/email_signup_screen.dart',
    ).readAsStringSync();
    expect(email, contains('UsernameStatus.taken'));
    expect(email, contains('handleTaken'));
    // But a failed lookup must not block: that would lock somebody out of
    // signing up over a name that is probably free.
    expect(email, isNot(contains('UsernameStatus.unknown')));
  });
}
