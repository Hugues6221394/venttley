BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(69);

SELECT has_table('public', 'push_delivery_outbox', 'durable push outbox exists');
SELECT is(
  (
    SELECT class.relrowsecurity
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relname = 'push_delivery_outbox'
  ),
  TRUE,
  'push outbox has RLS enabled'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.push_delivery_outbox', 'SELECT'),
  'authenticated clients cannot inspect push routing state'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.enqueue_push_event(text,uuid)', 'EXECUTE'
  ),
  'authenticated clients cannot fan out arbitrary events'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.enqueue_push_event(text,uuid)', 'EXECUTE'
  ),
  'service role can enqueue canonical push events'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.collect_space_mood_counts(uuid)', 'EXECUTE'
  ),
  'aggregate Space summary input is not client-callable'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.collect_space_mood_counts(uuid)', 'EXECUTE'
  ),
  'summary worker can read aggregate mood counts'
);
SELECT ok(
  NOT has_function_privilege(
    'service_role', 'public.collect_space_vent_corpus(uuid,integer)', 'EXECUTE'
  ),
  'summary worker cannot read vent bodies'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_whisper_idempotent(uuid,text,text,integer,text,text,text,text,text,uuid)',
    'EXECUTE'
  ),
  'authenticated clients can create retry-safe Whispers'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.create_whisper_idempotent(uuid,text,text,integer,text,text,text,text,text,uuid)',
    'EXECUTE'
  ),
  'anonymous clients cannot create Whispers'
);
SELECT has_trigger(
  'public', 'posts', 'content_safety_guard_posts',
  'posts have authoritative content safety at ingress'
);
SELECT has_trigger(
  'public', 'chat_messages', 'content_safety_guard_chat_messages',
  'DMs have authoritative content safety at ingress'
);
SELECT has_trigger(
  'public', 'whispers', 'content_safety_guard_whispers',
  'Whisper metadata has authoritative content safety at ingress'
);
SELECT has_trigger(
  'public', 'users', 'prevent_legal_hold_user_delete',
  'account deletion has an authoritative legal-hold guard'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.list_storage_cleanup_candidates(integer)', 'EXECUTE'
  ),
  'clients cannot enumerate orphaned storage objects'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.list_storage_cleanup_candidates(integer)', 'EXECUTE'
  ),
  'cleanup worker can request a bounded canonical candidate list'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.trust_boundary_health()', 'EXECUTE'
  ),
  'clients cannot call the operational health probe'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.trust_boundary_health()', 'EXECUTE'
  ),
  'service monitors can read content-free trust-boundary health'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.claim_email_deliveries(integer)', 'EXECUTE'
  ),
  'clients cannot claim transactional email work'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.claim_email_deliveries(integer)', 'EXECUTE'
  ),
  'the email worker can claim bounded deliveries'
);
SELECT has_table(
  'public', 'stripe_webhook_events',
  'Stripe webhook receipts provide durable deduplication'
);
SELECT ok(
  NOT has_table_privilege(
    'authenticated', 'public.stripe_webhook_events', 'SELECT'
  ),
  'clients cannot inspect Stripe webhook receipts'
);
SELECT has_table(
  'public', 'media_scan_jobs',
  'media scanning has a durable per-resource lease'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.media_scan_jobs', 'SELECT'),
  'clients cannot inspect media scan leases'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.claim_media_scan(text,uuid,uuid,uuid)', 'EXECUTE'
  ),
  'clients cannot claim media work with forged ownership'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.claim_media_scan(text,uuid,uuid,uuid)', 'EXECUTE'
  ),
  'the authenticated media worker can claim canonical pending resources'
);
SELECT ok(
  position(
    'content encrypted' IN pg_get_functiondef(
      'public.admin_safety_queue(boolean,integer)'::REGPROCEDURE
    )
  ) = 0,
  'the staff safety queue makes no false DM encryption claim'
);
SELECT ok(
  position(
    'server-readable; access restricted' IN pg_get_functiondef(
      'public.admin_safety_queue(boolean,integer)'::REGPROCEDURE
    )
  ) > 0,
  'the staff safety queue accurately describes DM handling'
);

INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '81000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'trust-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"trust_a","avatar_seed":"trust-a","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  ),
  (
    '81000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'trust-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"trust_b","avatar_seed":"trust-b","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  ),
  (
    '81000000-0000-4000-8000-000000000003',
    'authenticated', 'authenticated', 'trust-age@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"trust_age","avatar_seed":"trust-age"}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  );

UPDATE public.users
   SET created_at = now() - INTERVAL '2 hours'
 WHERE user_id::TEXT LIKE '81000000-0000-4000-8000-%';

UPDATE public.users
   SET recovery_blob = repeat('a', 80), recovery_salt = repeat('b', 24)
 WHERE user_id = '81000000-0000-4000-8000-000000000001';

INSERT INTO public.chat_rooms (
  room_id, initiated_by, received_by, request_preview, room_status
) VALUES (
  '82000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000002',
  'canonical routing fixture', 'active'
);

INSERT INTO public.chat_messages (
  message_id, room_id, sender_id, encrypted_payload, nonce_iv
) VALUES (
  '83000000-0000-4000-8000-000000000001',
  '82000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000001',
  'private message body must not enter FCM', 'v1-plaintext'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '81000000-0000-4000-8000-000000000003';
SET LOCAL "request.jwt.claims" =
  '{"sub":"81000000-0000-4000-8000-000000000003","role":"authenticated"}';

SELECT throws_ok(
  $$
    SELECT public.create_post_idempotent(
      '84000000-0000-4000-8000-000000000001',
      'age gate fixture', 'confessions', 'healing'
    )
  $$,
  'P0001', 'age_verification_required',
  'an account without a birth year cannot publish through an RPC'
);
SELECT throws_ok(
  format(
    'SELECT public.set_my_birth_year(%s)',
    EXTRACT(YEAR FROM now())::INT - 12
  ),
  'P0001', 'age_below_minimum',
  'the server rejects a declared age below 13'
);
SELECT lives_ok(
  format(
    'SELECT public.set_my_birth_year(%s)',
    EXTRACT(YEAR FROM now())::INT - 16
  ),
  'an eligible account can complete the one-time age flow'
);
SELECT is(
  (
    SELECT safety_tier
      FROM public.users
     WHERE user_id = '81000000-0000-4000-8000-000000000003'
  ),
  'restricted_minor',
  'the server derives the restricted minor tier from birth year'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '81000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"81000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_ok(
  $$
    SELECT public.create_post_idempotent(
      '84000000-0000-4000-8000-000000000002',
      'contact me at attacker@example.com', 'confessions', 'healing'
    )
  $$,
  'P0001', 'content_blocked_privacy',
  'direct RPC writes cannot bypass contact-detail protection'
);
SELECT throws_ok(
  $$
    SELECT public.create_post_idempotent(
      '84000000-0000-4000-8000-000000000003',
      'you should die', 'confessions', 'angry'
    )
  $$,
  'P0001', 'content_blocked_harassment',
  'direct RPC writes cannot bypass harassment protection'
);
SELECT lives_ok(
  $$
    SELECT public.create_post_idempotent(
      '84000000-0000-4000-8000-000000000004',
      'I want to die and need support', 'dark_thoughts', 'broken'
    )
  $$,
  'self-harm language remains publishable so support stays reachable'
);
SELECT is(
  (
    SELECT crisis_level
      FROM public.posts
     WHERE author_id = '81000000-0000-4000-8000-000000000001'
       AND content = 'I want to die and need support'
  ),
  'high',
  'self-harm language is tagged authoritatively at ingress'
);

CREATE TEMP TABLE trust_results (
  result_key TEXT PRIMARY KEY,
  resource_id UUID NOT NULL
) ON COMMIT DROP;

INSERT INTO trust_results VALUES (
  'whisper-first',
  public.create_whisper_idempotent(
    '84000000-0000-4000-8000-000000000005',
    '81000000-0000-4000-8000-000000000001/one.m4a',
    'https://media.venttly.test/one.m4a', 12, 'confessions'
  )
);
INSERT INTO trust_results VALUES (
  'whisper-retry',
  public.create_whisper_idempotent(
    '84000000-0000-4000-8000-000000000005',
    '81000000-0000-4000-8000-000000000001/one.m4a',
    'https://media.venttly.test/one.m4a', 12, 'confessions'
  )
);
SELECT is(
  (SELECT resource_id FROM trust_results WHERE result_key = 'whisper-first'),
  (SELECT resource_id FROM trust_results WHERE result_key = 'whisper-retry'),
  'a lost-response Whisper retry returns the original resource'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.whispers
     WHERE author_id = '81000000-0000-4000-8000-000000000001'
       AND audio_path = '81000000-0000-4000-8000-000000000001/one.m4a'
  ),
  1::BIGINT,
  'a lost-response Whisper retry creates one row'
);
SELECT lives_ok(
  $$
    DO $block$
    BEGIN
      FOR index IN 2..10 LOOP
        PERFORM public.create_whisper(
          '81000000-0000-4000-8000-000000000001/' || index || '.m4a',
          'https://media.venttly.test/' || index || '.m4a',
          12, 'confessions'
        );
      END LOOP;
    END
    $block$
  $$,
  'the documented Whisper hourly allowance succeeds'
);
SELECT throws_ok(
  $$
    SELECT public.create_whisper(
      '81000000-0000-4000-8000-000000000001/eleven.m4a',
      'https://media.venttly.test/eleven.m4a', 12, 'confessions'
    )
  $$,
  'P0001', NULL,
  'Whisper rate limiting is enforced in Postgres'
);

RESET ROLE;
INSERT INTO public.email_outbox (
  outbox_id, user_id, template, variables
) VALUES (
  '85000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000001',
  'welcome', '{"pseudonym":"trust_a"}'::JSONB
);
SET LOCAL ROLE service_role;
CREATE TEMP TABLE claimed_push (
  delivery_id UUID,
  attempts INT,
  user_id UUID,
  event_kind TEXT,
  event_data JSONB
) ON COMMIT DROP;
CREATE TEMP TABLE claimed_email (
  outbox_id UUID,
  user_id UUID,
  template TEXT,
  variables JSONB,
  attempts INT
) ON COMMIT DROP;
SELECT is(
  public.enqueue_push_event(
    'chat_messages', '83000000-0000-4000-8000-000000000001'
  ),
  1,
  'the first canonical webhook event enqueues one recipient'
);
SELECT is(
  public.enqueue_push_event(
    'chat_messages', '83000000-0000-4000-8000-000000000001'
  ),
  0,
  'a duplicate webhook event does not duplicate the outbox row'
);
INSERT INTO claimed_push SELECT * FROM public.claim_push_deliveries(1);
SELECT is(
  (SELECT attempts FROM claimed_push),
  1,
  'the first push lease has attempt number one'
);
SELECT lives_ok(
  $$
    SELECT public.complete_push_delivery(
      (SELECT delivery_id FROM claimed_push), 0, true, NULL
    )
  $$,
  'a stale worker completion is harmless'
);
INSERT INTO claimed_email SELECT * FROM public.claim_email_deliveries(1);
SELECT is(
  (SELECT attempts FROM claimed_email),
  1,
  'transactional email is leased exactly once per attempt'
);
SELECT lives_ok(
  $$
    SELECT public.complete_email_delivery(
      (SELECT outbox_id FROM claimed_email), 1, 'sent', NULL
    )
  $$,
  'the email lease holder can record provider acceptance'
);

RESET ROLE;
SELECT is(
  (
    SELECT status
      FROM public.push_delivery_outbox
     WHERE delivery_id = (SELECT delivery_id FROM claimed_push)
  ),
  'processing',
  'a stale worker cannot complete a newer lease'
);
SELECT is(
  (
    SELECT status FROM public.email_outbox
     WHERE outbox_id = '85000000-0000-4000-8000-000000000001'
  ),
  'sent',
  'a completed email lease persists the terminal state'
);
SET LOCAL ROLE service_role;
SELECT lives_ok(
  $$
    SELECT public.complete_push_delivery(
      (SELECT delivery_id FROM claimed_push), 1, true, NULL
    )
  $$,
  'the current lease holder can complete delivery'
);
SELECT is(
  public.apply_stripe_subscription_event(
    'evt_trust_new', 200, 'customer.subscription.updated', 'sub_trust',
    '81000000-0000-4000-8000-000000000001', 'cus_trust',
    'active', 'plus', 'price_plus', NULL, NULL, NULL, NULL
  ),
  TRUE,
  'a new signed Stripe event applies subscription state'
);
SELECT is(
  public.apply_stripe_subscription_event(
    'evt_trust_new', 200, 'customer.subscription.updated', 'sub_trust',
    '81000000-0000-4000-8000-000000000001', 'cus_trust',
    'active', 'plus', 'price_plus', NULL, NULL, NULL, NULL
  ),
  FALSE,
  'a duplicate Stripe event is idempotent'
);
SELECT is(
  public.apply_stripe_subscription_event(
    'evt_trust_old', 100, 'customer.subscription.updated', 'sub_trust',
    '81000000-0000-4000-8000-000000000001', 'cus_trust',
    'canceled', 'free', NULL, NULL, NULL, NULL, NULL
  ),
  FALSE,
  'an older Stripe event cannot overwrite newer state'
);

UPDATE public.posts
   SET image_path =
         '81000000-0000-4000-8000-000000000001/scan-fixture.jpg',
       image_url = 'https://media.venttly.test/scan-fixture.jpg',
       media_status = 'pending'
 WHERE author_id = '81000000-0000-4000-8000-000000000001'
   AND content = 'I want to die and need support';
SELECT is(
  public.claim_media_scan(
    'post',
    (
      SELECT post_id FROM public.posts
       WHERE author_id = '81000000-0000-4000-8000-000000000001'
         AND content = 'I want to die and need support'
    ),
    '81000000-0000-4000-8000-000000000001',
    '87000000-0000-4000-8000-000000000001'
  ),
  'claimed',
  'the media worker can claim one canonical pending resource'
);
SELECT is(
  public.claim_media_scan(
    'post',
    (
      SELECT post_id FROM public.posts
       WHERE author_id = '81000000-0000-4000-8000-000000000001'
         AND content = 'I want to die and need support'
    ),
    '81000000-0000-4000-8000-000000000002',
    '87000000-0000-4000-8000-000000000002'
  ),
  'invalid',
  'a forged media owner cannot claim another account resource'
);
SELECT is(
  public.claim_media_scan(
    'post',
    (
      SELECT post_id FROM public.posts
       WHERE author_id = '81000000-0000-4000-8000-000000000001'
         AND content = 'I want to die and need support'
    ),
    '81000000-0000-4000-8000-000000000001',
    '87000000-0000-4000-8000-000000000003'
  ),
  'busy',
  'a duplicate media request cannot create a concurrent provider scan'
);
SELECT is(
  public.complete_media_scan_verdict(
    'post',
    (
      SELECT post_id FROM public.posts
       WHERE author_id = '81000000-0000-4000-8000-000000000001'
         AND content = 'I want to die and need support'
    ),
    '81000000-0000-4000-8000-000000000001',
    '87000000-0000-4000-8000-000000000001',
    'clean', '{"sexual":0,"suggestive":0,"gore":0}'::JSONB
  ),
  TRUE,
  'only the active media lease can commit its verdict'
);

RESET ROLE;
SELECT is(
  (SELECT status FROM public.subscriptions WHERE subscription_id = 'sub_trust'),
  'active',
  'subscription state remains at the canonical newer value'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.push_delivery_outbox
     WHERE event_key = 'chat_messages:83000000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'the push outbox contains one durable recipient delivery'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
      FROM public.push_delivery_outbox
     WHERE event_data::TEXT LIKE '%private message body%'
  ),
  'push routing data contains no message preview'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '81000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"81000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT is(
  public.export_my_data() #>> '{direct_messages,0,body}',
  'private message body must not enter FCM',
  'DSAR truthfully includes the caller server-readable DM body'
);
SELECT is(
  (SELECT recovery_blob FROM public.get_my_recovery_material()),
  repeat('a', 80),
  'owner can retrieve the currently sealed recovery material'
);
SELECT lives_ok(
  $$
    SELECT public.rotate_my_recovery_material(repeat('c', 80), repeat('d', 24))
  $$,
  'owner can rotate recovery material after a password change'
);
SELECT is(
  (SELECT recovery_blob FROM public.get_my_recovery_material()),
  repeat('c', 80),
  'subsequent recovery reads return the rotated blob'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.server_text_safety(text)', 'EXECUTE'
  ),
  'clients cannot probe the private moderation helper directly'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.get_my_recovery_material()', 'EXECUTE'
  ),
  'anonymous callers cannot read recovery material'
);

SELECT lives_ok(
  $$
    SELECT public.register_push_token(
      'shared-device-token-0001', 'android', 'en', '1.0.0'
    )
  $$,
  'a signed-in account can bind its installation token'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '81000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"81000000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT lives_ok(
  $$
    SELECT public.register_push_token(
      'shared-device-token-0001', 'android', 'en', '1.0.0'
    )
  $$,
  'account switching atomically rebinds the installation token'
);

RESET ROLE;
SELECT is(
  (
    SELECT user_id
      FROM public.push_tokens
     WHERE token = 'shared-device-token-0001'
  ),
  '81000000-0000-4000-8000-000000000002'::UUID,
  'an installation token belongs only to the current account'
);

INSERT INTO public.csam_incidents (
  kind, content_ref, author_id, status
) VALUES (
  'post', '86000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000002', 'detected'
);
SELECT throws_ok(
  $$
    DELETE FROM public.users
     WHERE user_id = '81000000-0000-4000-8000-000000000002'
  $$,
  'P0001', 'legal_hold_active',
  'a concurrent legal hold prevents destructive account purge'
);

SELECT * FROM finish();
ROLLBACK;
