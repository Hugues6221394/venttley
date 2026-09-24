import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/user_profile_link.dart';
import 'package:vently_app/presentation/widgets/verified_badge.dart';

/// Where the tick reaches.
///
/// "Verification only comes to their usernames" had two causes, and only one
/// of them was a missing badge. The other was UserProfileLink — the widget
/// that renders "avatar + name" on fifteen screens — forwarding
/// showVerifiedBadge to the avatar alone, which draws a small pip on the
/// corner of the picture. Its name half could not carry a tick no matter what
/// any caller passed.
void main() {
  Future<void> pumpLink(
    WidgetTester tester, {
    required bool verified,
    bool showName = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VentlyTheme.dark(pureBlack: true),
        home: Scaffold(
          body: UserProfileLink(
            userId: 'u1',
            pseudonym: 'knownperson',
            displayName: 'Known Person',
            avatarSeed: 'seed',
            showName: showName,
            showVerifiedBadge: verified,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a verified person is ticked beside their name', (tester) async {
    await pumpLink(tester, verified: true);

    expect(find.text('Known Person'), findsOneWidget);
    expect(
      find.byType(VerifiedBadge),
      findsOneWidget,
      reason: 'the name half could never show one before',
    );
  });

  testWidgets('an unverified person is not', (tester) async {
    await pumpLink(tester, verified: false);
    expect(find.byType(VerifiedBadge), findsNothing);
  });

  testWidgets('and an avatar with no name does not sprout a stray tick', (
    tester,
  ) async {
    // showName: false is the bare-avatar form, used in rails and stacks. The
    // pip belongs to ProfileAvatar there; a second badge floating beside
    // nothing would be a rendering bug.
    await pumpLink(tester, verified: true, showName: false);
    expect(find.byType(VerifiedBadge), findsNothing);
  });

  group('the entities that carry it', () {
    test('a chat room knows whether its peer is verified', () {
      // inbox_rooms joined users at both ends of a direct room and took the
      // pseudonym, the seed and the photo — never is_verified. So the list
      // people open most was the one surface with no tick at all.
      final plain = ChatRoom(
        roomId: 'r1',
        peerPseudonym: '@someone',
        peerAvatarSeed: 'seed',
        requestPreview: '',
        roomStatus: 'active',
        createdAt: DateTime(2026, 1, 1),
        initiatedByMe: true,
      );
      expect(plain.peerIsVerified, isFalse);
    });

    test('a search hit knows, and defaults to not verified', () {
      const hit = SearchHit(
        hitKind: 'tribe',
        hitId: 't1',
        title: 'A Tribe',
        subtitle: '',
        rankScore: 1,
      );
      expect(
        hit.isVerified,
        isFalse,
        reason: 'a tribe is not a person and cannot be verified',
      );
    });
  });

  test('a persona never carries a tick, anywhere', () {
    // A persona exists to hide who somebody is. Attaching a checked identity
    // to one would defeat the entire point, so both places that could have
    // leaked it — the post arm of search, and whisper comments — resolve to
    // false when a persona is in play. Asserted against the SQL, because that
    // is where the rule lives.
    final sql = File(
      'supabase/migrations/20261049090000_a_tick_travels_with_the_name.sql',
    ).readAsStringSync();

    expect(
      sql,
      contains(
        'CASE WHEN p.persona_id IS NULL\n'
        '                THEN COALESCE(u.is_verified, FALSE) ELSE FALSE END',
      ),
      reason: 'the post arm of search must not tick a persona',
    );
    expect(
      sql,
      contains('CASE WHEN c.persona_id IS NULL'),
      reason: 'nor must a whisper comment',
    );
  });
}
