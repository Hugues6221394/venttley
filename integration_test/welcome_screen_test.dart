// The welcome screen, on a device, in both themes and on a small phone.
//
// It is the first thing anybody sees, and the one screen where a layout that
// overflows by twelve points is the whole first impression.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/screens/onboarding/welcome_screen.dart';

const _shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    Set<String> providers = const {'email', 'google', 'apple'},
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enabledAuthProvidersProvider.overrideWith((ref) async => providers),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          home: const WelcomeScreen(),
        ),
      ),
    );
    // pump, not pumpAndSettle: the carousel rotates on a repeating timer, so
    // "settled" never arrives.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (_shotDir.isEmpty) return;
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    File('$_shotDir/$name.png').writeAsBytesSync(
      await binding.takeScreenshot(name),
    );
  }

  testWidgets('the three ways in replaced the three promises', (tester) async {
    await pump(tester);
    for (final id in ['google', 'apple', 'email']) {
      expect(
        find.byKey(ValueKey('welcome-auth-$id')),
        findsOneWidget,
        reason: '$id is not offered on the welcome screen',
      );
    }
    // The tiles they replaced. Nobody reads a feature list while deciding
    // whether to start, and the ways to start were a screen further in.
    expect(find.text('Pseudonymous'), findsNothing);
    expect(find.text('Stories & tribes'), findsNothing);
    expect(find.text('Safety first'), findsNothing);

    // The anonymous path is still the loudest thing on the screen.
    expect(find.text('Step into the Circle'), findsOneWidget);
    // RichText, not Text — find.textContaining does not see inline spans.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is RichText &&
            w.text.toPlainText().contains('Already have an account?'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await shot(tester, 'welcome-light');
  });

  testWidgets('and on a dark canvas', (tester) async {
    await pump(tester, brightness: Brightness.dark);
    expect(find.byKey(const ValueKey('welcome-auth-apple')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'welcome-dark');
  });

  testWidgets('a provider the project has not configured is not offered', (
    tester,
  ) async {
    await pump(tester, providers: const {'email'});
    expect(find.byKey(const ValueKey('welcome-auth-google')), findsNothing);
    expect(find.byKey(const ValueKey('welcome-auth-apple')), findsNothing);
    // Email is always there: it is the one door that does not depend on
    // somebody else's service being configured, or reachable.
    expect(find.byKey(const ValueKey('welcome-auth-email')), findsOneWidget);
  });

  testWidgets('it fits a small phone without overflowing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the first screen anybody sees overflows on a 4-inch phone',
    );
    expect(find.text('Step into the Circle'), findsOneWidget);
  });
}
