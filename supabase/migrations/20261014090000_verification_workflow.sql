-- Verification worked end to end and still could not be operated.
--
-- 0109 built the spine: a request table, one-pending-per-user, a super_admin
-- review that flips is_verified and sets verification_override='manual_on' so
-- the automatic sweep leaves it alone, and an admin_log entry. All of that is
-- kept. What it could not do:
--
--   * **Say where an application is.** Three states — pending, approved,
--     denied — so "a reviewer has this open" and "we asked the applicant a
--     question" both read as 'pending', and the applicant is told nothing but
--     "pending" for however long it takes.
--   * **Undo an approval.** There is no revoke. A check granted in error, or
--     to an account that later broke the rules, could only be removed by
--     hand-editing users.is_verified — which the auto-sweep might then
--     reverse, because nothing recorded that a human decided.
--   * **Ask for anything specific.** One free-text note. No category, no
--     links, nowhere to put evidence.
--   * **Show its own history.** admin_log records the decision globally, but
--     there is no per-request timeline, so a reviewer cannot see that somebody
--     already asked this applicant for more information last week.
--
-- ---------------------------------------------------------------------------
-- THE STATE MODEL
-- ---------------------------------------------------------------------------
--
-- Six stored states. NOT_APPLIED is deliberately not one of them: it is the
-- absence of a row, and storing it would mean writing a row for every account
-- that has never applied.
--
--   pending       submitted, nobody has picked it up
--   under_review  a named reviewer has claimed it
--   more_info     we asked the applicant something; the ball is with them
--   approved      verified
--   rejected      declined
--   revoked       was approved, then withdrawn by a reviewer
--
-- 'denied' is migrated to 'rejected'. One name for one thing; the old token
-- only ever appeared in the CHECK constraint and in my_verification_status's
-- return, and the client treats anything that is not 'verified' or an open
-- state as "you may apply", so nothing breaks on the way through.
--
-- ---------------------------------------------------------------------------
-- WHERE THE SENSITIVE PART GOES, AND WHY IT IS A SEPARATE TABLE
-- ---------------------------------------------------------------------------
--
-- The brief is explicit that verification evidence must not become public
-- profile data, and that ordinary Keepers must never see it. Evidence could
-- have been columns on verification_requests — that table's RLS is already
-- self-or-staff — but it is put in its own table on purpose.
--
-- The realistic failure here is not a policy written wrongly today. It is
-- somebody six months from now adding a useful-looking column to a
-- user_profile_* view, or widening verification_requests so a Keeper can see
-- who applied from their Tribe. Identity documents sitting in that same row
-- would go along for the ride. A table called verification_evidence, granted
-- to nobody but its owner and staff, does not travel by accident — and there
-- is a test asserting no profile-facing view or function references it.
--
-- Evidence is personal data, so it cascades away with the account. The
-- decision history does not: see below.
--
-- ---------------------------------------------------------------------------
-- THE HISTORY TABLE HAS NO FOREIGN KEYS, DELIBERATELY
-- ---------------------------------------------------------------------------
--
-- This is the mistake 20261010090000 and 20261011090000 were written to undo,
-- and it would have been very easy to reintroduce here.
--
-- An append-only ledger whose guard refuses UPDATE and DELETE cannot carry a
-- foreign key with ON DELETE SET NULL or CASCADE: deleting the referenced row
-- fires a cascade the table's own trigger rejects, so the *delete* fails. In
-- those two migrations that is precisely how filing an appeal made an account
-- undeletable, and how any member who had ever logged in could not be removed
-- through the console.
--
-- So verification_review_events stores actor_id, subject_id and request_id as
-- plain UUIDs with no FK, and denormalises actor_pseudonym — exactly what
-- audit_log already does, and for the same reason. A decision ledger that
-- forgets who made the decision as soon as they offboard is not a ledger.
-- Immutability is enforced by the guard; retention is enforced by not letting
-- a cascade reach it.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. States
-- ---------------------------------------------------------------------------
UPDATE public.verification_requests SET status = 'rejected' WHERE status = 'denied';

