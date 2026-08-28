BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(34);

SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.bump_whisper_plays(uuid)', 'EXECUTE'
  ),
  'signed-in callers cannot use the legacy non-deduplicated play counter'
);
SELECT ok(
  NOT has_function_privilege('anon', 'public.bump_whisper_plays(uuid)', 'EXECUTE'),
  'anonymous callers cannot use the legacy play counter'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.record_whisper_listen(uuid)', 'EXECUTE'
  ),
  'signed-in listeners retain the canonical deduplicated listen RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.increment_prompt_answers(uuid)', 'EXECUTE'
  ),
  'clients cannot increment a derived answer counter'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.queue_email(text,uuid,jsonb)', 'EXECUTE'
  ),
  'clients cannot choose arbitrary transactional email templates'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.queue_email(text,uuid,jsonb)', 'EXECUTE'
  ),
  'trusted email workers retain the internal queue primitive'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.request_email_verification()', 'EXECUTE'
  ),
  'clients retain the bounded purpose-specific verification flow'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.mark_email_verified()', 'EXECUTE'
  ),
  'provider-backed accounts retain the verification completion RPC'
);
SELECT has_trigger(
  'public', 'prompt_answers', 'maintain_prompt_answers_count',
  'prompt answer rows maintain their counter transactionally'
);
SELECT has_trigger(
  'public', 'posts', 'preserve_crisis_classification',
  'post crisis classifications cannot be silently downgraded'
);
SELECT has_trigger(
  'public', 'tribe_messages', 'preserve_crisis_classification',
  'tribe-message crisis classifications cannot be silently downgraded'
);
SELECT has_trigger(
  'public', 'chat_messages', 'preserve_crisis_classification',
  'DM crisis classifications cannot be silently downgraded'
);
SELECT has_trigger(
  'public', 'whispers', 'preserve_crisis_classification',
  'Whisper crisis classifications cannot be silently downgraded'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.maintain_prompt_answers_count()', 'EXECUTE'
  ),
  'the prompt counter trigger helper is not an API RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.preserve_crisis_classification()', 'EXECUTE'
  ),
  'the crisis guard trigger helper is not an API RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.sanitize_event_props(jsonb)', 'EXECUTE'
  ),
  'the telemetry sanitizer is not an API RPC'
);
SELECT is(
  (
    SELECT count(*)
      FROM public.plug_prompts
     WHERE is_active
       AND NOT (
         (plug_id IS NOT NULL AND author_id IS NULL)
         OR (plug_id IS NULL AND author_id IS NOT NULL)
       )
  ),
  0::BIGINT,
  'legacy prompts with no authoritative owner are quarantined'
);

