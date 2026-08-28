BEGIN;

-- The UI already removes Stories after 24 hours, but the same product
-- contract must hold at the Data API boundary. A restrictive policy composes
-- with every existing permissive posts-read policy, preventing older clients
-- from querying expired Story rows directly.
DROP POLICY IF EXISTS "active stories only" ON public.posts;
CREATE POLICY "active stories only"
ON public.posts
AS RESTRICTIVE
FOR SELECT
TO anon, authenticated
USING (
  is_story = FALSE
  OR created_at > now() - INTERVAL '24 hours'
);

COMMIT;
