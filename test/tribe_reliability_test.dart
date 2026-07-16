import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/widgets/media_preview_viewer.dart';
import 'package:vently_app/presentation/widgets/tribe_avatar.dart';

void main() {
  test('Tribe keepers use canonical user profiles, never Plug profiles', () {
    final detail = File(
      'lib/presentation/screens/tribes/tribe_detail_screen.dart',
    ).readAsStringSync();
    final directory = File(
      'lib/presentation/screens/tribes/tribes_directory_screen.dart',
    ).readAsStringSync();

    expect(detail, contains('UserProfileTap('));
    expect(detail, contains('userId: tribe.keeperId'));
    expect(directory, contains('userId: tribe.keeperId'));
    expect(detail, isNot(contains("'/plug/")));
    expect(directory, isNot(contains("'/plug/")));
  });

  test('Tribe and public user photos are wired to the shared preview', () {
    final detail = File(
      'lib/presentation/screens/tribes/tribe_detail_screen.dart',
    ).readAsStringSync();
    final publicProfile = File(
      'lib/presentation/screens/friends/friend_profile_screen.dart',
    ).readAsStringSync();

    expect(detail, contains('openCover: true'));
    expect(detail, contains('openCover: false'));
    expect(detail, contains('showMediaPreview('));
    expect(publicProfile, contains('class _PublicProfilePhoto'));
    expect(publicProfile, contains('showMediaPreview('));
    expect(publicProfile, contains('profile.profilePhotoUrl'));
  });

  test('Tribe directory migration is RLS-aware and includes identity photos',
      () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) =>
              file.path.endsWith('_home_topic_stats_and_tribe_profiles.sql'),
        )
        .readAsStringSync();

    expect(migration, contains('SECURITY INVOKER'));
    expect(migration, contains('FROM public.feed_posts f'));
    expect(migration, contains('SUM(f.comments_count)'));
    expect(migration, contains('keeper_profile_photo_url'));
    expect(migration, contains('spotlight_profile_photo_url'));
    expect(migration, contains('GRANT EXECUTE ON FUNCTION'));
    expect(migration, contains('GRANT SELECT ON public.tribe_directory'));
  });

  testWidgets('Tribe image fallbacks preserve stable card dimensions',
      (tester) async {
    var coverTaps = 0;
    var avatarTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              TribeCoverPreview(
                width: 76,
                height: 58,
                onTap: () => coverTaps++,
              ),
              TribeAvatar(size: 44, onTap: () => avatarTaps++),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(TribeCoverPreview)), const Size(76, 58));
    expect(tester.getSize(find.byType(TribeAvatar)), const Size(44, 44));
    expect(find.byIcon(Icons.diversity_3_rounded), findsNWidgets(2));
    await tester.tap(find.byType(TribeCoverPreview));
    await tester.tap(find.byType(TribeAvatar));
    expect(coverTaps, 1);
    expect(avatarTaps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared media preview opens full screen and closes reliably',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaPreview(
              context,
              title: 'Dating & Chaos',
              items: const [
                MediaPreviewItem(
                  url: 'https://example.invalid/cover.jpg',
                  label: 'Cover photo',
                ),
                MediaPreviewItem(
                  url: 'https://example.invalid/profile.jpg',
                  label: 'Profile photo',
                ),
              ],
            ),
            child: const Text('Preview'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Preview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('Dating & Chaos'), findsOneWidget);
    expect(find.text('Cover photo'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsWidgets);

    await tester.tap(find.byTooltip('Next image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Profile photo'), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    expect(find.text('Dating & Chaos'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