INSERT INTO auth.users (
  id, aud, role, email, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
  (
    '91000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'boundary-email@id.venttly.app',
    NULL, NULL,
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"boundary_email","avatar_seed":"boundary-email","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  ),
  (
    '91000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', NULL,
    '+250788123987', now() - INTERVAL '1 minute',
    '{"provider":"phone","providers":["phone"]}'::JSONB,
    '{"pseudonym":"boundary_phone","avatar_seed":"boundary-phone","birth_year":2000}'::JSONB,
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
  );

UPDATE public.users
   SET created_at = now() - INTERVAL '2 hours'
 WHERE user_id::TEXT LIKE '91000000-0000-4000-8000-%';

INSERT INTO public.plug_profiles(plug_id, display_name, approved_at)
VALUES (
  '91000000-0000-4000-8000-000000000002',
  'Boundary Plug', now()
);
INSERT INTO public.plug_prompts(prompt_id, plug_id, prompt_text)
VALUES (
  '92000000-0000-4000-8000-000000000001',
  '91000000-0000-4000-8000-000000000002',
  'What helped today?'
);

CREATE TEMP TABLE boundary_ids (
  result_key TEXT PRIMARY KEY,
  resource_id UUID NOT NULL
) ON COMMIT DROP;
GRANT SELECT, INSERT ON boundary_ids TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '91000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_ok(
  'SELECT public.mark_email_verified()',
  'P0001', 'provider_identity_not_verified',
  'an email/password caller cannot self-assert provider verification'
);
RESET ROLE;
SELECT is(
  (SELECT email_verified FROM public.users
    WHERE user_id = '91000000-0000-4000-8000-000000000001'),
  FALSE,
  'a rejected verification claim leaves the profile unverified'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '91000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT lives_ok(
  'SELECT public.mark_email_verified()',
  'a server-confirmed phone identity can complete verification'
);
RESET ROLE;
SELECT is(
  (SELECT email_verified FROM public.users
    WHERE user_id = '91000000-0000-4000-8000-000000000002'),
  TRUE,
  'provider-backed verification persists on the matching profile'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '91000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$
    INSERT INTO public.prompt_answers(
      answer_id, prompt_id, author_id, answer_text
    ) VALUES (
      '92000000-0000-4000-8000-000000000002',
      '92000000-0000-4000-8000-000000000001',
      '91000000-0000-4000-8000-000000000001',
      'A quiet conversation.'
    )
  $$,
  'an eligible user can insert an answer without a second counter RPC'
);
RESET ROLE;
SELECT is(
  (SELECT answers_count FROM public.plug_prompts
    WHERE prompt_id = '92000000-0000-4000-8000-000000000001'),
  1,
  'the answer insert increments the counter exactly once'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '91000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$
    DELETE FROM public.prompt_answers
     WHERE answer_id = '92000000-0000-4000-8000-000000000002'
  $$,
  'the answer author can delete their row'
);
RESET ROLE;
SELECT is(
  (SELECT answers_count FROM public.plug_prompts
    WHERE prompt_id = '92000000-0000-4000-8000-000000000001'),
  0,
  'the answer delete decrements the counter exactly once'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '91000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$
    INSERT INTO boundary_ids(result_key, resource_id)
    SELECT 'event', public.record_event(
      'boundary.test', 'info',
      '{"message":"private confession","category":"healing","unknown":"discard me"}'::JSONB
    )
  $$,
  'a valid outcome event is recorded'
);
RESET ROLE;
SELECT ok(
  NOT (
    SELECT props ? 'message'
      FROM public.app_events
     WHERE event_id = (SELECT resource_id FROM boundary_ids WHERE result_key = 'event')
  ),
  'user-authored message content is stripped from telemetry server-side'
);
SELECT is(
  (
    SELECT props->>'category'
      FROM public.app_events
     WHERE event_id = (SELECT resource_id FROM boundary_ids WHERE result_key = 'event')
  ),
  'healing',
  'an approved outcome dimension is retained'
);
SELECT ok(
  NOT (
    SELECT props ? 'unknown'
      FROM public.app_events
     WHERE event_id = (SELECT resource_id FROM boundary_ids WHERE result_key = 'event')
  ),
  'unknown analytics dimensions are discarded'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '91000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"91000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT throws_ok(
  $$SELECT public.record_event('invalid event name', 'info', '{}'::JSONB)$$,
  'P0001', 'invalid_event_name',
  'malformed event names are rejected'
);
SELECT throws_ok(
  $$
    SELECT public.record_event(
      'boundary.too_large', 'info',
      pg_catalog.jsonb_build_object('unknown', pg_catalog.repeat('x', 17000))
    )
  $$,
  'P0001', 'event_props_too_large',
  'oversized hostile telemetry payloads are rejected before storage'
);

INSERT INTO boundary_ids(result_key, resource_id)
SELECT 'post', public.create_post_idempotent(
  '92000000-0000-4000-8000-000000000003',
  'I want to die and need support', 'dark_thoughts', 'broken'
);
SELECT throws_ok(
  $$
    SELECT public.set_post_crisis(
      (SELECT resource_id FROM boundary_ids WHERE result_key = 'post'), NULL
    )
  $$,
  'P0001', 'invalid_crisis_level',
  'an author cannot clear a crisis classification through the hint RPC'
);
SELECT lives_ok(
  $$
    SELECT public.set_post_crisis(
      (SELECT resource_id FROM boundary_ids WHERE result_key = 'post'), 'elevated'
    )
  $$,
  'an author moderation hint remains accepted'
);
RESET ROLE;
SELECT is(
  (
    SELECT crisis_level
      FROM public.posts
     WHERE post_id = (SELECT resource_id FROM boundary_ids WHERE result_key = 'post')
  ),
  'high',
  'a lower client hint cannot downgrade a server-applied high classification'
);

SELECT * FROM finish();
ROLLBACK;
