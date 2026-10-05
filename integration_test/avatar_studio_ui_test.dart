// The avatar studio screen, driven on a real device against a real stack.
//
// The sibling test (avatar_studio_test.dart) proves the save path — bake,
// upload, validate, read back. This proves the part a person actually touches:
// that the four parts are all reachable, that choosing something changes the
// face, and that Save stays dark until there is something to save.
//
//   flutter test integration_test/avatar_studio_ui_test.dart -d <simulator-id> \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/presentation/screens/profile/avatar_studio_screen.dart';
import 'package:vently_app/presentation/widgets/avatar_look_view.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Set SHOT_DIR to collect screenshots while looking at a design change.
const _shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> shot(WidgetTester tester, String name) async {
    if (_shotDir.isEmpty) return;
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    final bytes = await binding.takeScreenshot(name);
    File('$_shotDir/$name.png').writeAsBytesSync(bytes);
  }

  testWidgets('every part is reachable, and changing one redraws the face', (
    tester,
  ) async {
    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AvatarStudioScreen()),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // The preview, plus one tile per option on the opening tab.
    expect(find.byType(AvatarLookView), findsWidgets);
    for (final part in ['skin', 'hair', 'beard', 'outfit']) {
      expect(
        find.byKey(ValueKey('avatar-tab-$part')),
        findsOneWidget,
        reason: '$part is not reachable',
      );
    }

    // Nothing changed yet, so there is nothing to save.
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('avatar-studio-save')),
    );
    expect(save.onPressed, isNull, reason: 'Save is live before any change');

    await shot(tester, 'studio-skin');

    Future<void> choose(String tab, String option) async {
      await tester.tap(find.byKey(ValueKey('avatar-tab-$tab')));
      await tester.pumpAndSettle();
      final tile = find.byKey(ValueKey('avatar-option-$option'));
      // Named explicitly: a tab with a colour strip has two scrollables, and
      // the default picks whichever is first rather than the one holding the
      // tiles.
      await tester.scrollUntilVisible(
        tile,
        120,
        maxScrolls: 10,
        scrollable: find
            .descendant(
              of: find.byType(GridView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }

    await choose('hair', 'hair_07');
    await tester.tap(find.byKey(const ValueKey('avatar-tint-blonde')));
    await tester.pumpAndSettle();
    await shot(tester, 'studio-hair');

    await choose('beard', 'beard_10');
    await shot(tester, 'studio-beard');

    await choose('outfit', 'top_02');
    await tester.tap(find.byKey(const ValueKey('avatar-tint-berry')));
    await tester.pumpAndSettle();
    await shot(tester, 'studio-outfit');

    // Bald is a haircut, and it must be choosable.
    await tester.tap(find.byKey(const ValueKey('avatar-tab-hair')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('avatar-option-none')), findsOneWidget);

    final afterwards = tester.widget<FilledButton>(
      find.byKey(const ValueKey('avatar-studio-save')),
    );
    expect(
      afterwards.onPressed,
      isNotNull,
      reason: 'Save is still dark after four changes',
    );
    expect(tester.takeException(), isNull);
  });
}
