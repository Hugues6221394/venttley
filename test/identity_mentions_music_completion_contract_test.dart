import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260827222451_complete_identity_mentions_music_rollout.sql',
    ).readAsStringSync();
  });

  test('identity views append display labels without weakening RLS', () {
    expect(migration, contains('WITH (security_invoker = true)'));
    expect(migration, contains('sender_display_name'));
    expect(migration, contains('reply_sender_display_name'));
    expect(migration, contains('from_display_name'));
    expect(migration, contains('to_display_name'));
    expect(
      migration,
      contains("WHEN m.sender_persona_id IS NOT NULL THEN pr.pseudonym"),
    );
  });

  test('mentions bind immutable user ids in a private table', () {
    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS private.content_mentions'),
    );
    expect(migration, contains('mentioned_user_id UUID NOT NULL'));
    expect(migration, contains('u.username_normalized = v_handle'));
    expect(migration, contains('AFTER INSERT OR UPDATE OF content'));
    expect(
      migration,
      contains(
        'REVOKE ALL ON TABLE private.content_mentions FROM PUBLIC, anon, authenticated',
      ),
    );
  });

  test('music rollout has a kill switch and internal-only default cohort', () {
    expect(migration, contains('rollout_pct = 0'));
    expect(migration, contains('admin_set_user_feature_override'));
    expect(migration, contains('private.feature_enabled_for'));
    expect(migration, contains('music_catalog_section'));
    expect(migration, contains('private.music_track_usage'));
    expect(migration, contains('v_previous_track IS DISTINCT FROM'));
  });

  test('all exposed mutation and catalog functions are auth-bound', () {
    expect(migration, contains('SET search_path = \'\''));
    expect(
      migration,
      contains(
        'REVOKE ALL ON FUNCTION public.music_catalog_section(TEXT, INT)',
      ),
    );
    expect(
      migration,
      contains(
        'REVOKE ALL ON FUNCTION public.admin_set_user_feature_override(UUID, TEXT, BOOLEAN)',
      ),
    );
    expect(
      migration,
      contains("IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'"),
    );
  });
}
