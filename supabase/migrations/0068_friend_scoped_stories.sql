-- 0068_friend_scoped_stories.sql
-- Production story rail endpoint: real 24h stories from self + accepted friends.

CREATE OR REPLACE FUNCTION public.friend_stories_for_me(p_limit INT DEFAULT 24)
RETURNS SETOF public.feed_posts
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT fp.*
      FROM public.feed_posts fp
     WHERE (SELECT auth.uid()) IS NOT NULL
       AND fp.is_whisper = TRUE
       AND fp.deleted_at IS NULL
       AND fp.created_at > now() - INTERVAL '24 hours'
       AND fp.author_id IS NOT NULL
       AND (
            fp.author_id = (SELECT auth.uid())
            OR EXISTS (
                SELECT 1
                  FROM public.friendships f
                 WHERE f.status = 'accepted'
                   AND (
                        (f.user_a = (SELECT auth.uid()) AND f.user_b = fp.author_id)
                        OR
                        (f.user_b = (SELECT auth.uid()) AND f.user_a = fp.author_id)
                   )
            )
       )
     ORDER BY fp.created_at DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 24), 1), 100);
$$;

REVOKE ALL ON FUNCTION public.friend_stories_for_me(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_stories_for_me(INT) TO authenticated;

CREATE INDEX IF NOT EXISTS story_views_viewer_idx
    ON public.story_views (viewer_id);

