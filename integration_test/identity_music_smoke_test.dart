import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vently_app/data/services/mock_backend.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/compose/compose_screen.dart';
import 'package:vently_app/presentation/screens/feed/feed_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'display identity and authorized Vent music survive the full UI flow',
    (tester) async {
      MockBackend.instance.registerSession(
        const AppUser(
          userId: 'e2e-user',
          anonymousPseudonym: 'midnight_soul',
          displayName: 'Midnight Soul',
          avatarSeed: 'e2e-orb',
          currentMood: 'healing',
          userRole: 'normal',
          isVerified: false,
          safetyTier: 'standard',
          accountStatus: 'active',
          birthYear: 2000,
        ),
      );

      final router = GoRouter(
        initialLocation: '/compose',
        routes: [
          GoRoute(path: '/compose', builder: (_, __) => const ComposeScreen()),
          GoRoute(path: '/feed', builder: (_, __) => const FeedScreen()),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: VentlyTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('New Vent'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);

      await tester.tap(find.text('Music'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Add music'), findsOneWidget);
      expect(find.text('Afterglow'), findsWidgets);
      expect(find.text('Venttly Originals'), findsWidgets);

      await tester.tap(find.text('Afterglow').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Music on'), findsOneWidget);

      final ventField = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.maxLength == 1000,
      );
      expect(ventField, findsOneWidget);
      await tester.enterText(
        ventField,
        'A live integration Vent with an authorized original track.',
      );

      await tester.tap(find.text('Post'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Preview your Vent'), findsOneWidget);
      expect(find.text('Midnight Soul'), findsWidgets);
      expect(find.text('Afterglow'), findsWidgets);

      await tester.tap(find.text('Publish'));
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.text('A live integration Vent with an authorized original track.'),
        findsOneWidget,
      );
      expect(find.text('Afterglow'), findsWidgets);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
