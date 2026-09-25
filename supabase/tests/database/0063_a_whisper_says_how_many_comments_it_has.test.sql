-- The number on a whisper, and the comments underneath it.
--
-- Reported from the phone: "3 comments", open the sheet, nothing there. The
-- counter was incremented and decremented by hand from two of the four events
-- that change it, so a hard delete left it high and a restore left it low, and
-- anything that wrote the column directly was believed forever.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(8);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('ccf10000-0000-4000-8000-000000000001',
        '00000000-0000-0000-0000-000000000000','authenticated','authenticated',
        'whispercount@id.venttly.app','x', now(),'{}','{}',
        now() - INTERVAL '2 years', now(),'','','','','','','','');

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ccf10000-0000-4000-8000-000000000001','whispercounter','x','x',
        'Counter','counter','whispercounter','normal','active',1990);

INSERT INTO public.whispers (whisper_id, author_id, audio_path, audio_url,
                             audio_duration_seconds, category_name, comments_count)
VALUES ('ccf1aaaa-0000-4000-8000-000000000001',
        'ccf10000-0000-4000-8000-000000000001',
        'a.m4a','http://example.test/a.m4a', 30, 'mental_health',
        -- The reported state: a number with nothing behind it. Seeded here the
        -- way it was seeded there, by writing the column.
        3);

-- The content guard refuses a write from somebody who has not accepted the
-- current policies, which is right and is not what this test is about.
INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT 'ccf10000-0000-4000-8000-000000000001', c.kind, c.version
  FROM public.current_policies() c
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;

-- Nothing has touched the comments yet, so the lie is still in place. This is
-- the shape of the bug rather than a claim about the fix.
SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  3,
  'a count written straight into the column stays until something recomputes it'
);

-- One comment. A recompute puts the number right even though it arrived at a
-- wrong one: the old counter would have said four.
INSERT INTO public.whisper_comments (comment_id, whisper_id, author_id, content)
VALUES ('ccf1bbbb-0000-4000-8000-000000000001',
        'ccf1aaaa-0000-4000-8000-000000000001',
        'ccf10000-0000-4000-8000-000000000001','first');

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  1,
  'one comment is one comment, whatever the column said before'
);

INSERT INTO public.whisper_comments (comment_id, whisper_id, author_id, content)
VALUES ('ccf1bbbb-0000-4000-8000-000000000002',
        'ccf1aaaa-0000-4000-8000-000000000001',
        'ccf10000-0000-4000-8000-000000000001','second');

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  2,
  'and two is two'
);

-- Soft delete, which the old counter did handle.
UPDATE public.whisper_comments SET deleted_at = now()
 WHERE comment_id = 'ccf1bbbb-0000-4000-8000-000000000002';

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  1,
  'a deleted comment stops being counted'
);

-- Restoring one, which it did not.
UPDATE public.whisper_comments SET deleted_at = NULL
 WHERE comment_id = 'ccf1bbbb-0000-4000-8000-000000000002';

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  2,
  'and a restored one is counted again'
);

-- A hard delete, which is the path that produced the report: comments are
-- removed outright when an account is deleted or a whisper is purged, and the
-- old trigger was never asked.
DELETE FROM public.whisper_comments
 WHERE comment_id = 'ccf1bbbb-0000-4000-8000-000000000002';

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  1,
  'a comment deleted outright stops being counted'
);

DELETE FROM public.whisper_comments
 WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001';

SELECT is(
  (SELECT comments_count FROM public.whispers
    WHERE whisper_id = 'ccf1aaaa-0000-4000-8000-000000000001'),
  0,
  'and an empty comment section says nothing, not three'
);

-- The trigger has to be asked about all four events, or the next rewrite of
-- the function quietly loses two of them again.
SELECT is(
  (SELECT count(*)::INT
     FROM pg_trigger t
    WHERE t.tgrelid = 'public.whisper_comments'::regclass
      AND t.tgname = 'whisper_comments_count_trg'
      AND pg_get_triggerdef(t.oid) LIKE '%INSERT OR DELETE OR UPDATE OF deleted_at%'),
  1,
  'the counter fires on insert, delete and both directions of soft delete'
);

SELECT * FROM finish();
ROLLBACK;
