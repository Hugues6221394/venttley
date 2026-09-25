import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/presentation/screens/onboarding/recovery_key_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

/// The screen that shows the twelve words, and what it does when it has none.
///
/// The route reads the phrase from go_router's `extra`, and `extra` does not
/// survive a redirect. Any rule that bounced /onboarding/key and came back
/// would arrive with nothing — and splitting an empty string yields one empty
/// chip, so the screen rendered a blank grid under "write these down" beside a
/// checkbox claiming you had.
///
/// The phrase is generated once at signup and never stored, so an empty one is
/// not a loading state. It is gone, and the screen has to say so.
void main() {
  Future<void> pump(WidgetTester tester, String phrase) async {
    final router = GoRouter(
      initialLocation: '/key',
      routes: [
        GoRoute(
          path: '/key',
          builder: (_, __) => RecoveryKeyScreen(phrase: phrase),
        ),
        GoRoute(
          path: '/onboarding/personalise',
          builder: (_, __) => const Scaffold(body: Text('personalise')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          theme: VentlyTheme.dark(pureBlack: true),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a real phrase is shown to be written down', (tester) async {
    await pump(tester, 'alpha bravo charlie delta echo foxtrot '
        'golf hotel india juliet kilo lima');

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.textContaining('could not show'), findsNothing);

    // This also holds the backdrop honest: a ListTile whose ink surface is
    // hidden behind the page colour reports a framework error, and a reported
    // error fails this test. On black it used to.
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Enter Venttly'),
      ).onPressed,
      isNotNull,
      reason: 'acknowledging the phrase is what unlocks the way forward',
    );
  });

  testWidgets('an empty phrase says so instead of showing blanks', (
    tester,
  ) async {
    await pump(tester, '');

    expect(find.textContaining('could not show'), findsOneWidget);
    expect(
      find.byType(CheckboxListTile),
      findsNothing,
      reason: 'never ask somebody to confirm they saved something blank',
    );
  });

  testWidgets('and offers the one way back that is left', (tester) async {
    // A recovery email is the only remaining route into the account, and the
    // next screen is where it is set.
    await pump(tester, '   ');

    final button = find.widgetWithText(ElevatedButton, 'Add a recovery email');
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('personalise'), findsOneWidget);
  });
}
