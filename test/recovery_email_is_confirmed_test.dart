import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/presentation/screens/onboarding/personalise_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

/// The recovery email on the last step of signup, and the code that makes it
/// mean something.
///
/// Found by driving a real signup on an iPhone simulator: type an address,
/// press Enter Venttly, and you are in the app. The address is stored, a live
/// six-digit code is sitting in recovery_verification_codes, and
/// recovery_email_verified is false — with a note suggesting you finish it in
/// Settings, which nobody does. The person leaves onboarding believing they
/// have a way back in. They have an address they typed.
///
/// The brief said it plainly: a recovery email "that always be verified on
/// onboarding screen".
class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.acceptCode = '123456'}) : super(forceMock: true);

  final String acceptCode;
  final List<String> saved = [];
  final List<String> attempted = [];

  @override
  Future<String?> setRecoveryEmail(String email) async {
    saved.add(email);
    return email;
  }

  @override
  Future<bool> confirmRecoveryEmail(String code) async {
    attempted.add(code);
    return code == acceptCode;
  }
}

Future<_FakeRepo> _open(WidgetTester tester) async {
  // A phone, not the 800x600 default: everything below the banner — the code
  // box and the button this test is about — is otherwise off the bottom.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final repo = _FakeRepo();
  final router = GoRouter(
    initialLocation: '/onboarding/personalise',
    routes: [
      GoRoute(
        path: '/onboarding/personalise',
        builder: (_, __) => const PersonaliseScreen(),
      ),
      GoRoute(
        path: '/feed',
        builder: (_, __) => const Scaffold(body: Text('feed')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(
        theme: VentlyTheme.light(),
        routerConfig: router,
        // The onboarding backdrop drifts two orbs forever on the light theme,
        // so pumpAndSettle never returns. This is the same switch the backdrop
        // reads for somebody who has asked the system to reduce motion.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Finder get _emailField =>
    find.widgetWithText(TextField, 'Recovery email (optional)');
Finder get _codeField => find.widgetWithText(TextField, 'Confirmation code');

/// The label on the one filled button at the bottom, scrolled into view first.
///
/// The screen is taller than a phone, so the button is below the fold — and a
/// ListView does not build what it cannot show, which makes a finder for it
/// come back empty rather than false.
Future<String> _finishLabel(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.byType(FilledButton),
    find.byType(Scrollable).first,
    const Offset(0, -150),
    maxIteration: 40,
  );
  await tester.pumpAndSettle();
  final button = tester.widget<FilledButton>(find.byType(FilledButton));
  return (button.child as Text?)?.data ?? '';
}

Future<void> _tapFinish(WidgetTester tester) async {
  await _finishLabel(tester);
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with nothing typed, the step is still optional', (tester) async {
    await _open(tester);

    expect(await _finishLabel(tester), 'Enter Venttly');
    await _tapFinish(tester);
    expect(find.text('feed'), findsOneWidget);
  });

  testWidgets('an address asks for a code instead of leaving', (tester) async {
    final repo = await _open(tester);

    await tester.enterText(_emailField, 'someone@example.com');
    await tester.pumpAndSettle();
    expect(
      await _finishLabel(tester),
      'Send me a code',
      reason: 'the button says what it is about to do',
    );

    await _tapFinish(tester);

    expect(repo.saved, ['someone@example.com']);
    expect(find.text('feed'), findsNothing, reason: 'this is the bug: it left');
    expect(_codeField, findsOneWidget);
    expect(await _finishLabel(tester), 'Confirm and enter');
  });

  testWidgets('a wrong code says so and stays put', (tester) async {
    await _open(tester);

    await tester.enterText(_emailField, 'someone@example.com');
    await tester.pumpAndSettle();
    await _tapFinish(tester);

    await tester.enterText(_codeField, '000000');
    await tester.pumpAndSettle();
    await _tapFinish(tester);

    expect(find.textContaining('wrong or has expired'), findsOneWidget);
    expect(find.text('feed'), findsNothing);
  });

  testWidgets('and the right one confirms, then lets you in', (tester) async {
    final repo = await _open(tester);

    await tester.enterText(_emailField, 'someone@example.com');
    await tester.pumpAndSettle();
    await _tapFinish(tester);

    await tester.enterText(_codeField, '123456');
    await tester.pumpAndSettle();
    await _tapFinish(tester);

    expect(repo.attempted, ['123456']);
    expect(find.text('feed'), findsOneWidget);
  });

  testWidgets('Skip still leaves, and says what it leaves behind', (
    tester,
  ) async {
    await _open(tester);

    await tester.enterText(_emailField, 'someone@example.com');
    await tester.pumpAndSettle();
    await _tapFinish(tester);

    // The line under the button, which is the last thing before Skip.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('still needs its code'),
      findsOneWidget,
      reason: 'leaving now leaves an address that cannot recover the account',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();
    expect(find.text('feed'), findsOneWidget);
  });
}
