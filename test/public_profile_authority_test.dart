import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public profile RPC owns public bio and pronouns', () {
    final migration = File(
      'supabase/migrations/20260727130805_public_profile_bio_authority.sql',
    ).readAsStringSync();
    final backend =
        File('lib/data/services/supabase_backend.dart').readAsStringSync();

    expect(migration, contains("'bio',               u.bio"));
    expect(migration, contains("'pronouns',          u.pronouns"));
    expect(
      migration,
      contains(
        'REVOKE ALL ON FUNCTION public.user_profile_summary(UUID) FROM anon',
      ),
    );
    expect(backend, contains("bio: user['bio'] as String?"));
    expect(backend, contains("pronouns: user['pronouns'] as String?"));
  });

  test('public profile canvas cannot shrink to its floating back button', () {
    final screen = File(
      'lib/presentation/screens/friends/friend_profile_screen.dart',
    ).readAsStringSync();

    expect(screen, contains('fit: StackFit.expand'));
    expect(screen, contains('VentlyPremiumBackground('));
  });

  test('full tribe management is owner-only in Tribe info', () {
    final hub = File(
      'lib/presentation/screens/tribes/tribe_chat_hub_screen.dart',
    ).readAsStringSync();

    expect(hub, contains('final isOwner ='));
    expect(hub, contains('if (isOwner) ...['));
    expect(
      hub,
      contains('_HeroSection(tribe: tribe, canEditIdentity: isOwner)'),
    );
  });
}
