-- ============================================================================
-- Venttly | Migration 0006 — Member reports
--
-- Lets any authenticated user flag a post for moderator review. Reports are
-- intentionally write-only for normal users: insert allowed, never read back.
-- super_admins are the only role that can SELECT, so triage can happen
-- inside the admin tooling without leaking who-flagged-whom to peers.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.post_reports (
    report_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id         UUID NOT NULL
        REFERENCES public.posts(post_id) ON DELETE CASCADE,
    reporter_id     UUID
        REFERENCES public.users(user_id) ON DELETE SET NULL,
    reason          TEXT NOT NULL
        CHECK (reason IN (
            'self_harm', 'hate', 'harassment', 'sexual_content',
            'violence', 'privacy', 'spam', 'other'
        )),
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Prevent the same user from spamming the same post.
    UNIQUE (post_id, reporter_id)
);

CREATE INDEX IF NOT EXISTS idx_post_reports_post
    ON public.post_reports(post_id, created_at DESC);

ALTER TABLE public.post_reports ENABLE ROW LEVEL SECURITY;

-- Anyone signed-in may file a report. The reporter_id MUST match auth.uid()
-- so people can't impersonate someone else's flag.
DROP POLICY IF EXISTS "post_reports insert auth" ON public.post_reports;
CREATE POLICY "post_reports insert auth"
    ON public.post_reports FOR INSERT
    WITH CHECK (
        auth.uid() IS NOT NULL
        AND reporter_id = auth.uid()
    );

-- SELECT is restricted to super_admins. We piggy-back on `users.user_role`
-- so we don't need a separate `is_admin()` function.
DROP POLICY IF EXISTS "post_reports admin read" ON public.post_reports;
CREATE POLICY "post_reports admin read"
    ON public.post_reports FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.users u
             WHERE u.user_id   = auth.uid()
               AND u.user_role = 'super_admin'
        )
    );

NOTIFY pgrst, 'reload schema';
