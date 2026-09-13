// Tapping the heart, in the real feed, against a real backend.
//
// Reported from the device: tapping the heart on a Vent does nothing visible.
// Every piece looked correct in isolation — the controller writes its override
// before the await, reactionAdjusted watches the provider, Post.copyWith uses
// an _unset sentinel so an explicit null really clears, AnimatedLikeButton
// keys its AnimatedSwitcher on `active`, and set_post_reaction returns 200
// over HTTP. The existing unit tests pass.
//
// They pass because they pump a bare Consumer, never the card a thumb actually
// hits. This test taps the real thing.
//
//   flutter test integration_test/like_button_test.dart -d <sim> \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/screens/feed/feed_screen.dart';
import 'package:vently_app/animation/widgets/animated_like_button.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tapping the heart fills it and moves the count', (tester) async {
    expect(_url.isNotEmpty && _anonKey.isNotEmpty, isTrue,
        reason: 'pass --dart-define=SUPABASE_URL and SUPABASE_ANON_KEY');

    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );

    final router = GoRouter(
      initialLocation: '/feed',
      routes: [
        GoRoute(path: '/feed', builder: (_, __) => const FeedScreen()),
        // The card pushes here on tap; a stub keeps an accidental navigation
        // from failing the test for the wrong reason.
        GoRoute(
          path: '/post/:id',
          builder: (_, __) => const Scaffold(body: Text('detail')),
        ),
      ],
    );
    addTearDown(router.dispose);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(sessionProvider.notifier).restore();
    expect(container.read(sessionProvider), isNotNull,
        reason: 'the session must be restored or the feed renders signed-out');

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

    // Let the network settle first.
    for (var i = 0;
        i < 60 && container.read(feedPostsProvider).valueOrNull == null;
        i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // Then scroll to the Vents. The feed opens on stories, the Whispers rail
    // and Trending Tribes; the post cards start below the fold and Flutter
    // does not build off-screen slivers, so without this the cards genuinely
    // do not exist yet and the test would "reproduce" a bug that is not there.
    for (var i = 0;
        i < 12 && find.byType(AnimatedLikeButton).evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.byType(AnimatedLikeButton), findsWidgets,
        reason: 'the feed should render at least one Vent card');

    final before = find.byIcon(Icons.favorite_rounded).evaluate().length;

    // Diagnostic: separate "the tap never reached the handler" from "the
    // handler ran but nothing repainted". Those have completely different
    // fixes and the symptom on screen is identical.
    final overridesBefore = container.read(reactionControllerProvider).length;

    // Tap the button widget, not the glyph, to find out whether the glyph is
    // simply outside its parent's hit area.
    final button = find.byType(AnimatedLikeButton);
    // Tap the glyph itself — what a thumb actually hits — rather than the
    // centre of the widget's box, which Expanded stretches well past the
    // GestureDetector's own bounds.
    final glyph = find.descendant(
      of: button.first,
      matching: find.byType(Icon),
    );
    // Scroll it fully into the viewport. A widget that exists but sits below
    // the fold is not tappable, and tester.tap on it silently hits the render
    // view — which looks exactly like a dead button.
    await tester.ensureVisible(button.first);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(glyph.first);
    await tester.pump();
    final immediate = container.read(reactionControllerProvider).length;

    // THE ACTUAL REQUIREMENT. The brief is explicit: "Tap Like → UI
    // immediately changes → counter immediately changes → background
    // persistence". Not after the double-tap timer, not after the round trip.
    // On the frame of the tap.
    expect(immediate, greaterThan(overridesBefore),
        reason: 'the reaction must register on the frame of the tap. If this '
            'fails but the 600ms check below passes, an ancestor '
            'DoubleTapGestureRecognizer is holding the gesture arena open and '
            'the heart feels dead to the thumb.');

    await tester.pump(const Duration(milliseconds: 600));
    final overridesAfter = container.read(reactionControllerProvider).length;
    // If the ancestor InkWell won the arena, the card navigated instead.
    debugPrint('DIAG like buttons still present=${find.byType(AnimatedLikeButton).evaluate().length}');
    expect(overridesAfter, greaterThan(overridesBefore),
        reason: 'the tap must reach ReactionController.toggle');
    // One frame. The whole promise of optimistic UI is that the heart moves
    // now, not after the round trip.
    await tester.pump();

    final after = find.byIcon(Icons.favorite_rounded).evaluate().length;
    expect(after, greaterThan(before),
        reason: 'the heart must fill on the frame of the tap, before the '
            'server has answered — this is the reported bug');

    // And it must survive the server's answer rather than flipping back.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.favorite_rounded).evaluate().length,
        greaterThanOrEqualTo(after),
        reason: 'the confirmed reaction must not revert once the server agrees');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
