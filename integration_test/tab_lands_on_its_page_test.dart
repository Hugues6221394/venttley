// Tapping a tab, from wherever you happen to be.
//
// Reported from the phone: tap Friends and you do not always get Friends. The
// expectation is the one every big app sets — a tab takes you to that tab's
// page, no matter where you were or how deep.
//
// This drives the real router and the real shell, and tries every "where you
// were" the app can be in: another branch, deep inside the branch Friends
// lives in, and Friends itself.
//
//   flutter test integration_test/tab_lands_on_its_page_test.dart -d <device> \
//     --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/router/app_router.dart';
import 'package:vently_app/presentation/screens/profile/edit_profile_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a tab lands on its own page from anywhere',
    (tester) async {
      expect(_url.isNotEmpty && _anonKey.isNotEmpty, isTrue);

      await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'tester_user@id.venttly.app',
        password: 'TestPass123!',
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).restore();

      final router = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: VentlyTheme.light(),
            routerConfig: router,
          ),
        ),
      );

      String where() => router.routerDelegate.currentConfiguration.uri.path;

      Future<void> settle([int frames = 12]) async {
        for (var i = 0; i < frames; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      router.go('/feed');
      await settle();
      expect(where(), '/feed', reason: 'signed in, on the home tab');

      Future<void> tap(String tab) async {
        final finder = find.byKey(ValueKey('member-nav-$tab'));
        expect(
          finder,
          findsOneWidget,
          reason: 'the $tab tab must be on screen',
        );
        await tester.tap(finder);
        await settle();
      }

      // From another branch.
      await tap('friends');
      expect(where(), '/friends');

      // From deep inside the branch Friends itself lives in.
      router.go('/tribes');
      await settle();
      router.push('/discover');
      await settle();
      await tap('friends');
      expect(
        where(),
        '/friends',
        reason: 'a pushed page on top of the branch must not swallow the tap',
      );

      // From Friends itself — a second tap is a no-op, not a stack.
      await tap('friends');
      expect(where(), '/friends');

      // And back out again, so the other tabs still work from here.
      await tap('inbox');
      expect(where(), '/inbox');
      await tap('friends');
      expect(where(), '/friends');

      // The same promise for the branch tabs, which is where it was actually
      // broken: goBranch restores the page you left a branch on, so Profile
      // could open three screens into Settings instead of your profile.
      await tap('profile');
      expect(where(), '/profile');
      router.push('/profile/edit');
      await settle();
      // Asked of the widget tree rather than the URI: a push inside a shell
      // branch does not move the router's top-level configuration, so the path
      // still reads /profile while Edit profile is what is on screen.
      expect(
        find.byType(EditProfileScreen),
        findsOneWidget,
        reason: 'deep inside the Profile tab',
      );

      await tap('home');
      expect(where(), '/feed');
      await tap('profile');
      expect(where(), '/profile');
      expect(
        find.byType(EditProfileScreen),
        findsNothing,
        reason: 'a tab opens its own page, not the one you wandered off from',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
