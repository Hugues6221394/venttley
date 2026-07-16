import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              TribeCoverPreview(width: 76, height: 58),
              TribeAvatar(size: 44),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(TribeCoverPreview)), const Size(76, 58));
    expect(tester.getSize(find.byType(TribeAvatar)), const Size(44, 44));
    expect(find.byIcon(Icons.diversity_3_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
