import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/data/services/mock_backend.dart';
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

    test('tribe messages and social discovery use readable fallbacks', () {
      final message = TribeMessage(
        messageId: 'message-a',
        tribeId: 'tribe-a',
        senderPseudonym: 'midnight_soul',
        senderAvatarSeed: 'seed',
        createdAt: DateTime.utc(2026),
        sentByMe: false,
      );
      final request = FriendRequest(
        friendshipId: 'friendship-a',
        otherUserId: 'user-a',
        otherPseudonym: 'midnight_soul',
        otherAvatarSeed: 'seed',
        otherKarma: 0,
        createdAt: DateTime.utc(2026),
        isOutgoing: false,
      );

      expect(message.displayName, 'midnight_soul');
      expect(request.primaryName, 'midnight_soul');
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

    test(
      'mock runtime keeps canonical music and display identity on publish',
      () async {
        const user = AppUser(
          userId: 'mock-music-user',
          anonymousPseudonym: 'midnight_soul',
          displayName: 'Midnight Soul',
          avatarSeed: 'seed',
          currentMood: 'healing',
          userRole: 'normal',
          isVerified: false,
          safetyTier: 'standard',
          accountStatus: 'active',
          birthYear: 2000,
        );
        MockBackend.instance.registerSession(user);
        final repository = VentlyRepository(forceMock: true);
        final catalog = await repository.searchMusic(query: 'afterglow');

        expect(catalog, hasLength(1));
        final post = await repository.createPost(
          content: 'A music-backed Vent.',
          category: 'confessions',
          mood: 'healing',
          musicTrack: catalog.single,
        );

        expect(post.authorDisplayName, 'Midnight Soul');
        expect(post.musicTrackId, catalog.single.trackId);
        expect(post.musicTrack, same(catalog.single));
        expect(post.musicDurationMs, 15000);
      },
    );

    test('mock runtime rejects client-invented catalog records', () async {
      MockBackend.instance.registerSession(
        const AppUser(
          userId: 'mock-hostile-user',
          anonymousPseudonym: 'hostile_client',
          avatarSeed: 'seed',
          currentMood: 'healing',
          userRole: 'normal',
          isVerified: false,
          safetyTier: 'standard',
          accountStatus: 'active',
          birthYear: 2000,
        ),
      );
      final repository = VentlyRepository(forceMock: true);
      const invented = MusicTrack(
        trackId: 'invented',
        provider: 'unauthorized',
        providerTrackId: 'pirated',
        title: 'Invented',
        artist: 'Hostile Client',
        previewUrl: 'https://example.invalid/full-song.mp3',
        previewDurationMs: 180000,
        licenseCode: 'NONE',
      );

      await expectLater(
        repository.createPost(
          content: 'Hostile payload.',
          category: 'confessions',
          mood: 'healing',
          musicTrack: invented,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'music_track_unavailable',
          ),
        ),
      );
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
