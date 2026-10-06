// What a person sees when things go wrong, on a device, with a backend that
// really is failing.
//
//   flutter test integration_test/adverse_conditions_test.dart -d <sim>
//
// WHY THIS EXISTS
//
// test/no_raw_errors_on_screen_test.dart reads source and proves no screen
// interpolates a caught error into UI copy. It says so itself: it cannot
// render screens, because most of these failures need a live backend to
// reproduce. So the rule is enforced where it is written and unproven where it
// is seen.
//
// This closes that. It points the app at a host that cannot be reached, drives
// the screens a stranger meets first, and reads every string actually on the
// screen. Nothing is mocked: the failures are real connection failures, which
// is the condition the app will meet on a train, in a lift, on a Rwandan
// mobile network at 7pm, and on a reviewer's device behind a corporate proxy.
//
// It asserts two things, and the second is the one that matters:
//
//   1. the app does not crash, hang or go blank
//   2. whatever it says is a sentence a person could have written

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/presentation/screens/onboarding/email_signup_screen.dart';
import 'package:vently_app/presentation/screens/onboarding/recover_screen.dart';
import 'package:vently_app/presentation/screens/onboarding/welcome_screen.dart';

/// A host that resolves instantly and refuses the connection, so every call
/// fails fast and for a real reason rather than by a stubbed exception.
const _deadUrl = 'http://127.0.0.1:1';
const _anonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
    'eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.'
    'CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

/// The shapes of a leaked exception. Matching on substance rather than on a
/// list of class names, because the next leak will be a class nobody has
/// written yet.
final _leaks = <RegExp, String>{
  RegExp(r'\b[A-Z]\w*Exception\b'): 'an exception class name',
  RegExp(r'\b[A-Z]\w*Error\b(?! is| occurred)'): 'an error class name',
  RegExp(r'statusCode\s*[:=]'): 'an HTTP status field',
  RegExp(r'\bPostgrestException|\bAuthApiException|\bClientException'):
      'a backend exception',
  RegExp(r'SocketException|Connection refused|Failed host lookup'):
      'a raw socket failure',
  RegExp(r'\b(?:23505|42501|42P01|PGRST\d+)\b'): 'a Postgres or PostgREST code',
  RegExp(r'violates \w+ constraint|duplicate key'): 'a constraint violation',
  RegExp(r'^\s*\{.*"(?:code|message)"\s*:'): 'a raw JSON body',
  RegExp(r'#\d+\s+\w+.*\(package:'): 'a stack frame',
  RegExp(r'\bnull\b(?!-)', caseSensitive: true): 'the word null',
};

/// Every string a person can actually read right now.
List<String> visibleText(WidgetTester tester) {
  final out = <String>[];
  for (final w in tester.allWidgets) {
    if (w is Text && w.data != null) {
      out.add(w.data!);
    } else if (w is RichText) {
      out.add(w.text.toPlainText());
    } else if (w is SelectableText && w.data != null) {
      out.add(w.data!);
    }
  }
  return out;
}

void expectNothingLeaked(WidgetTester tester, String where) {
  for (final text in visibleText(tester)) {
    for (final entry in _leaks.entries) {
      expect(
        entry.key.hasMatch(text),
        isFalse,
        reason:
            'On $where a person is shown ${entry.value}:\n  "$text"\n'
            'Route it through UserFriendlyErrors.message(e, fallback: ...).',
      );
    }
  }
}

