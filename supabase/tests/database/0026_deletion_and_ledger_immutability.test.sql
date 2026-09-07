BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(8);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('bbb10000-0000-4000-8000-000000000001','delsuper','delsuper','x',
        'delsuper','delsuper','delsuper','super_admin','active',1990),
       -- A member who has signed in on a device: the ordinary case, and the
       -- one that could not be deleted.
       ('bbb10000-0000-4000-8000-000000000002','delmember','delmember','x',
        'delmember','delmember','delmember','normal','active',1995),
       -- A staff member who has taken an audited action.
       ('bbb10000-0000-4000-8000-000000000003','delstaff','delstaff','x',
        'delstaff','delstaff','delstaff','moderator','active',1990);

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('bbb10000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','delmember@id.venttly.app','x', now(),
        '{}','{}', now(), now(), '','','','','','','','');

INSERT INTO public.user_devices (device_row_id, user_id, device_id, device_type)
VALUES ('bbb20000-0000-4000-8000-000000000001','bbb10000-0000-4000-8000-000000000002',
        repeat('f',40),'phone');

-- Signing in writes this. It is why deletion failed.
INSERT INTO public.security_events (user_id, kind, device_row_id)
VALUES ('bbb10000-0000-4000-8000-000000000002','login','bbb20000-0000-4000-8000-000000000001');

INSERT INTO public.audit_log (actor_id, actor_pseudonym, actor_role, action, target_type)
VALUES ('bbb10000-0000-4000-8000-000000000003','delstaff','moderator','probe.action','user');

SET session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- Deletion works again
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"bbb10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

-- Before this fix admin_delete_user raised "security_events is append-only"
-- for any member who had ever logged in, so the console's Delete user button
-- could not fulfil a deletion request at all.
SELECT lives_ok(
  $$SELECT public.admin_delete_user('bbb10000-0000-4000-8000-000000000002', 'deletion request')$$,
  'a member who has signed in on a device can be deleted'
);

RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.users
    WHERE user_id = 'bbb10000-0000-4000-8000-000000000002'),
  0, 'the account is actually gone'
);

-- The member's own login history goes with the account: it is their personal
-- data, and erasure is the point of a deletion request.
SELECT is(
  (SELECT count(*)::int FROM public.security_events
    WHERE user_id = 'bbb10000-0000-4000-8000-000000000002'),
  0, 'the deleted account takes its own security events with it'
);

-- But the record of what staff did survives, and still names who did it. An
-- audit trail that forgets its actor when the target leaves is not one.
SELECT is(
  (SELECT actor_id FROM public.audit_log
    WHERE action = 'user.delete'
      AND target_id = 'bbb10000-0000-4000-8000-000000000002'),
  'bbb10000-0000-4000-8000-000000000001'::uuid,
  'the deletion is audited and the actor is retained'
);

-- Staff offboarding: the original report. A staff account with audit rows
-- could not be deleted, because the cascade tried to null actor_id.
SELECT lives_ok(
  $$DELETE FROM public.users WHERE user_id = 'bbb10000-0000-4000-8000-000000000003'$$,
  'a staff account that has taken audited actions can be deleted'
);

SELECT is(
  (SELECT actor_pseudonym FROM public.audit_log WHERE action = 'probe.action'),
  'delstaff',
  'their audited actions survive them, still attributed'
);

-- ---------------------------------------------------------------------------
-- None of that weakened the ledgers
-- ---------------------------------------------------------------------------
SET session_replication_role = replica;
INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('bbb10000-0000-4000-8000-000000000004','immprobe','immprobe','x',
        'immprobe','immprobe','immprobe','normal','active',1995);
INSERT INTO public.security_events (user_id, kind)
VALUES ('bbb10000-0000-4000-8000-000000000004','login');
SET session_replication_role = origin;

SELECT throws_ok(
  $$UPDATE public.security_events SET kind = 'password_changed'
     WHERE user_id = 'bbb10000-0000-4000-8000-000000000004'$$,
  'P0001', 'security_events is append-only',
  'security events still cannot be rewritten'
);

-- The purge flag is only meaningful inside admin_delete_user. Outside it, a
-- direct DELETE is still refused — and a client setting the flag itself
-- achieves nothing anyway, having no DELETE privilege on the table.
SELECT throws_ok(
  $$DELETE FROM public.security_events
     WHERE user_id = 'bbb10000-0000-4000-8000-000000000004'$$,
  'P0001', 'security_events is append-only',
  'a security event cannot be deleted outside an account purge'
);

SELECT * FROM finish();
ROLLBACK;