ALTER TABLE public.verification_requests
    DROP CONSTRAINT IF EXISTS verification_requests_status_check;
ALTER TABLE public.verification_requests
    ADD CONSTRAINT verification_requests_status_check
    CHECK (status IN (
      'pending', 'under_review', 'more_info', 'approved', 'rejected', 'revoked'
    ));

-- ---------------------------------------------------------------------------
-- 2. A structured application
-- ---------------------------------------------------------------------------
ALTER TABLE public.verification_requests
    ADD COLUMN IF NOT EXISTS category TEXT,
    ADD COLUMN IF NOT EXISTS links TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
    -- What the applicant was called when they applied. A reviewer is deciding
    -- about a name, and a display name can change between applying and being
    -- looked at.
    ADD COLUMN IF NOT EXISTS applied_display_name TEXT,
    ADD COLUMN IF NOT EXISTS applied_pseudonym TEXT,
    -- Set when a reviewer asks a question, cleared when the applicant answers.
    ADD COLUMN IF NOT EXISTS info_requested_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS info_request TEXT,
    ADD COLUMN IF NOT EXISTS applicant_response TEXT,
    ADD COLUMN IF NOT EXISTS responded_at TIMESTAMPTZ,
    -- Staff-only. Not shown to the applicant in any RPC below.
    ADD COLUMN IF NOT EXISTS internal_note TEXT,
    ADD COLUMN IF NOT EXISTS claimed_by UUID,
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE public.verification_requests
    DROP CONSTRAINT IF EXISTS verification_requests_category_check;
ALTER TABLE public.verification_requests
    ADD CONSTRAINT verification_requests_category_check
    CHECK (category IS NULL OR category IN (
      'community_leader', 'health_professional', 'creator',
      'organisation', 'public_figure', 'other'
    ));

-- At most six links, and a bounded total size. Free input that a reviewer has
-- to read, and an unbounded array is how a form becomes a place to paste a
-- wall of text.
--
-- Only the two properties a CHECK can actually express. Per-element rules —
-- each entry must look like a URL, each under 300 characters — are enforced in
-- request_verification() below, because a CHECK constraint cannot contain a
-- subquery and `unnest` needs one ("cannot use subquery in check constraint").
-- That is sufficient rather than a compromise: no client role holds INSERT or
-- UPDATE on this table, so the RPC is the only writer there is.
ALTER TABLE public.verification_requests
    DROP CONSTRAINT IF EXISTS verification_requests_links_sane;
ALTER TABLE public.verification_requests
    ADD CONSTRAINT verification_requests_links_sane
    CHECK (
      cardinality(links) <= 6
      AND length(array_to_string(links, ' ')) <= 1800
    );

-- The open states. Replaces the pending-only partial index: an application
-- under review or awaiting the applicant's answer is still open, and a second
-- one must not be creatable alongside it.
DROP INDEX IF EXISTS verification_requests_one_pending;
CREATE UNIQUE INDEX IF NOT EXISTS verification_requests_one_open
    ON public.verification_requests (user_id)
    WHERE status IN ('pending', 'under_review', 'more_info');

CREATE INDEX IF NOT EXISTS verification_requests_queue_idx
    ON public.verification_requests (status, created_at);

