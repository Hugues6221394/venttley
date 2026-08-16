import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260815224342_identity_self_interaction_music.sql',
    ).readAsStringSync();
  });

  test('stable username and safe display-name invariants are server-side', () {
    expect(migration, contains('CREATE TRIGGER users_identity_guard'));
    expect(migration, contains("RAISE EXCEPTION 'username_changes_disabled'"));
    expect(migration, contains('users_username_normalized_unique'));
    expect(migration, contains('users_display_name_normalized_trgm'));
  });

  test('every engagement table is protected from direct hostile writes', () {
    for (final trigger in [
      'no_self_post_reaction',
      'no_self_comment_like',
      'no_self_whisper_reaction',
      'no_self_whisper_comment_like',
      'no_self_poll_vote',
    ]) {
      expect(migration, contains('CREATE TRIGGER $trigger'));
    }
    expect(migration, contains('self_interaction_not_allowed'));
  });

  test('retry-safe desired-state RPCs are authenticated only', () {
    for (final function in [
      'set_post_reaction',
      'set_comment_like',
      'set_whisper_reaction_v2',
      'set_whisper_comment_like',
      'cast_poll_vote',
    ]) {
      expect(migration, contains('public.$function'));
    }
    expect(migration, contains('ON CONFLICT (post_id, user_id) DO UPDATE'));
    expect(migration, contains('FROM PUBLIC, anon'));
  });

  test(
    'music catalog is rights gated, rate limited, and killed by default',
    () {
      expect(migration, contains("'vent_music', FALSE, 0"));
      expect(migration, contains('license_code'));
      expect(migration, contains('rights_expires_at'));
      expect(migration, contains('private.claim_music_quota'));
      expect(migration, contains('public.music_enabled_for_me()'));
      expect(migration, contains("'venttly_original'"));
      expect(migration, contains("'VENTTLY_ORIGINAL'"));
    },
  );

  test('global content search executes with the caller RLS context', () {
    final searchStart = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.search_global',
    );
    final searchEnd = migration.indexOf(
      'REVOKE ALL ON FUNCTION public.search_global',
      searchStart,
    );
    final search = migration.substring(searchStart, searchEnd);
    expect(search, contains('SECURITY INVOKER'));
    expect(search, contains('FROM public.feed_posts AS p'));
    expect(search, contains('FROM public.search_user_hits('));
    expect(search, isNot(contains('private.')));
    expect(search, isNot(contains('FROM public.posts AS p\n')));
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.search_user_hits'),
    );
    expect(
      migration,
      isNot(contains('CREATE OR REPLACE FUNCTION private.search_user_hits')),
    );
    expect(migration, contains('v_viewer UUID := (SELECT auth.uid());'));
    expect(
      migration,
      contains("public.claim_rate_limit('global_search', 60, 120)"),
    );
    expect(migration, isNot(contains('GRANT USAGE ON SCHEMA private')));
  });
}
