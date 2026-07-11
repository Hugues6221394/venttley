-- 0108_cold_start_suggestions.sql
-- friend_suggestions() only drew from mutual-tribe members, so a brand-new user
-- with no tribes/connections got an EMPTY list. Now every signed-in user — even
-- with zero connections — gets a ranked list: mutual-tribe people first, then
-- TRENDING users (verified + high karma + well-connected + active). This powers
-- both the connections screen and the new home "People to connect with" rail.

CREATE OR REPLACE FUNCTION public.friend_suggestions(p_limit INT DEFAULT 6)
RETURNS TABLE (
    user_id           UUID,
    pseudonym         TEXT,
    avatar_seed       TEXT,
    profile_photo_url TEXT,
    is_verified       BOOLEAN,
    shared_tribes     INT,
    rationale         TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public STABLE
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    RETURN QUERY
    WITH my_tribes AS (
        SELECT tribe_id FROM tribe_members WHERE user_id = v_me
    ),
    my_blocks AS (
        SELECT blocked_id AS other_id FROM user_blocks WHERE blocker_id = v_me
        UNION
        SELECT blocker_id AS other_id FROM user_blocks WHERE blocked_id = v_me
    ),
    my_friends AS (
        SELECT CASE WHEN user_a = v_me THEN user_b ELSE user_a END AS other_id
          FROM friendships
         WHERE status IN ('accepted','pending')
           AND (user_a = v_me OR user_b = v_me)
    ),
    -- Everyone the caller could connect with (active, not a minor, not blocked,
    -- not already a friend/pending, not deactivated).
    eligible AS (
        SELECT u.user_id,
               u.anonymous_pseudonym,
               u.avatar_seed,
               u.profile_photo_url,
               COALESCE(u.is_verified, false)      AS is_verified,
               COALESCE(u.karma_points, 0)         AS karma_points,
               COALESCE(u.connections_count, 0)    AS connections_count
          FROM users u
         WHERE u.user_id <> v_me
           AND u.account_status = 'active'
           AND u.deactivated_at IS NULL
           AND COALESCE(u.safety_tier, 'standard') <> 'restricted_minor'
           AND NOT EXISTS (SELECT 1 FROM my_friends f WHERE f.other_id = u.user_id)
           AND NOT EXISTS (SELECT 1 FROM my_blocks  b WHERE b.other_id  = u.user_id)
    ),
    shared AS (
        SELECT tm.user_id, COUNT(DISTINCT tm.tribe_id)::INT AS shared_tribes
          FROM tribe_members tm
         WHERE tm.tribe_id IN (SELECT tribe_id FROM my_tribes)
         GROUP BY tm.user_id
    )
    SELECT
        e.user_id,
        e.anonymous_pseudonym::TEXT                   AS pseudonym,
        COALESCE(e.avatar_seed, 'default-orb')::TEXT  AS avatar_seed,
        e.profile_photo_url::TEXT                     AS profile_photo_url,
        e.is_verified                                 AS is_verified,
        COALESCE(s.shared_tribes, 0)                  AS shared_tribes,
        (CASE
            WHEN COALESCE(s.shared_tribes, 0) = 1 THEN '1 Mutual Tribe'
            WHEN COALESCE(s.shared_tribes, 0) > 1 THEN s.shared_tribes || ' Mutual Tribes'
            WHEN e.is_verified                    THEN 'Verified · trending'
            ELSE 'Trending on Venttly'
         END)::TEXT                                   AS rationale
      FROM eligible e
      LEFT JOIN shared s ON s.user_id = e.user_id
     ORDER BY
        COALESCE(s.shared_tribes, 0) DESC,           -- mutual-tribe people first
        e.is_verified DESC,                          -- then verified
        (e.karma_points + e.connections_count * 5) DESC,  -- then trending score
        e.user_id
     LIMIT GREATEST(1, LEAST(p_limit, 20));
END $$;

REVOKE ALL ON FUNCTION public.friend_suggestions(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_suggestions(INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