-- ---------------------------------------------------------------------------
-- 3. Evidence — its own table, its own grants
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.verification_evidence (
    evidence_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id  UUID NOT NULL
        REFERENCES public.verification_requests(request_id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    -- 'identity' | 'affiliation' | 'credential' | 'other'
    kind        TEXT NOT NULL DEFAULT 'other'
                CHECK (kind IN ('identity', 'affiliation', 'credential', 'other')),
    detail      TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT verification_evidence_detail_present
        CHECK (length(btrim(detail)) BETWEEN 1 AND 4000)
);

COMMENT ON TABLE public.verification_evidence IS
  'Sensitive supporting material for a verification application. Readable '
  'only by its owner and platform staff, never by a Keeper, and deliberately '
  'in its own table so it cannot be swept into a profile view by a later '
  'widening of verification_requests. Cascades away with the account.';

CREATE INDEX IF NOT EXISTS verification_evidence_request_idx
    ON public.verification_evidence (request_id, created_at);

ALTER TABLE public.verification_evidence ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ve owner or staff read" ON public.verification_evidence;
CREATE POLICY "ve owner or staff read"
    ON public.verification_evidence FOR SELECT TO authenticated
    USING (
      user_id = auth.uid()
      OR public.is_staff(auth.uid(), ARRAY['super_admin', 'admin'])
    );

GRANT SELECT ON public.verification_evidence TO authenticated;
-- No INSERT/UPDATE/DELETE to any client role: evidence enters through
-- request_verification() and leaves only with the account.

-- ---------------------------------------------------------------------------
-- 4. The decision ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.verification_review_events (
    event_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- No foreign keys on any of these three. See the header: a cascade into an
    -- append-only table makes the *referenced* row undeletable.
    request_id  UUID NOT NULL,
    subject_id  UUID NOT NULL,
    actor_id    UUID,
    -- Denormalised so the ledger still names the reviewer after they offboard.
    actor_pseudonym TEXT,
    action      TEXT NOT NULL CHECK (action IN (
      'applied', 'claimed', 'info_requested', 'applicant_responded',
      'approved', 'rejected', 'revoked'
    )),
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.verification_review_events IS
  'Immutable per-application timeline: who did what, when, and why. Holds '
  'decisions, not evidence. Ids are plain UUIDs with no FK so that neither a '
  'cascade nor an account deletion can rewrite or block it.';

CREATE INDEX IF NOT EXISTS verification_review_events_request_idx
    ON public.verification_review_events (request_id, created_at);

ALTER TABLE public.verification_review_events ENABLE ROW LEVEL SECURITY;

-- The applicant sees their own timeline; staff see any. Internal notes are not
-- in this table, so showing an applicant their own history is safe.
DROP POLICY IF EXISTS "vre subject or staff read" ON public.verification_review_events;
CREATE POLICY "vre subject or staff read"
    ON public.verification_review_events FOR SELECT TO authenticated
    USING (
      subject_id = auth.uid()
      OR public.is_staff(auth.uid(), ARRAY['super_admin', 'admin'])
    );

GRANT SELECT ON public.verification_review_events TO authenticated;

CREATE OR REPLACE FUNCTION private.verification_events_append_only()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    RAISE EXCEPTION
      'verification_review_events rows are immutable (op: %)', TG_OP;
END $$;

REVOKE ALL ON FUNCTION private.verification_events_append_only()
    FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS verification_events_no_mutate
    ON public.verification_review_events;
CREATE TRIGGER verification_events_no_mutate
    BEFORE UPDATE OR DELETE ON public.verification_review_events
    FOR EACH ROW EXECUTE FUNCTION private.verification_events_append_only();

-- Internal writer. SECURITY DEFINER so the RPCs below can append while no
-- client role holds INSERT on the table.
CREATE OR REPLACE FUNCTION private.log_verification_event(
    p_request UUID,
    p_subject UUID,
    p_action  TEXT,
    p_reason  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor UUID := auth.uid(); v_nick TEXT;
BEGIN
    SELECT anonymous_pseudonym INTO v_nick FROM users WHERE user_id = v_actor;
    INSERT INTO verification_review_events
        (request_id, subject_id, actor_id, actor_pseudonym, action, reason)
    VALUES (p_request, p_subject, v_actor, v_nick, p_action, p_reason);
END $$;

REVOKE ALL ON FUNCTION private.log_verification_event(UUID, UUID, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Applying
-- ---------------------------------------------------------------------------
-- Dropped and recreated rather than replaced: CREATE OR REPLACE cannot add
-- parameters, and leaving the old one-argument version in place next to a new
-- four-argument one would make `request_verification(p_note := …)` ambiguous.
DROP FUNCTION IF EXISTS public.request_verification(TEXT);

CREATE OR REPLACE FUNCTION public.request_verification(
    p_note     TEXT       DEFAULT NULL,
    p_category TEXT       DEFAULT NULL,
    p_links    TEXT[]     DEFAULT NULL,
    p_evidence JSONB      DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_me       UUID := auth.uid();
    v_id       UUID;
    v_open     TEXT;
    v_last     RECORD;
    v_item     JSONB;
    v_links    TEXT[] := COALESCE(p_links, '{}'::TEXT[]);
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    IF EXISTS (SELECT 1 FROM users WHERE user_id = v_me AND is_verified) THEN
        RAISE EXCEPTION 'already verified';
    END IF;

    SELECT status INTO v_open FROM verification_requests
     WHERE user_id = v_me
       AND status IN ('pending', 'under_review', 'more_info')
     LIMIT 1;
    IF v_open IS NOT NULL THEN
        -- Named states rather than one message, because "we asked you a
        -- question" and "nobody has looked yet" call for different actions
        -- from the applicant.
        IF v_open = 'more_info' THEN
            RAISE EXCEPTION 'respond_to_the_open_request'
              USING HINT = 'A reviewer asked you for more information.';
        END IF;
        RAISE EXCEPTION 'already_pending'
          USING HINT = 'Your application is already in the queue.';
    END IF;

    -- Cooling-off after a decision. Without it a rejected applicant can
    -- reapply in a loop, and the queue becomes the same person forever.
    SELECT status, reviewed_at INTO v_last
      FROM verification_requests
     WHERE user_id = v_me AND status IN ('rejected', 'revoked')
     ORDER BY COALESCE(reviewed_at, created_at) DESC
     LIMIT 1;
    IF v_last.reviewed_at IS NOT NULL
       AND v_last.reviewed_at > now() - interval '30 days' THEN
        RAISE EXCEPTION 'too_soon_to_reapply'
          USING HINT = 'You can apply again 30 days after a decision.';
    END IF;

    -- The per-element link rules the CHECK constraint cannot express. Done
    -- here because this function is the table's only writer.
    IF EXISTS (
        SELECT 1 FROM unnest(v_links) AS l
         WHERE length(l) > 300
            OR (l NOT LIKE 'http://%' AND l NOT LIKE 'https://%')
    ) THEN
        RAISE EXCEPTION 'invalid_link'
          USING HINT = 'Each link must be an http(s) address under 300 characters.';
    END IF;

    INSERT INTO verification_requests (
        user_id, note, category, links,
        applied_display_name, applied_pseudonym
    )
    SELECT v_me,
           NULLIF(btrim(COALESCE(p_note, '')), ''),
           NULLIF(btrim(COALESCE(p_category, '')), ''),
           v_links,
           u.display_name,
           u.anonymous_pseudonym
      FROM users u WHERE u.user_id = v_me
    RETURNING request_id INTO v_id;

    -- Evidence arrives as [{"kind": "...", "detail": "..."}]. Written through
    -- here rather than by the client, which holds no INSERT on the table.
    IF p_evidence IS NOT NULL AND jsonb_typeof(p_evidence) = 'array' THEN
        IF jsonb_array_length(p_evidence) > 10 THEN
            RAISE EXCEPTION 'too_much_evidence';
        END IF;
        FOR v_item IN SELECT value FROM jsonb_array_elements(p_evidence) LOOP
            IF length(btrim(COALESCE(v_item->>'detail', ''))) = 0 THEN
                CONTINUE;
            END IF;
            INSERT INTO verification_evidence (request_id, user_id, kind, detail)
            VALUES (
                v_id, v_me,
                CASE WHEN COALESCE(v_item->>'kind', 'other') IN
                        ('identity', 'affiliation', 'credential', 'other')
                     THEN v_item->>'kind' ELSE 'other' END,
                btrim(v_item->>'detail')
            );
        END LOOP;
    END IF;

    PERFORM private.log_verification_event(v_id, v_me, 'applied', NULL);
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.request_verification(TEXT, TEXT, TEXT[], JSONB)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_verification(TEXT, TEXT, TEXT[], JSONB)
    TO authenticated;

-- ---- The applicant answers a question -------------------------------------
CREATE OR REPLACE FUNCTION public.respond_to_verification_request(
    p_response TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_me UUID := auth.uid(); v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF length(btrim(COALESCE(p_response, ''))) = 0 THEN
        RAISE EXCEPTION 'empty_response';
    END IF;

    SELECT request_id INTO v_id FROM verification_requests
     WHERE user_id = v_me AND status = 'more_info' LIMIT 1;
    IF v_id IS NULL THEN RAISE EXCEPTION 'no_open_information_request'; END IF;

    -- Back to pending, not to under_review: the reviewer who asked may not be
    -- the one who picks it up, and claiming is an explicit act.
    UPDATE verification_requests
       SET status = 'pending',
           applicant_response = btrim(p_response),
           responded_at = now(),
           updated_at = now()
     WHERE request_id = v_id;

    PERFORM private.log_verification_event(
        v_id, v_me, 'applicant_responded', NULL);
END $$;

REVOKE ALL ON FUNCTION public.respond_to_verification_request(TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_verification_request(TEXT)
    TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. What the applicant can see
-- ---------------------------------------------------------------------------
-- Returns the state, the dates, and the reviewer's stated reason — but never
-- internal_note, and never the reviewer's identity. A decision explained to
-- the person it affects is right; naming the individual staff member who made
-- it is not, on a platform where members can be hostile.
CREATE OR REPLACE FUNCTION public.my_verification_state()
RETURNS TABLE (
    status           TEXT,
    category         TEXT,
    applied_at       TIMESTAMPTZ,
    reviewed_at      TIMESTAMPTZ,
    decision_reason  TEXT,
    info_request     TEXT,
    can_apply        BOOLEAN,
    reapply_after    TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp STABLE AS $$
DECLARE
    v_me       UUID := auth.uid();
    v_verified BOOLEAN;
    v_row      RECORD;
BEGIN
    IF v_me IS NULL THEN RETURN; END IF;

    SELECT is_verified INTO v_verified FROM users WHERE user_id = v_me;

    SELECT r.status, r.category, r.created_at, r.reviewed_at,
           r.review_reason, r.info_request
      INTO v_row
      FROM verification_requests r
     WHERE r.user_id = v_me
     ORDER BY r.created_at DESC
     LIMIT 1;

    IF v_verified THEN
        RETURN QUERY SELECT
            'approved'::TEXT, v_row.category, v_row.created_at,
            v_row.reviewed_at, v_row.review_reason, NULL::TEXT,
            FALSE, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF v_row IS NULL THEN
        RETURN QUERY SELECT
            'not_applied'::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT,
            TRUE, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    RETURN QUERY SELECT
        v_row.status,
        v_row.category,
        v_row.created_at,
        v_row.reviewed_at,
        v_row.review_reason,
        CASE WHEN v_row.status = 'more_info' THEN v_row.info_request END,
        -- Applying again is possible only with nothing open and the
        -- cooling-off elapsed. Computed here so the button and the RPC cannot
        -- disagree about eligibility.
        v_row.status IN ('rejected', 'revoked')
          AND (v_row.reviewed_at IS NULL
               OR v_row.reviewed_at <= now() - interval '30 days'),
        CASE WHEN v_row.status IN ('rejected', 'revoked')
                  AND v_row.reviewed_at IS NOT NULL
             THEN v_row.reviewed_at + interval '30 days' END;
END $$;

REVOKE ALL ON FUNCTION public.my_verification_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_verification_state() TO authenticated;

-- Kept, and now reports the wider set, because the Flutter client and any
-- cached build still call it.
CREATE OR REPLACE FUNCTION public.my_verification_status()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp STABLE AS $$
DECLARE v_me UUID := auth.uid(); v_verified BOOLEAN; v_last TEXT;
BEGIN
    IF v_me IS NULL THEN RETURN 'none'; END IF;
    SELECT is_verified INTO v_verified FROM users WHERE user_id = v_me;
    IF v_verified THEN RETURN 'verified'; END IF;
    SELECT status INTO v_last FROM verification_requests
      WHERE user_id = v_me ORDER BY created_at DESC LIMIT 1;
    RETURN COALESCE(v_last, 'none');
END $$;

GRANT EXECUTE ON FUNCTION public.my_verification_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Reviewing
-- ---------------------------------------------------------------------------
-- Every function here is super_admin only and appends to both ledgers: the
-- per-request timeline for the reviewer's own history view, and admin_log for
-- the platform-wide audit the console already reads.

-- ---- Claim, so two reviewers do not decide the same case -------------------
CREATE OR REPLACE FUNCTION public.admin_claim_verification(p_request UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user UUID; v_status TEXT; v_holder UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can review verification';
    END IF;

    SELECT user_id, status, claimed_by INTO v_user, v_status, v_holder
      FROM verification_requests WHERE request_id = p_request;
    IF v_user IS NULL THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_status NOT IN ('pending', 'under_review') THEN
        RAISE EXCEPTION 'request_not_open';
    END IF;
    -- Re-claiming your own is a no-op rather than an error; a reviewer
    -- refreshing the page should not be told off.
    IF v_status = 'under_review' AND v_holder IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'already_claimed'
          USING HINT = 'Another reviewer has this open.';
    END IF;

    UPDATE verification_requests
       SET status = 'under_review', claimed_by = auth.uid(),
           claimed_at = now(), updated_at = now()
     WHERE request_id = p_request;

    IF v_status <> 'under_review' THEN
        PERFORM private.log_verification_event(p_request, v_user, 'claimed', NULL);
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.admin_claim_verification(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_claim_verification(UUID) TO authenticated;

-- ---- Ask the applicant something ------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_request_verification_info(
    p_request UUID,
    p_message TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user UUID; v_status TEXT; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can review verification';
    END IF;
    IF length(btrim(COALESCE(p_message, ''))) = 0 THEN
        -- "We need more information" with no question is a dead end for the
        -- applicant, so the message is required rather than optional.
        RAISE EXCEPTION 'message_required'
          USING HINT = 'Say what you need from them.';
    END IF;

    SELECT user_id, status INTO v_user, v_status
      FROM verification_requests WHERE request_id = p_request;
    IF v_user IS NULL THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_status NOT IN ('pending', 'under_review') THEN
        RAISE EXCEPTION 'request_not_open';
    END IF;

    UPDATE verification_requests
       SET status = 'more_info', info_request = btrim(p_message),
           info_requested_at = now(), updated_at = now()
     WHERE request_id = p_request;

    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = v_user;
    PERFORM private.log_verification_event(
        p_request, v_user, 'info_requested', btrim(p_message));
    PERFORM admin_log('verification.request_info', 'user', v_user, v_label,
        NULL, jsonb_build_object('request_id', p_request), btrim(p_message),
        '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.admin_request_verification_info(UUID, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_request_verification_info(UUID, TEXT)
    TO authenticated;

-- ---- Approve / reject ------------------------------------------------------
-- Same signature as 0109 so the console's existing Server Action keeps
-- working. Two behavioural changes: it now accepts a request that is
-- under_review or more_info as well as pending, and it appends to the
-- per-request ledger.
CREATE OR REPLACE FUNCTION public.admin_review_verification(
    p_request UUID,
    p_approve BOOLEAN,
    p_reason  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user UUID; v_status TEXT; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can review verification';
    END IF;

    SELECT user_id, status INTO v_user, v_status
      FROM verification_requests WHERE request_id = p_request;
    IF v_user IS NULL THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_status NOT IN ('pending', 'under_review', 'more_info') THEN
        RAISE EXCEPTION 'request already reviewed';
    END IF;

    -- Rejecting is allowed with no reason; the applicant is told a decision
    -- was made either way. Approving needs none.
    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = v_user;

    UPDATE verification_requests
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
           reviewed_by = auth.uid(), reviewed_at = now(),
           review_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
           updated_at = now()
     WHERE request_id = p_request;

    IF p_approve THEN
        UPDATE users
           SET is_verified = true, verification_override = 'manual_on',
               updated_at = now()
         WHERE user_id = v_user;
        BEGIN PERFORM award(v_user, 'verified'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    PERFORM private.log_verification_event(
        p_request, v_user,
        CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
        NULLIF(btrim(COALESCE(p_reason, '')), ''));

    PERFORM admin_log(
        CASE WHEN p_approve THEN 'verification.approve' ELSE 'verification.deny' END,
        'user', v_user, v_label, NULL,
        jsonb_build_object('request_id', p_request), p_reason, '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.admin_review_verification(UUID, BOOLEAN, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_review_verification(UUID, BOOLEAN, TEXT)
    TO authenticated;

-- ---- Revoke ----------------------------------------------------------------
-- Takes a user, not a request: a check may have been granted by the automatic
-- sweep in 0107 and have no application behind it at all, and "revoke this
-- person's verification" must work in that case too.
--
-- Sets verification_override = 'manual_off', which is the whole reason this
-- cannot be done by editing is_verified: without the override the automatic
-- sweep would re-verify an account that still meets the reach thresholds, and
-- a deliberate human decision would silently undo itself.
CREATE OR REPLACE FUNCTION public.admin_revoke_verification(
    p_user   UUID,
    p_reason TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_label TEXT; v_was BOOLEAN; v_request UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can revoke verification';
    END IF;
    IF length(btrim(COALESCE(p_reason, ''))) = 0 THEN
        -- Required. Removing a badge is visible to the member and to everyone
        -- who follows them; an unexplained revocation is not reviewable.
        RAISE EXCEPTION 'reason_required'
          USING HINT = 'Record why the check is being removed.';
    END IF;

    SELECT is_verified, '@' || anonymous_pseudonym INTO v_was, v_label
      FROM users WHERE user_id = p_user;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
    IF NOT COALESCE(v_was, FALSE) THEN RAISE EXCEPTION 'not_verified'; END IF;

    UPDATE users
       SET is_verified = false, verification_override = 'manual_off',
           updated_at = now()
     WHERE user_id = p_user;

    -- Mark the approved application revoked, when there is one. The badge can
    -- also have come from the automatic sweep, hence the null-tolerance.
    SELECT request_id INTO v_request FROM verification_requests
     WHERE user_id = p_user AND status = 'approved'
     ORDER BY reviewed_at DESC NULLS LAST LIMIT 1;

    IF v_request IS NOT NULL THEN
        UPDATE verification_requests
           SET status = 'revoked', review_reason = btrim(p_reason),
               reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
         WHERE request_id = v_request;
    END IF;

    -- Logged either way. gen_random_uuid() stands in for the request id when
    -- the badge was automatic, so the timeline still has a row rather than
    -- silently dropping the most consequential action in this file.
    PERFORM private.log_verification_event(
        COALESCE(v_request, gen_random_uuid()), p_user, 'revoked', btrim(p_reason));

    PERFORM admin_log('verification.revoke', 'user', p_user, v_label,
        jsonb_build_object('is_verified', TRUE),
        jsonb_build_object('is_verified', FALSE),
        btrim(p_reason), '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.admin_revoke_verification(UUID, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_revoke_verification(UUID, TEXT)
    TO authenticated;

-- ---- Internal notes --------------------------------------------------------
-- Staff-only scratch space on a request. Deliberately not in the review
-- ledger and never returned by my_verification_state: a reviewer needs
-- somewhere to write "second application, first was withdrawn" without it
-- becoming a message to the applicant.
CREATE OR REPLACE FUNCTION public.admin_set_verification_note(
    p_request UUID,
    p_note    TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can review verification';
    END IF;
    UPDATE verification_requests
       SET internal_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           updated_at = now()
     WHERE request_id = p_request;
    IF NOT FOUND THEN RAISE EXCEPTION 'request not found'; END IF;
END $$;

REVOKE ALL ON FUNCTION public.admin_set_verification_note(UUID, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_verification_note(UUID, TEXT)
    TO authenticated;

-- ---- The queue -------------------------------------------------------------
-- One read for the console: filter by status, search by handle, and the
-- counts each row needs, without the console assembling it from three
-- queries. Evidence is returned as a count only — a reviewer opens a single
-- application to read it, which keeps identity documents out of a list
-- response that might be logged or cached.
CREATE OR REPLACE FUNCTION public.admin_verification_queue(
    p_status TEXT DEFAULT NULL,
    p_search TEXT DEFAULT NULL,
    p_limit  INT  DEFAULT 100
) RETURNS TABLE (
    request_id      UUID,
    user_id         UUID,
    pseudonym       TEXT,
    status          TEXT,
    category        TEXT,
    note            TEXT,
    links           TEXT[],
    evidence_count  INT,
    internal_note   TEXT,
    info_request    TEXT,
    applicant_response TEXT,
    claimed_by_pseudonym TEXT,
    reviewed_by_pseudonym TEXT,
    review_reason   TEXT,
    created_at      TIMESTAMPTZ,
    reviewed_at     TIMESTAMPTZ,
    is_verified     BOOLEAN,
    connections_count INT,
    karma_points    INT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp STABLE AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin', 'admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    RETURN QUERY
    -- Explicit ::TEXT on every pseudonym. users.anonymous_pseudonym is
    -- VARCHAR(100), and RETURNS TABLE is strict about it: without the cast
    -- the whole function fails at call time with "structure of query does not
    -- match function result type ... character varying(100) does not match
    -- expected type text".
    SELECT r.request_id, r.user_id, u.anonymous_pseudonym::TEXT, r.status,
           r.category, r.note, r.links,
           (SELECT count(*)::INT FROM verification_evidence e
             WHERE e.request_id = r.request_id),
           r.internal_note, r.info_request, r.applicant_response,
           cb.anonymous_pseudonym::TEXT, rb.anonymous_pseudonym::TEXT,
           r.review_reason, r.created_at, r.reviewed_at,
           u.is_verified, u.connections_count, u.karma_points
      FROM verification_requests r
      JOIN users u  ON u.user_id = r.user_id
      LEFT JOIN users cb ON cb.user_id = r.claimed_by
      LEFT JOIN users rb ON rb.user_id = r.reviewed_by
     WHERE (p_status IS NULL OR p_status = 'all' OR r.status = p_status)
       AND (
         p_search IS NULL OR btrim(p_search) = ''
         OR u.anonymous_pseudonym ILIKE '%' || btrim(p_search) || '%'
         OR u.display_name ILIKE '%' || btrim(p_search) || '%'
       )
     -- Open applications first, oldest first within that, so the queue is
     -- worked in the order people have been waiting.
     ORDER BY
       CASE r.status
         WHEN 'more_info' THEN 0 WHEN 'under_review' THEN 1
         WHEN 'pending' THEN 2 ELSE 3 END,
       r.created_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
END $$;

REVOKE ALL ON FUNCTION public.admin_verification_queue(TEXT, TEXT, INT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_verification_queue(TEXT, TEXT, INT)
    TO authenticated;

-- ---- One application's evidence and timeline ------------------------------
CREATE OR REPLACE FUNCTION public.admin_verification_detail(p_request UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp STABLE AS $$
DECLARE v_out JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin', 'admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT jsonb_build_object(
        'evidence', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'kind', e.kind, 'detail', e.detail, 'created_at', e.created_at)
                ORDER BY e.created_at)
              FROM verification_evidence e WHERE e.request_id = p_request
        ), '[]'::jsonb),
        'timeline', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'action', v.action, 'actor', v.actor_pseudonym,
                'reason', v.reason, 'at', v.created_at)
                ORDER BY v.created_at)
              FROM verification_review_events v WHERE v.request_id = p_request
        ), '[]'::jsonb)
    ) INTO v_out;

    RETURN v_out;
END $$;

REVOKE ALL ON FUNCTION public.admin_verification_detail(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_verification_detail(UUID) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20261014090000', 'verification_workflow'
);

NOTIFY pgrst, 'reload schema';
