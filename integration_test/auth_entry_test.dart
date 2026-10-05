// The ways into Venttly, drawn on a real device.
//
// The code-shape guards in test/welcome_entry_methods_test.dart answer "is the
// button still in the source". They cannot answer "does it draw" — Apple's
// mark is an SVG with a currentColor fill under a colour filter, and the
// Google one has had a tinted Material letter stand in for it before. This
// renders both against a provider list it controls, so neither depends on what
// a particular backend happens to advertise.
//
//   flutter test integration_test/auth_entry_test.dart -d <simulator-id>

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/widgets/auth_entry_methods.dart';

const _shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpWith(WidgetTester tester, Set<String> providers,
      {Brightness brightness = Brightness.light}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enabledAuthProvidersProvider.overrideWith((ref) async => providers),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    ContinueWithEmailButton(),
                    SizedBox(height: 14),
                    AuthOrDivider(),
                    SizedBox(height: 14),
                    SocialAuthRow(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // An SVG decodes off the main isolate, and pumpAndSettle does not wait for
    // it — the first frame draws the button with no mark on it. Without this
    // the first screenshot of a run shows a Google button missing its G, which
    // looks exactly like the bug this file exists to catch.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (_shotDir.isEmpty) return;
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    File('$_shotDir/$name.png').writeAsBytesSync(
      await binding.takeScreenshot(name),
    );
  }

  testWidgets('both providers draw, each with its own mark', (tester) async {
    await pumpWith(tester, {'email', 'google', 'apple'});
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);
    // Two marks, both real files rather than Material glyphs.
    expect(find.byType(SvgPicture), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await shot(tester, 'auth-entry-light');
  });

  testWidgets('and on a dark background', (tester) async {
    await pumpWith(tester, {'email', 'google', 'apple'},
        brightness: Brightness.dark);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'auth-entry-dark');
  });

  testWidgets('a provider the project has not configured stays hidden', (
    tester,
  ) async {
    await pumpWith(tester, {'email', 'google'});
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(
      find.text('Continue with Apple'),
      findsNothing,
      reason: 'Apple is not enabled on this project',
    );
  });

  testWidgets('Apple does not disappear when Google is off', (tester) async {
    // The row used to return early if Google was missing, which would have
    // taken Apple down with it.
    await pumpWith(tester, {'email', 'apple'});
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('Continue with email'), findsOneWidget);
  });
}
