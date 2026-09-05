import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/presentation/screens/onboarding/password_reset_screen.dart';

/// Resetting a password with a recovery email is an unauthenticated path to
/// taking over an account, so the screen's job is as much about what it refuses
/// to say as about what it does. These tests pin both.
class _FakeRepository extends VentlyRepository {
  _FakeRepository({this.failure}) : super(forceMock: true);

  /// What confirmPasswordReset should report back.
  final String? failure;

  final List<String> requested = <String>[];
  final List<Map<String, String>> confirmed = <Map<String, String>>[];

  @override
  Future<Set<String>> weakPasswordBases() async => {'password', 'venttly'};

  @override
  Future<void> requestPasswordReset(String identifier) async {
    requested.add(identifier);
  }

  @override
  Future<String?> confirmPasswordReset({
    required String identifier,
    required String code,
    required String newPassword,
  }) async {
    confirmed.add({
      'identifier': identifier,
      'code': code,
      'password': newPassword,
    });
    return failure;
  }
}

/// A real router, because the success path navigates back to sign-in and a
/// bare MaterialApp would make that throw — hiding whether the reset itself
/// worked behind a harness problem.
Future<_FakeRepository> pump(
  WidgetTester tester, {
  String? failure,
}) async {
  final repo = _FakeRepository(failure: failure);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const PasswordResetScreen()),
      GoRoute(
        path: '/onboarding/recover',
        builder: (_, __) => const Scaffold(body: Text('sign in')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  return repo;
}

Future<void> enterInto(WidgetTester tester, String label, String value) async {
  await tester.enterText(
    find.widgetWithText(TextField, label).first,
    value,
  );
  await tester.pump();
}

void main() {
  testWidgets('an empty identifier is refused before anything is sent', (
    tester,
  ) async {
    final repo = await pump(tester);

    await tester.tap(find.text('Send me a code'));
    await tester.pump();

    expect(find.text('Enter your email or your username.'), findsOneWidget);
    expect(
      repo.requested,
      isEmpty,
      reason: 'nothing should reach the server for an empty box',
    );
  });

  testWidgets('the confirmation never claims the account exists', (
    tester,
  ) async {
    // The whole point. If this screen said "we sent a code to your email" it
    // would confirm that the address or handle has a Venttly account, and
    // anyone could test any address. It must stay conditional.
    final repo = await pump(tester);

    await enterInto(tester, 'Email or username', 'someone@example.com');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();

    expect(repo.requested, ['someone@example.com']);
    expect(
      find.textContaining('If that account has a verified recovery email'),
      findsOneWidget,
    );
    // Nothing anywhere may assert the account is real.
    expect(find.textContaining('We sent a code to your'), findsNothing);
  });

  testWidgets('a short code does not advance', (tester) async {
    await pump(tester);
    await enterInto(tester, 'Email or username', 'a@b.com');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();

    await enterInto(tester, '6-digit code', '123');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Enter the 6-digit code from your email.'), findsOneWidget);
    expect(find.text('New password'), findsNothing);
  });

  testWidgets('the reset password obeys the same policy as signup', (
    tester,
  ) async {
    // A reset that accepted a weak password would make the signup rules
    // decorative — an attacker would simply use this door.
    final repo = await pump(tester);

    await enterInto(tester, 'Email or username', 'a@b.com');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();
    await enterInto(tester, '6-digit code', '123456');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    await enterInto(tester, 'New password', 'short');
    await tester.tap(find.text('Change my password'));
    await tester.pump();

    expect(find.text('Use at least 12 characters.'), findsOneWidget);
    expect(repo.confirmed, isEmpty, reason: 'the code must not be spent');
  });

  testWidgets('a mismatched confirmation is caught before the code is spent', (
    tester,
  ) async {
    final repo = await pump(tester);

    await enterInto(tester, 'Email or username', 'a@b.com');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();
    await enterInto(tester, '6-digit code', '123456');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    await enterInto(tester, 'New password', 'Str0ng!Passphrase');
    await enterInto(tester, 'Confirm new password', 'Str0ng!Passphrasx');
    await tester.tap(find.text('Change my password'));
    await tester.pump();

    expect(find.text('Those two passwords are not the same.'), findsOneWidget);
    expect(repo.confirmed, isEmpty);
  });

  testWidgets('a valid reset reaches the server with what was typed', (
    tester,
  ) async {
    final repo = await pump(tester);

    await enterInto(tester, 'Email or username', 'QuietFox');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();
    await enterInto(tester, '6-digit code', '654321');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    await enterInto(tester, 'New password', 'Str0ng!Passphrase');
    await enterInto(tester, 'Confirm new password', 'Str0ng!Passphrase');
    await tester.tap(find.text('Change my password'));
    await tester.pump();

    expect(repo.confirmed, hasLength(1));
    expect(repo.confirmed.single['identifier'], 'QuietFox');
    expect(repo.confirmed.single['code'], '654321');
    expect(repo.confirmed.single['password'], 'Str0ng!Passphrase');
  });

  testWidgets('a rejected code sends you back to the code step', (
    tester,
  ) async {
    // Leaving somebody on the password step after a bad code would have them
    // retyping a password that was never the problem.
    await pump(
      tester,
      failure: 'That code was wrong or has expired. Ask for a new one.',
    );

    await enterInto(tester, 'Email or username', 'a@b.com');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();
    await enterInto(tester, '6-digit code', '000000');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    await enterInto(tester, 'New password', 'Str0ng!Passphrase');
    await enterInto(tester, 'Confirm new password', 'Str0ng!Passphrase');
    await tester.tap(find.text('Change my password'));
    await tester.pump();

    expect(find.textContaining('wrong or has expired'), findsOneWidget);
    expect(find.widgetWithText(TextField, '6-digit code'), findsOneWidget);
  });

  testWidgets('the resend button is disabled until the cooldown passes', (
    tester,
  ) async {
    await pump(tester);
    await enterInto(tester, 'Email or username', 'a@b.com');
    await tester.tap(find.text('Send me a code'));
    await tester.pump();

    expect(find.textContaining('Send a new code in'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.ancestor(
        of: find.textContaining('Send a new code in'),
        matching: find.byType(TextButton),
      ),
    );
    expect(
      button.onPressed,
      isNull,
      reason: 'a live button that always fails teaches people to distrust it',
    );

    // Let the countdown run out.
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('Send a new code'), findsOneWidget);
  });
}
