import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/home/home_discovery.dart';
import 'package:vently_app/presentation/screens/feed/story_viewer_screen.dart';
import 'package:vently_app/presentation/widgets/sensitive_media_veil.dart';

/// The story viewer, pinned against four bugs that all reached a real device.
///
/// These are widget tests rather than simulator passes on purpose. Two of them
/// cannot be reached by hand at all without a second signed-in account posting
/// a story — the reaction tray and reply composer only render on somebody
/// else's story — and a RenderFlex overflow is reported as a thrown
/// FlutterError here, which is a far more reliable check than looking at a
/// screenshot and deciding whether something is clipped.
const _me = AppUser(
  userId: 'viewer-1',
  anonymousPseudonym: 'QuietFox',
  avatarSeed: 'quiet-fox',
  currentMood: 'hopeful',
  userRole: 'normal',
  isVerified: false,
  safetyTier: 'standard',
  accountStatus: 'active',
  emailVerified: true,
);

class _TestSessionController extends SessionController {
  _TestSessionController() : super(VentlyRepository(forceMock: true)) {
    state = _me;
  }
}

Post _story({
  required String postId,
  required String authorId,
  String content = '',
  String? imageUrl,
  String mediaStatus = 'clean',
}) {
  return Post(
    postId: postId,
    authorId: authorId,
    authorPseudonym: 'DawnPatrol',
    authorAvatarSeed: 'dawn-patrol',
    categoryName: 'Confessions',
    postType: 'text',
    content: content,
    postMood: 'hopeful',
    likesCount: 0,
    commentsCount: 0,
    createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    imageUrl: imageUrl,
    mediaStatus: mediaStatus,
    isStory: true,
  );
}

Future<void> pumpViewer(
  WidgetTester tester,
  List<Post> stories, {
  bool replyAllowed = true,
}) async {
  // A real phone, because two of these bugs are width-dependent.
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(VentlyRepository(forceMock: true)),
        sessionProvider.overrideWith((ref) => _TestSessionController()),
        liveStoriesProvider.overrideWith((ref) async => stories),
        storyReplyAllowedProvider.overrideWith((ref, id) async => replyAllowed),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: StoryViewerScreen(initialPostId: stories.first.postId),
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 200));
}

void main() {
  group('a story with a photo still shows its words', () {
    testWidgets('caption renders alongside the image', (tester) async {
      // The bug: _StoryCanvas returned the image early, so the caption branch
      // was never built. A story posted with a photo and something written on
      // it showed the photo and silently dropped the words.
      await pumpViewer(tester, [
        _story(
          postId: 's1',
          authorId: 'someone-else',
          content: 'I finally told them how I feel',
          imageUrl: 'https://example.test/a.jpg',
        ),
      ]);

      expect(find.textContaining('I finally told them how I feel'), findsOne);
    });

    testWidgets('a text-only story still renders its text', (tester) async {
      await pumpViewer(tester, [
        _story(
          postId: 's2',
          authorId: 'someone-else',
          content: 'Some nights are just long',
        ),
      ]);

      expect(find.textContaining('Some nights are just long'), findsOne);
    });
  });

  group('story images obey the scan verdict', () {
    testWidgets('pending media is veiled', (tester) async {
      // VentStory.fromPost used to drop mediaStatus entirely, so the viewer
      // had no idea whether an image had been scanned and showed every one of
      // them. The feed has veiled on this since 0087.
      await pumpViewer(tester, [
        _story(
          postId: 's3',
          authorId: 'someone-else',
          imageUrl: 'https://example.test/b.jpg',
          mediaStatus: 'pending',
        ),
      ]);

      final veil = tester.widget<SensitiveMediaVeil>(
        find.byType(SensitiveMediaVeil),
      );
      expect(veil.veiled, isTrue);
      expect(veil.pending, isTrue);
    });

    testWidgets('sensitive media is veiled but not marked pending', (
      tester,
    ) async {
      await pumpViewer(tester, [
        _story(
          postId: 's4',
          authorId: 'someone-else',
          imageUrl: 'https://example.test/c.jpg',
          mediaStatus: 'sensitive',
        ),
      ]);

      final veil = tester.widget<SensitiveMediaVeil>(
        find.byType(SensitiveMediaVeil),
      );
      expect(veil.veiled, isTrue);
      expect(veil.pending, isFalse);
    });

    testWidgets('a cleared image is not veiled', (tester) async {
      await pumpViewer(tester, [
        _story(
          postId: 's5',
          authorId: 'someone-else',
          imageUrl: 'https://example.test/d.jpg',
          mediaStatus: 'clean',
        ),
      ]);

      final veil = tester.widget<SensitiveMediaVeil>(
        find.byType(SensitiveMediaVeil),
      );
      expect(veil.veiled, isFalse);
    });

    test('the entity defaults to veiled, not to clean', () {
      // If a future caller forgets to pass mediaStatus, the image must hide
      // rather than show. Same reasoning as `?? 'pending'` in the feed.
      final story = VentStory(
        postId: 'x',
        authorPseudonym: 'a',
        authorDisplayName: 'a',
        authorAvatarSeed: 'a',
        content: 'a',
        category: 'Confessions',
        mood: 'hopeful',
        createdAt: DateTime(2026, 9, 2),
        expiresAt: DateTime(2026, 9, 3),
        reactionsCount: 0,
        repliesCount: 0,
        viewCount: 0,
        imageUrl: 'https://example.test/e.jpg',
      );
      expect(story.mediaStatus, 'pending');
      expect(story.mediaNeedsVeil, isTrue);
    });
  });

  testWidgets('the reaction tray fits a 393pt phone', (tester) async {
    // The bug: four TextButton.icon widgets in a Row, icon beside label.
    // "Been there" plus an icon plus each button's own padding, four times,
    // does not fit — "A RenderFlex overflowed by 15 pixels". An overflow is a
    // thrown FlutterError in a widget test, so takeException() catches it
    // whether or not anything looks wrong in a screenshot.
    await pumpViewer(tester, [
      _story(
        postId: 's6',
        authorId: 'someone-else',
        content: 'Tray layout check',
      ),
    ]);

    expect(find.text('Hug'), findsOne);
    expect(find.text('Been there'), findsOne);
    expect(
      tester.takeException(),
      isNull,
      reason: 'a RenderFlex overflow would surface here',
    );
  });

  testWidgets('the tray is hidden on your own story', (tester) async {
    await pumpViewer(tester, [
      _story(postId: 's7', authorId: _me.userId, content: 'mine'),
    ]);

    expect(find.text('Been there'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
