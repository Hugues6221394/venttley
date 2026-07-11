-- 0040_friend_suggestions_favorites.sql
--
-- Wires the Image #15 Friends screen:
--   * friend_suggestions RPC — mutual-tribe acquaintances minus current
--     friends and blocked, sorted by shared-tribe count
--   * friendship_favorites table — per-user favorite marker on a
--     friendship (the heart icon on the alphabetical list)
--   * toggle_friend_favorite RPC — flips the heart for the caller

-- =========================================================================
-- 1) friendship_favorites
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.friendship_favorites (
    friendship_id UUID NOT NULL REFERENCES public.friendships(friendship_id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (friendship_id, user_id)
);
CREATE INDEX IF NOT EXISTS friendship_favorites_user_idx
    ON public.friendship_favorites(user_id);

ALTER TABLE public.friendship_favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "friendship favorite self read" ON public.friendship_favorites;
CREATE POLICY "friendship favorite self read"
    ON public.friendship_favorites FOR SELECT
    USING (user_id = auth.uid());

GRANT SELECT ON public.friendship_favorites TO authenticated;

CREATE OR REPLACE FUNCTION public.toggle_friend_favorite(p_friendship_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_member BOOLEAN;
    v_exists BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    -- Must be one of the two friendship participants
    SELECT EXISTS (
        SELECT 1 FROM friendships
         WHERE friendship_id = p_friendship_id
           AND (user_a = v_me OR user_b = v_me)
           AND status = 'accepted'
    ) INTO v_member;
    IF NOT v_member THEN RAISE EXCEPTION 'not a participant'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM friendship_favorites
         WHERE friendship_id = p_friendship_id AND user_id = v_me
    ) INTO v_exists;

    IF v_exists THEN
        DELETE FROM friendship_favorites
         WHERE friendship_id = p_friendship_id AND user_id = v_me;
        RETURN FALSE;
    ELSE
        INSERT INTO friendship_favorites (friendship_id, user_id)
        VALUES (p_friendship_id, v_me)
        ON CONFLICT DO NOTHING;
        RETURN TRUE;
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.toggle_friend_favorite(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_friend_favorite(UUID) TO authenticated;

-- =========================================================================
-- 2) friend_suggestions
-- =========================================================================
-- Surfaces users who share at least one tribe with the caller, are not
-- already friends, are not blocked / blocker, and aren't the caller. The
-- shared_tribes count is the primary sort signal so the strongest mutual
-- ties bubble to the top.
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
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
        SELECT blocked_id FROM user_blocks WHERE blocker_id = v_me
        UNION
        SELECT blocker_id FROM user_blocks WHERE blocked_id = v_me
    ),
    my_friends AS (
        SELECT CASE WHEN user_a = v_me THEN user_b ELSE user_a END AS other_id
          FROM friendships
         WHERE status = 'accepted'
           AND (user_a = v_me OR user_b = v_me)
        UNION
        SELECT CASE WHEN user_a = v_me THEN user_b ELSE user_a END AS other_id
          FROM friendships
         WHERE status = 'pending'
           AND (user_a = v_me OR user_b = v_me)
    ),
    candidates AS (
        SELECT
            u.user_id,
            COUNT(DISTINCT tm.tribe_id)::INT AS shared_tribes
          FROM tribe_members tm
          JOIN users u ON u.user_id = tm.user_id
         WHERE tm.tribe_id IN (SELECT tribe_id FROM my_tribes)
           AND u.user_id <> v_me
           AND u.account_status = 'active'
           AND COALESCE(u.safety_tier, 'standard') <> 'restricted_minor'
           AND NOT EXISTS (SELECT 1 FROM my_friends f WHERE f.other_id = u.user_id)
           AND NOT EXISTS (SELECT 1 FROM my_blocks b WHERE b.blocked_id = u.user_id)
         GROUP BY u.user_id
    )
    SELECT
        u.user_id,
        u.anonymous_pseudonym::TEXT                     AS pseudonym,
        COALESCE(u.avatar_seed, 'default-orb')::TEXT    AS avatar_seed,
        u.profile_photo_url::TEXT                       AS profile_photo_url,
        COALESCE(u.is_verified, false)                  AS is_verified,
        c.shared_tribes                                 AS shared_tribes,
        CASE WHEN c.shared_tribes > 1
             THEN c.shared_tribes || ' Mutual Tribes'
             ELSE '1 Mutual Tribe' END::TEXT            AS rationale
      FROM candidates c
      JOIN users u ON u.user_id = c.user_id
     ORDER BY c.shared_tribes DESC, u.karma_points DESC
     LIMIT GREATEST(1, LEAST(p_limit, 20));
END $$;

REVOKE ALL ON FUNCTION public.friend_suggestions(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_suggestions(INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
