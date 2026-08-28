-- online_friends() raised 42804 (datatype_mismatch) on every call, so the
-- inbox's around-now strip silently rendered nothing.
--
-- PL/pgSQL's RETURN QUERY requires the query's column types to match the
-- RETURNS TABLE declaration *exactly*. It will not coerce `character varying`
-- to `text` the way an ordinary assignment would, so a column declared TEXT
-- here fed by a varchar column there fails at runtime — not at creation, which
-- is why the migration applied cleanly and the failure only showed up on the
-- first call.
--
-- Every returned expression is now cast explicitly. That also makes the
-- function immune to a future column type change in `users`.
--
-- Found because the client logs the *structured* Postgrest code for this call.
-- The strip is deliberately fail-quiet — it renders nothing rather than an
-- error card, which is right for a decorative surface — and that made a broken
-- RPC indistinguishable from a quiet night until the code was logged.

CREATE OR REPLACE FUNCTION public.online_friends(p_limit INT DEFAULT 12)
RETURNS TABLE (
  user_id           UUID,
  pseudonym         TEXT,
  display_name      TEXT,
  avatar_seed       TEXT,
  profile_photo_url TEXT,
  is_verified       BOOLEAN,
  state             TEXT,
  last_seen_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN RETURN; END IF;

  RETURN QUERY
  WITH my_friends AS (
      SELECT CASE WHEN f.user_a = v_me THEN f.user_b ELSE f.user_a END AS fid
        FROM friendships f
       WHERE f.status = 'accepted'
         AND v_me IN (f.user_a, f.user_b)
  ),
  blocked AS (
      SELECT b.blocked_id AS other_id FROM user_blocks b WHERE b.blocker_id = v_me
      UNION
      SELECT b.blocker_id AS other_id FROM user_blocks b WHERE b.blocked_id = v_me
  )
  SELECT u.user_id::UUID,
         u.anonymous_pseudonym::TEXT,
         u.display_name::TEXT,
         COALESCE(u.avatar_seed, 'default-orb')::TEXT,
         u.profile_photo_url::TEXT,
         COALESCE(u.is_verified, FALSE)::BOOLEAN,
         (CASE
            WHEN u.last_seen_at > now() - INTERVAL '70 seconds' THEN 'online'
            ELSE 'recent'
          END)::TEXT,
         u.last_seen_at::TIMESTAMPTZ
    FROM my_friends mf
    JOIN users u ON u.user_id = mf.fid
   WHERE u.user_id NOT IN (SELECT other_id FROM blocked)
     AND u.account_status = 'active'
     AND u.deactivated_at IS NULL
     -- Opt-in only. Omitted entirely, not merely undated: being listed as
     -- "around" is presence information in its own right.
     AND u.show_last_seen IS TRUE
     AND u.last_seen_at IS NOT NULL
     AND u.last_seen_at > now() - INTERVAL '5 minutes'
   ORDER BY u.last_seen_at DESC
   LIMIT GREATEST(COALESCE(p_limit, 12), 1);
END $$;

REVOKE ALL ON FUNCTION public.online_friends(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_friends(INT) TO authenticated;
