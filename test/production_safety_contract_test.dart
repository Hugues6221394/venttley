import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('server-only secret names never enter Flutter source', () {
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final source = dartFiles.map((file) => file.readAsStringSync()).join('\n');

    expect(source, isNot(contains('GROQ_API_KEY')));
    expect(source, isNot(contains('SUPABASE_SERVICE_ROLE_KEY')));
    expect(source, isNot(contains('api.groq.com')));

    final readme = File('README.md').readAsStringSync();
    expect(readme, isNot(contains('--dart-define=GROQ_API_KEY')));
    expect(readme, contains('Service secrets'));

    final edgeHandler = File(
      'supabase/functions/moderate/handler.ts',
    ).readAsStringSync();
    expect(edgeHandler, isNot(contains('api.groq.com')));
    expect(edgeHandler, isNot(contains('GROQ_API_KEY')));
  });

  test('new public read surfaces use caller RLS and explicit grants', () {
    final antiSpam = File(
      'supabase/migrations/0117_rate_limiting_antispam.sql',
    ).readAsStringSync();
    final flags = File(
      'supabase/migrations/0118_feature_flags.sql',
    ).readAsStringSync();
    final search = File(
      'supabase/migrations/0119_search_upgrade.sql',
    ).readAsStringSync();

    expect(antiSpam, contains('WITH (security_invoker = true)'));
    expect(flags, contains('GRANT SELECT ON TABLE public.feature_flags'));
    expect(flags, contains('SECURITY INVOKER'));
    expect(search, contains('SECURITY INVOKER'));
    expect(
      search,
      contains('GRANT EXECUTE ON FUNCTION public.search_suggestions'),
    );
  });

  test('remote moderation is authenticated, bounded, and rate limited', () {
    final entrypoint = File(
      'supabase/functions/moderate/index.ts',
    ).readAsStringSync();
    final handler = File(
      'supabase/functions/moderate/handler.ts',
    ).readAsStringSync();
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) => file.path.endsWith('_moderation_request_quota.sql'),
        )
        .readAsStringSync();

    expect(entrypoint, contains('createModerationHandler'));
    expect(handler, contains('request.method !== "POST"'));
    expect(handler, contains('client.auth.getUser('));
    expect(handler, contains('consume_moderation_quota'));
    expect(handler, contains('MAX_TEXT_LENGTH'));
    expect(handler, contains('if (result === null)'));
    expect(migration, contains('ENABLE ROW LEVEL SECURITY'));
    expect(migration, contains('TO service_role'));
  });

  test('retryable social writes have server-side idempotency receipts', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) => file.path.endsWith('_idempotent_social_writes.sql'),
        )
        .readAsStringSync();
    final outbox = File('lib/data/services/outbox.dart').readAsStringSync();
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();

    expect(migration, contains('private.client_mutation_receipts'));
    expect(migration, contains('pg_advisory_xact_lock'));
    expect(migration, contains('create_post_idempotent'));
    expect(migration, contains('create_threaded_comment_idempotent'));
    expect(migration, contains('add_whisper_comment_idempotent'));
    expect(migration, contains('send_tribe_message_idempotent'));
    expect(migration, contains('send_chat_message_idempotent'));
    expect(migration, contains('ON DELETE CASCADE'));
    expect(outbox, contains('idempotencyKey: operation.id'));
    expect(backend, contains("'p_mutation_id': idempotencyKey"));
  });

  test('DM replies reuse the active-room send guard', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) => file.path.endsWith('_idempotent_social_writes.sql'),
        )
        .readAsStringSync();

    expect(migration, contains('FROM public.send_chat_message('));
    expect(migration, contains('parent message does not belong to this room'));
  });

  test('pending attachments are encrypted and owned by the retry queue', () {
    final media = File(
      'lib/data/services/pending_media_store.dart',
    ).readAsStringSync();
    final outbox = File('lib/data/services/outbox.dart').readAsStringSync();

    expect(media, contains('AesGcm.with256bits()'));
    expect(media, contains('Pending media path is outside'));
    expect(outbox, contains('await _uploadPendingMedia('));
    expect(outbox, contains('await _deleteLocalMedia(operation)'));
    expect(outbox, contains("payload['localMediaPath']"));
  });

  test('DM voice notes are accepted only through the canonical room guard', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere((file) => file.path.endsWith('_dm_voice_reliability.sql'))
        .readAsStringSync();

    expect(migration, contains("p_media_type NOT IN ('image', 'audio')"));
    expect(migration, contains("v_room.room_status <> 'active'"));
    expect(migration, contains('media path must be in room prefix'));
    expect(migration, contains('attached post not found or not readable'));
  });

  test('anonymous callers cannot execute privileged database functions', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) => file.path.endsWith(
            '_revoke_anonymous_security_definer_execution.sql',
          ),
        )
        .readAsStringSync();

    expect(migration, contains('AND p.prosecdef'));
    expect(migration, contains('FROM PUBLIC, anon'));
    expect(migration, contains('TO authenticated, service_role'));
    expect(migration, contains('REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC'));
  });

  test('every reported public foreign key receives a covering index', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) => file.path.endsWith('_add_missing_foreign_key_indexes.sql'),
        )
        .readAsStringSync();

    expect(
      RegExp(
        r'CREATE INDEX IF NOT EXISTS idx_fk_',
      ).allMatches(migration).length,
      57,
    );
    expect(migration, contains('idx_fk_post_likes_user_id'));
    expect(migration, contains('idx_fk_notifications_actor_id'));
    expect(migration, contains('idx_fk_tribe_members_user_id'));
    expect(migration, contains('idx_fk_whispers_author_id'));
    expect(migration, isNot(contains('ON storage.')));
  });

  test('RLS auth lookup optimization preserves existing policy contracts', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere((file) => file.path.endsWith('_cache_rls_auth_lookups.sql'))
        .readAsStringSync();

    expect(migration, contains('ALTER POLICY %I ON %I.%I'));
    expect(migration, contains('( SELECT auth.uid() AS uid)'));
    expect(migration, contains('USING (%s)'));
    expect(migration, contains('WITH CHECK (%s)'));
    expect(migration, isNot(contains('DROP POLICY')));
    expect(migration, isNot(contains('CREATE POLICY')));
  });

  test('hot-feed cache is private behind a role-checked admin probe', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .firstWhere(
          (file) =>
              file.path.endsWith('_protect_hot_posts_materialized_view.sql'),
        )
        .readAsStringSync();
    final adminSystem = File(
      'admin/app/(dashboard)/system/page.tsx',
    ).readAsStringSync();

    expect(
      migration,
      contains(
        'REVOKE SELECT ON public.mv_hot_posts FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(migration, contains('public.admin_hot_feed_health'));
    expect(migration, contains("'super_admin', 'admin'"));
    expect(migration, contains('FROM PUBLIC, anon'));
    expect(adminSystem, contains('rpc("admin_hot_feed_health")'));
    expect(adminSystem, isNot(contains('.from("mv_hot_posts")')));
  });

  test('privileged trigger functions are not exposed as client RPCs', () {
    final migration = File(
      'supabase/migrations/'
      '20260728164933_restrict_trigger_function_execution.sql',
    ).readAsStringSync();

    expect(migration, contains("'pg_catalog.trigger'::pg_catalog.regtype"));
    expect(
      migration,
      contains("'pg_catalog.event_trigger'::pg_catalog.regtype"),
    );
    expect(
      migration,
      contains(
        'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO service_role'),
    );
  });
}
