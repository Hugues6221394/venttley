import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/widgets/poll_card.dart';

void main() {
  group('display-name compatibility', () {
    test('uses a readable fallback without changing the stable username', () {
      const user = AppUser(
        userId: 'user-a',
        anonymousPseudonym: 'midnight_soul',
        avatarSeed: 'seed',
        currentMood: 'healing',
        userRole: 'normal',
        isVerified: false,
        safetyTier: 'standard',
        accountStatus: 'active',
      );

      expect(user.displayName, 'midnight soul');
      expect(user.anonymousPseudonym, 'midnight_soul');
    });

    test('preserves an international display name exactly', () {
      const user = AppUser(
        userId: 'user-a',
        anonymousPseudonym: 'voice_of_hope',
        displayName: '希望 の 声',
        avatarSeed: 'seed',
        currentMood: 'healing',
        userRole: 'normal',
        isVerified: false,
        safetyTier: 'standard',
        accountStatus: 'active',
      );

      expect(user.displayName, '希望 の 声');
    });
  });

  group('optional music attachment', () {
    const track = MusicTrack(
      trackId: 'track-a',
      provider: 'venttly_original',
      providerTrackId: 'afterglow-v1',
      title: 'Afterglow',
      artist: 'Venttly Originals',
      previewUrl: 'asset:///assets/audio/afterglow.wav',
      previewDurationMs: 30000,
      licenseCode: 'VENTTLY_ORIGINAL',
    );

    test('a Vent remains readable when music metadata is absent', () {
      final post = _post();
      expect(post.content, 'The important human message.');
      expect(post.hasMusic, isFalse);
      expect(post.musicTrack, isNull);
    });

    test('copy hydration adds music without changing the Vent body', () {
      final hydrated = _post().copyWith(
        musicTrackId: track.trackId,
        musicTrack: track,
        musicStartMs: 0,
        musicDurationMs: 15000,
        musicVolume: 0.75,
      );

      expect(hydrated.content, 'The important human message.');
      expect(hydrated.hasMusic, isTrue);
      expect(hydrated.musicTrack?.licenseCode, 'VENTTLY_ORIGINAL');
    });

    testWidgets('the bundled original preview is declared and readable', (
      tester,
    ) async {
      final bytes = await rootBundle.load('assets/audio/afterglow.wav');
      expect(bytes.lengthInBytes, greaterThan(100000));
      expect(bytes.buffer.asUint8List(0, 4), [82, 73, 70, 70]); // RIFF
    });
  });

  testWidgets('an author-owned poll presents results without vote controls', (
    tester,
  ) async {
    final poll = PostPoll(
      pollId: 'poll-a',
      postId: 'post-a',
      question: 'Should authors vote?',
      closesAt: DateTime.now().add(const Duration(days: 1)),
      options: const [
        PollOption(optionId: 'yes', text: 'Yes'),
        PollOption(optionId: 'no', text: 'No'),
      ],
      optionCounts: const {'yes': 2, 'no': 3},
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: PollCard(poll: poll, votingDisabled: true)),
        ),
      ),
    );

    expect(find.text('Authors can’t vote'), findsOneWidget);
    expect(tester.widget<InkWell>(find.byType(InkWell).first).onTap, isNull);
  });
}

Post _post() => Post(
  postId: 'post-a',
  authorId: 'user-a',
  authorPseudonym: '@midnight_soul',
  authorDisplayName: 'Midnight Soul',
  authorAvatarSeed: 'seed',
  categoryName: 'confessions',
  postType: 'user_post',
  content: 'The important human message.',
  postMood: 'healing',
  likesCount: 0,
  commentsCount: 0,
  createdAt: DateTime.utc(2026),
);
