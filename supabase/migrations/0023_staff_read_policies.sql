-- 0023_staff_read_policies.sql
--
-- Without these policies the admin console couldn't function unless the
-- operator pasted a service-role key in .env.local. That made local-dev
-- onboarding brittle (users page showed 0 rows, audit-export returned
-- "Invalid API key") and forced every staff member to handle the most
-- powerful credential in the system.
--
-- These policies let staff roles read soft-deleted content and private
-- tribes via the standard cookie-bound client, so the admin console
-- works with just the anon key + auth cookie. The service-role key
-- becomes an optional fast path, not a hard dependency.
--
-- Writes still go through SECURITY DEFINER admin_* RPCs (migration 0022),
-- which already check role inside the function body.

-- ---------------------------------------------------------------------------
-- posts: staff see deleted posts too
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "posts staff full read" ON public.posts;
CREATE POLICY "posts staff full read" ON public.posts FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','moderator','read_only_auditor')
      )
    );

-- ---------------------------------------------------------------------------
-- posts_comments: same staff bypass for deleted comments
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "comments staff full read" ON public.posts_comments;
CREATE POLICY "comments staff full read" ON public.posts_comments FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','moderator','read_only_auditor')
      )
    );

-- ---------------------------------------------------------------------------
-- tribes: staff can see private tribes too
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "tribes staff full read" ON public.tribes;
CREATE POLICY "tribes staff full read" ON public.tribes FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','moderator','read_only_auditor')
      )
    );

-- ---------------------------------------------------------------------------
-- reports: extend admin read to admin/moderator/auditor (was super_admin only)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "reports admin read" ON public.reports;
CREATE POLICY "reports admin read" ON public.reports FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','moderator','read_only_auditor')
      )
    );

-- ---------------------------------------------------------------------------
-- tribe_members: staff can see all memberships for tribe-detail page
-- (default policy "tribe_members readable" is already USING (true), so this
-- is a no-op — kept here for clarity and in case the readable policy ever
-- tightens.)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- user_badges, user_streaks: read-only data on the user detail page. The
-- existing badges policy is USING(true) and streaks is owner-only — extend
-- streaks so staff see other users' streaks too.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "user_streaks staff read" ON public.user_streaks;
CREATE POLICY "user_streaks staff read" ON public.user_streaks FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','moderator','read_only_auditor')
      )
    );

-- ---------------------------------------------------------------------------
-- post_likes: needed by analytics page
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "post_likes staff read" ON public.post_likes;
CREATE POLICY "post_likes staff read" ON public.post_likes FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','analyst','read_only_auditor')
      )
    );
