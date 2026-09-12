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
    // Anchored on the accessibility label rather than the widget's private
    // class name. The name has already churned once (_PublicProfilePhoto ->
    // _HeroAvatar in the hero redesign) without the behaviour changing; the
    // label is what a screen-reader user actually depends on.
    //
    // The `label: ` prefix has since been dropped from the match too. The
    // avatar now offers a choice when the person has a live story, so the
    // label is picked by a conditional and the photo case is no longer the
    // first thing on its line:
    //
    //   label: hasStory
    //       ? 'View @${profile.pseudonym} story or profile photo'
    //       : 'View @${profile.pseudonym} profile photo',
    //
    // Both labels are asserted, because a screen-reader user needs to be told
    // which of the two the tap will do.
    expect(
      publicProfile,
      contains(r"'View @${profile.pseudonym} profile photo'"),
    );
    expect(
      publicProfile,
      contains(r"'View @${profile.pseudonym} story or profile photo'"),
    );
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

  test('the age gate stands on the route, not on the buttons', () {
    // Eight screens push /tribes/new. Only tribes_directory_screen was calling
    // ensureCanCreateTribe, so the other seven opened the form with no check,
    // walked to step 3, and got "We need one more detail about your age first"
    // — a message naming a missing detail with no route to supply it, even
    // though the sheet that asks for it already existed.
    //
    // Guarding buttons is the fix that decays: the ninth caller forgets. So the
    // guard sits on the route, and this test is what keeps it there.
    final router = File(
      'lib/presentation/router/app_router.dart',
    ).readAsStringSync();

    final createRoute = RegExp(
      r"path:\s*'/tribes/new',(.*?)\),\s*GoRoute",
      dotAll: true,
    ).firstMatch(router);
    expect(
      createRoute,
      isNotNull,
      reason: 'the /tribes/new route moved; re-point this test',
    );
    expect(
      createRoute!.group(1),
      contains('TribeCreationGate'),
      reason:
          'CreateTribeScreen must be wrapped so no entry point can bypass the '
          'age check',
    );

    // And the gate has to actually ask. A wrapper that renders its child
    // unconditionally would satisfy the assertion above and change nothing.
    final gate = File(
      'lib/presentation/widgets/tribe_age_gate.dart',
    ).readAsStringSync();
    expect(gate, contains('class TribeCreationGate'));
    expect(gate, contains('checkCanCreateTribe(context, ref'));
    // Refused means leave, not sit on a form that can only fail at submit.
    expect(gate, contains('navigator.pop()'));

    // And an inconclusive check must NOT be treated as a refusal. Collapsing
    // the two would mean a dropped request bounces an adult out of the form,
    // while protecting nothing — the server checks the age itself.
    expect(gate, contains('enum TribeCreationCheck'));
    expect(gate, contains('result != TribeCreationCheck.refused'));
  });

  test('a late age refusal is recoverable, not a dead end', () {
    // Belt and braces for the case the gate cannot catch: the row changes
    // between opening the form and submitting it. The old catch turned
    // age_verification_required into a snackbar and dropped it there. It must
    // now ask for the month and retry.
    final create = File(
      'lib/presentation/screens/tribes/create_tribe_screen.dart',
    ).readAsStringSync();
    expect(create, contains('age_verification_required'));
    expect(create, contains('ensureCanCreateTribe(context, ref)'));
    // Once only. A server that keeps refusing must surface as an error rather
    // than an invisible loop between submit and sheet.
    expect(create, contains('_retriedAfterAgeGate'));
  });

  test('signup sends the birth month it already collected', () {
    // The month was collected by the signup date picker and thrown away one
    // layer later — birthYear: birthDate.year and nothing else — which is what
    // made the age gate reachable at all. Both signup paths must send it.
    final repo = File(
      'lib/data/repositories/vently_repository.dart',
    ).readAsStringSync();
    expect(
      'birthMonth: birthDate.month'.allMatches(repo).length,
      greaterThanOrEqualTo(2),
      reason: 'both the username and email signup paths must send the month',
    );
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();
    expect(
      "'birth_month': birthMonth".allMatches(backend).length,
      2,
      reason: 'signUp and signUpWithEmail must both put it in auth metadata',
    );
    // And the trigger has to read it, or the client is talking to itself.
    final migration = File(
      'supabase/migrations/20260930090000_record_birth_month_at_signup.sql',
    ).readAsStringSync();
    expect(migration, contains("meta->>'birth_month'"));
    expect(migration, contains('birth_month'));
  });
}
