-- 0019_fix_streak_rls.sql
--
-- Fix: trg_post_events / trg_comment_events fired bump_streak() and award()
-- as SECURITY INVOKER, so the INSERT/UPDATE on user_streaks and user_badges
-- hit RLS as `authenticated`. user_streaks has SELECT-only policy and
-- user_badges has none for writes, so the writes failed and the whole
-- post/comment INSERT was rolled back.
--
-- All writes already go through the trigger chain (no direct client access
-- to these tables is needed). Marking both as SECURITY DEFINER lets the
-- triggers update the streak/badge tables under the function owner, which
-- is the intended model — RLS still confines reads to the owner via the
-- existing SELECT policy.

CREATE OR REPLACE FUNCTION public.bump_streak(p_user UUID, p_kind TEXT, p_now TIMESTAMPTZ)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    prev TIMESTAMPTZ;
    cur  INT;
    longest INT;
    new_count INT;
BEGIN
    SELECT last_event_at, current_count, longest_count
      INTO prev, cur, longest
      FROM user_streaks
     WHERE user_id = p_user AND streak_kind = p_kind;

    IF NOT FOUND THEN
        INSERT INTO user_streaks(user_id, streak_kind, current_count, longest_count, last_event_at)
        VALUES (p_user, p_kind, 1, 1, p_now);
        RETURN 1;
    END IF;

    IF DATE(prev) = DATE(p_now) THEN
        new_count := cur;
    ELSIF DATE(prev) = DATE(p_now) - INTERVAL '1 day' THEN
        new_count := cur + 1;
    ELSE
        new_count := 1;
    END IF;

    UPDATE user_streaks
       SET current_count = new_count,
           longest_count = GREATEST(longest, new_count),
           last_event_at = p_now
     WHERE user_id = p_user AND streak_kind = p_kind;
    RETURN new_count;
END $$;

CREATE OR REPLACE FUNCTION public.award(p_user UUID, p_badge TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO user_badges(user_id, badge_key)
    VALUES (p_user, p_badge)
    ON CONFLICT (user_id, badge_key) DO NOTHING;
END $$;

REVOKE ALL ON FUNCTION public.bump_streak(UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.award(UUID, TEXT) FROM PUBLIC;
-- Only the trigger functions (which run in-process) call these. No client
-- GRANTs needed — leaving them locked closes off direct invocation.
