-- =========================================================================
-- Consent was a checkbox, not a boundary
--
-- Found by running the acceptance journey the original plan specifies. A
-- brand-new account, seconds old and having accepted nothing, posted
-- successfully:
--
--   POST /auth/v1/signup                          -> 200, token issued
--   POST /rest/v1/rpc/my_outstanding_policies     -> ['privacy','terms']
--   POST /rest/v1/rpc/create_post_idempotent_v4   -> 200, post created
--
-- Everything else about the consent system is sound. policy_documents and
-- policy_acceptances exist, versions are recorded with timestamps,
-- my_outstanding_policies reports exactly what is owed, and accept_policies
-- refuses a fabricated version with a message naming both what was sent and
-- what is current. 0025 covers all of it. The one missing piece was that
-- nothing consulted any of it before letting someone publish.
--
-- The gate lived only in Flutter. This project's own rule is that Flutter may
-- hide a button and nothing more, and consent is exactly the kind of claim
-- that must not rest on the client: "the user agreed" is a statement the
-- product may one day have to defend, and a checkbox the server never saw is
-- not evidence of anything.
--
-- WHERE THE CHECK GOES
--
-- private.assert_user_can_write() is already the single chokepoint every
-- guarded content path calls — _server_content_write_guard routes posts,
-- posts_comments, whisper_comments, tribe_messages, chat_messages and
-- whispers through it, and _writer_state calls it before the rate limiter. It
-- already refuses a suspended account and an under-age one. Consent is the
-- same kind of precondition and belongs beside them rather than in six
-- separate call sites that can drift apart.
--
-- WHY THE PREDICATE IS EXTRACTED RATHER THAN RESTATED
--
-- "Outstanding" is subtler than "has a row". my_outstanding_policies already
-- encodes the rule: never having accepted a document at all always counts,
-- but once accepted, only a *material* new version forces a fresh acceptance —
-- a typo fix creates a version so the record says which text was shown,
-- without putting the whole userbase through a wall.
--
-- Writing that logic a second time inside the gate would be the same mistake
-- as the thirteen RLS policies that each restated is_staff and quietly forked
-- from it (20261018090000). Worse here: if the gate and the prompt ever
-- disagreed, the app would show nothing outstanding while the server refused
-- every write, and the user would be locked out with no way to satisfy a
-- demand nobody could see. So the predicate moves into
-- private.outstanding_policies(user) and both callers use it.
--
-- WHAT IS GATED, AND WHAT DELIBERATELY IS NOT
--
-- Gated: creating content other people see or receive — Vents, comments,
-- Whispers, Tribe messages, direct messages.
--
-- Not gated: reading, signing in, editing your own profile, accepting the
-- policies themselves, exporting your data, or deleting your account. A
-- consent wall that traps someone inside an account they cannot read or leave
-- is a worse outcome than the gap it closes, and gating the act of accepting
-- would be a deadlock.
--
-- OPERATIONAL NOTE
--
-- Existing accounts that never accepted are refused on their next write until
-- they do. That is intended: the alternative is deciding on their behalf that
-- they agreed, which is the precise thing the brief says never to do. The seed
-- accepts on behalf of the test accounts, because a real user of those
-- accounts would have accepted at signup.
-- =========================================================================

-- =========================================================================
-- 1) One definition of "outstanding", for any user
-- =========================================================================

CREATE OR REPLACE FUNCTION private.outstanding_policies(p_user UUID)
RETURNS TABLE (kind TEXT, version TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT c.kind, c.version
      FROM public.current_policies() c
      JOIN public.policy_documents d
        ON d.kind = c.kind AND d.version = c.version
     WHERE p_user IS NOT NULL
       -- Never accepted this document at all: always outstanding, whether or
       -- not the live version is a material one.
       AND (
         NOT EXISTS (
           SELECT 1 FROM public.policy_acceptances a
            WHERE a.user_id = p_user AND a.kind = c.kind
         )
         -- Otherwise only a material version forces a fresh acceptance.
         OR (
           d.material
           AND NOT EXISTS (
             SELECT 1 FROM public.policy_acceptances a
              WHERE a.user_id = p_user
                AND a.kind    = c.kind
                AND a.version = c.version
           )
         )
       );
$$;

REVOKE ALL ON FUNCTION private.outstanding_policies(UUID)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.outstanding_policies(UUID) IS
  'Which current policy documents this user still owes acceptance of. The single definition, used by my_outstanding_policies (what the app prompts for) and assert_user_can_write (what the server enforces). They must never disagree: a gate stricter than the prompt locks a user out of a demand they cannot see.';

-- =========================================================================
-- 2) The prompt now delegates
-- =========================================================================

CREATE OR REPLACE FUNCTION public.my_outstanding_policies()
RETURNS TABLE (kind TEXT, version TEXT, title TEXT, summary TEXT,
               body_markdown TEXT, body_url TEXT,
               effective_at TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT c.kind, c.version, c.title, c.summary,
           c.body_markdown, c.body_url, c.effective_at
      FROM public.current_policies() c
      JOIN private.outstanding_policies((SELECT auth.uid())) o
        ON o.kind = c.kind AND o.version = c.version;
$$;

-- =========================================================================
-- 3) And the gate enforces the same thing
-- =========================================================================

CREATE OR REPLACE FUNCTION private.assert_user_can_write(p_user UUID)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user RECORD;
  v_age INT;
  v_missing TEXT;
BEGIN
  SELECT user_row.account_status, user_row.birth_year
    INTO v_user
    FROM public.users AS user_row
   WHERE user_row.user_id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'account_not_found'; END IF;
  IF v_user.account_status <> 'active' THEN RAISE EXCEPTION 'account_not_active'; END IF;
  IF v_user.birth_year IS NULL THEN
    RAISE EXCEPTION 'age_verification_required' USING ERRCODE = 'P0001';
  END IF;
  v_age := EXTRACT(YEAR FROM now())::INT - v_user.birth_year;
  IF v_age < 13 THEN RAISE EXCEPTION 'age_below_minimum' USING ERRCODE = 'P0001'; END IF;

  SELECT string_agg(o.kind, ' and ' ORDER BY o.kind)
    INTO v_missing
    FROM private.outstanding_policies(p_user) o;

  IF v_missing IS NOT NULL THEN
    -- Names what is outstanding, because the client has to know which
    -- document to present and a bare 'forbidden' would send it guessing.
    RAISE EXCEPTION
      'policy_acceptance_required: % not accepted at the current version', v_missing
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.assert_user_can_write(UUID)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.assert_user_can_write(UUID) IS
  'Preconditions shared by every guarded content write: the account exists, is active, is old enough, and owes no policy acceptance. Called by _server_content_write_guard and _writer_state. Reading, profile edits, accepting policies, data export and account deletion are deliberately NOT gated.';

SELECT public.record_migration(
  '20261020090000', 'consent_gates_content_writes'
);

NOTIFY pgrst, 'reload schema';
