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
// It is also destructive to its own precondition, which is why it passed once
// and then failed on every run afterwards. personal_feed excludes posts you
// have already liked — "you have seen it and acted on it" — so each run
// removed one more Vent from this account's feed until there was nothing left
// to scroll to and the test died on an empty CustomScrollView finder, several
// steps away from the cause. The likes it creates are therefore undone at the
// end, and the feed is checked for depth before the tap rather than after.
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

Future<Set<String>> _likedPostIds(SupabaseClient client, String uid) async {
  final rows =
      await client.from('post_likes').select('post_id').eq('user_id', uid);
  return {for (final r in rows) r['post_id'] as String};
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tapping the heart fills it and moves the count', (tester) async {
    expect(_url.isNotEmpty && _anonKey.isNotEmpty, isTrue,
        reason: 'pass --dart-define=SUPABASE_URL and SUPABASE_ANON_KEY');

    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    final client = Supabase.instance.client;
    await client.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );
    final uid = client.auth.currentUser!.id;

    // Undo whatever this run likes, so the next run has the same feed. Runs
    // even when the test fails part-way, which is the case that drained it.
    final likedBefore = await _likedPostIds(client, uid);
    addTearDown(() async {
      // Polled, not sampled once. The tap is optimistic — the UI updates
      // immediately and the write lands afterwards — so reading the table the
      // instant the test body ends finds nothing to undo, the like arrives a
      // moment later, and the feed loses a post per run anyway. That is
      // exactly what happened: three "cleaned up" runs left three likes.
      var mine = <String>{};
      for (var i = 0; i < 20 && mine.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        mine = (await _likedPostIds(client, uid)).difference(likedBefore);
      }
      for (final postId in mine) {
        // Undone the way the app undoes it. A direct DELETE fails with 42501:
        // members hold SELECT on post_likes and nothing more, and unliking
        // goes through this SECURITY DEFINER function. Reaching past it in a
        // teardown failed the test it was meant to make repeatable.
        await client.rpc(
          'set_post_reaction',
          params: {'p_post_id': postId, 'p_reaction': null},
        );
      }
      final left = (await _likedPostIds(client, uid)).difference(likedBefore);
      if (left.isNotEmpty) {
        // Said out loud rather than left for the next run to trip over.
        // ignore: avoid_print
        print('WARNING: could not undo ${left.length} like(s); the feed will '
            'be shorter next run: $left');
      }
    });

    // Said out loud before the tap. An empty feed is not a like-button bug,
    // and letting it surface as one costs an hour every time.
    final feed = await client.rpc('personal_feed', params: {}) as List<dynamic>;
    expect(
      feed,
      isNotEmpty,
      reason: 'personal_feed returned nothing for tester_user, so there is no '
          'card to tap. Seed a Vent from another account, or unlike what this '
          'account has already liked — personal_feed hides both.',
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