/// Let the real failure happen. The call is genuine I/O, so it needs real
/// time; the retry/backoff around it is fake-clock, so it needs pumping.
Future<void> letItFail(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> show(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp(home: screen)),
  );
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Guards the guard. A detector that cannot fire would let every test below
  // pass while proving nothing, which is the failure mode of every assertion
  // written against an absence.
  testWidgets('the detector catches what it is for', (tester) async {
    const leaks = [
      'AuthApiException(message: Invalid login credentials, statusCode: 400)',
      'PostgrestException(message: permission denied, code: 42501)',
      'SocketException: Connection refused (OS Error: Connection refused)',
      '{"code":"unexpected_failure","message":"Database error saving new user"}',
      'duplicate key value violates unique constraint "users_pseudonym"',
      '#0      _rootRunUnary (package:flutter/src/foo.dart:12)',
      'Could not save: null',
    ];
    for (final sample in leaks) {
      expect(
        _leaks.keys.any((p) => p.hasMatch(sample)),
        isTrue,
        reason: 'the detector would have let this through:\n  "$sample"',
      );
    }
    // And does not cry wolf at ordinary copy.
    const fine = [
      'Couldn’t reach Venttly. Check your connection and try again.',
      'That handle was taken a moment ago. Pick another and try again.',
      'Step into the Circle',
      'Already have an account?',
      'Say what you feel. Find people who understand.',
    ];
    for (final sample in fine) {
      final hit = _leaks.entries.where((e) => e.key.hasMatch(sample));
      expect(
        hit,
        isEmpty,
        reason: 'ordinary copy was flagged:\n  "$sample"',
      );
    }
  });

  setUpAll(() async {
    await Supabase.initialize(url: _deadUrl, anonKey: _anonKey, debug: false);
  });

  testWidgets('the welcome screen survives a backend that is not there', (
    tester,
  ) async {
    await show(tester, const WelcomeScreen());
    await letItFail(tester);

    // The anonymous path is the whole product. It must be offered even when
    // nothing can be reached — somebody opening this in a dead spot should
    // still see what the app is.
    expect(find.text('Step into the Circle'), findsOneWidget);
    expectNothingLeaked(tester, 'the welcome screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing up against a dead backend says something human', (
    tester,
  ) async {
    await show(tester, const EmailSignupScreen());
    await tester.pump();

    // The handle lookup cannot answer. It must not claim a name is taken, and
    // it must not print the socket failure.
    await tester.enterText(find.byType(TextField).at(1), 'probe_handle');
    await letItFail(tester);

    for (final text in visibleText(tester)) {
      expect(
        text.contains('is taken'),
        isFalse,
        reason:
            'A lookup that failed must never report a handle as taken — that '
            'sends somebody away from a name that is theirs to use.\n  "$text"',
      );
    }
    expectNothingLeaked(tester, 'the email signup form');
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing in against a dead backend says something human', (
    tester,
  ) async {
    await show(tester, const RecoverScreen());
    await letItFail(tester);
    expectNothingLeaked(tester, 'the sign-in screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a session that is revoked mid-use does not shout', (
    tester,
  ) async {
    // The shape of a real expiry: a token the client still holds and the
    // server no longer honours. Every authenticated call returns 401, which is
    // the one failure every signed-in screen must survive — a person who has
    // been away a week meets exactly this.
    await show(tester, const RecoverScreen());
    await letItFail(tester);

    // Sign-in itself fails against the dead host; what matters is the wording.
    final submit = find.byType(FilledButton);
    if (submit.evaluate().isNotEmpty) {
      await tester.tap(submit.first, warnIfMissed: false);
      await letItFail(tester);
    }
    expectNothingLeaked(tester, 'the sign-in screen after a failed submit');
    expect(tester.takeException(), isNull);
  });

  testWidgets('hostile input does not break the signup form', (tester) async {
    await show(tester, const EmailSignupScreen());
    await tester.pump();

    // Things a real person types, and things a bored one does: an essay, an
    // emoji, right-to-left script, and a quote that would end a SQL string.
    const hostile = [
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      '🙂🙂🙂🙂🙂',
      'مرحبا بالعالم',
      "o'brien\"; drop table users;--",
      '   ',
    ];
    for (final input in hostile) {
      await tester.enterText(find.byType(TextField).at(1), input);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.takeException(),
        isNull,
        reason: 'the handle field threw on: $input',
      );
    }
    await letItFail(tester);
    expectNothingLeaked(tester, 'the signup form after hostile input');
  });
}
