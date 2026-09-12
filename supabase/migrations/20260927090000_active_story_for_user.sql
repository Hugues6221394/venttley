-- Does this person have a story running right now?
--
-- The app has no way to ask. friend_stories_for_me returns every visible
-- story at once, which is right for the home rail and useless on a profile:
-- opening somebody's profile should not fetch and rank the whole rail to work
-- out whether that one person has posted in the last day.
--
-- Without it the profile avatar can only ever do one thing — open the profile
-- photo — even when the person has a story sitting unwatched. Everywhere else
-- in this app an avatar with a story gets a ring and takes you to the story;
-- on the profile screen, the one place someone deliberately went to look at a
-- person, there was nothing.
--
-- VISIBILITY IS THE SAME RULE AS THE RAIL, DELIBERATELY
--
-- Self, or an accepted friend. Copied from friend_stories_for_me rather than
-- invented here, because two functions answering "may I see this story?"
-- differently is how one of them ends up leaking. If the audience rules change
-- later they must change in both, and the comment in each should say so.
--
-- Note that story_audience is not consulted, matching friend_stories_for_me
-- exactly. That column is currently ignored by the only query that reads
-- stories, so an 'everyone' story is in practice friends-only. Honouring it
-- would widen who can see a story, which is a product decision rather than a
-- bug fix, and it must be made in one place for both functions at once.

BEGIN;

CREATE OR REPLACE FUNCTION public.active_story_for_user(p_user_id UUID)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT p.post_id
    FROM public.posts AS p
   WHERE p.author_id = p_user_id
     AND p.is_story = TRUE
     AND p.deleted_at IS NULL
     AND p.created_at > now() - INTERVAL '24 hours'
     -- Blocked media never surfaces, here as anywhere else. A story whose
     -- image the scanner refused must not be reachable from a profile.
     AND p.media_status <> 'blocked'
     AND (SELECT auth.uid()) IS NOT NULL
     AND (
       p.author_id = (SELECT auth.uid())
       OR EXISTS (
         SELECT 1
           FROM public.friendships AS f
          WHERE f.status = 'accepted'
            AND (
              (f.user_a = (SELECT auth.uid()) AND f.user_b = p.author_id)
              OR
              (f.user_b = (SELECT auth.uid()) AND f.user_a = p.author_id)
            )
       )
     )
   -- Newest, so tapping through lands on the same story the rail would open.
   ORDER BY p.created_at DESC
   LIMIT 1;
$$;

COMMENT ON FUNCTION public.active_story_for_user(UUID) IS
  'The newest story by this person that the caller may watch, or NULL. Visibility mirrors friend_stories_for_me — self or accepted friend — and both must change together.';

REVOKE ALL ON FUNCTION public.active_story_for_user(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.active_story_for_user(UUID) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260927090000', 'active_story_for_user'
);

NOTIFY pgrst, 'reload schema';
