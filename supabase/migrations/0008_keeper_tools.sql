-- ============================================================================
-- Venttly | Migration 0008 — Keeper tools
--
-- Powers the creator dashboard (`/tribe/:slug/manage`) by letting tribe
-- Keepers do three things they couldn't before:
--   1. Create Question-of-the-Day prompts pinned to their own tribe.
--   2. Read the report queue for posts in their own tribe.
--   3. Mark those reports resolved.
--
-- Existing policy already lets keepers UPDATE their own tribes
-- (migration 0005, "tribes update keeper"), so no change needed there.
-- ============================================================================

-- 1) Broaden plug_prompts so it can anchor to a Tribe, not just a Plug.
--    plug_id was previously NOT NULL and FK'd to plug_profiles — only
--    verified Plugz could write. v1 hybrid model treats every tribe Keeper
--    as a creator, so we make plug_id optional and add tribe_id.
ALTER TABLE public.plug_prompts
    ADD COLUMN IF NOT EXISTS tribe_id UUID
        REFERENCES public.tribes(tribe_id) ON DELETE CASCADE;

ALTER TABLE public.plug_prompts ALTER COLUMN plug_id DROP NOT NULL;

-- A prompt must be anchored to *something* — at least one of plug_id or
-- tribe_id is required.
ALTER TABLE public.plug_prompts
    DROP CONSTRAINT IF EXISTS plug_prompts_anchor_check;
ALTER TABLE public.plug_prompts
    ADD CONSTRAINT plug_prompts_anchor_check
    CHECK (plug_id IS NOT NULL OR tribe_id IS NOT NULL);

-- Replace the strict plug-only write policy with one that also allows
-- the Keeper of the prompt's tribe to write.
DROP POLICY IF EXISTS "prompts plug write"           ON public.plug_prompts;
DROP POLICY IF EXISTS "prompts plug or keeper write" ON public.plug_prompts;
CREATE POLICY "prompts plug or keeper write"
    ON public.plug_prompts FOR ALL
    USING (
        (plug_id IS NOT NULL AND plug_id = auth.uid())
        OR
        (tribe_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = plug_prompts.tribe_id
               AND t.keeper_id = auth.uid()
        ))
    )
    WITH CHECK (
        (plug_id IS NOT NULL AND plug_id = auth.uid())
        OR
        (tribe_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = plug_prompts.tribe_id
               AND t.keeper_id = auth.uid()
        ))
    );

-- 2) Reports: let Keepers read reports against posts in their own tribe.
DROP POLICY IF EXISTS "reports keeper read" ON public.reports;
CREATE POLICY "reports keeper read"
    ON public.reports FOR SELECT
    USING (
        post_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.posts p
             JOIN public.tribes t ON t.tribe_id = p.tribe_id
             WHERE p.post_id   = reports.post_id
               AND t.keeper_id = auth.uid()
        )
    );

-- 3) Reports: let Keepers mark them resolved (e.g. after they delete the post).
DROP POLICY IF EXISTS "reports keeper update" ON public.reports;
CREATE POLICY "reports keeper update"
    ON public.reports FOR UPDATE
    USING (
        post_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.posts p
             JOIN public.tribes t ON t.tribe_id = p.tribe_id
             WHERE p.post_id   = reports.post_id
               AND t.keeper_id = auth.uid()
        )
    )
    WITH CHECK (
        post_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.posts p
             JOIN public.tribes t ON t.tribe_id = p.tribe_id
             WHERE p.post_id   = reports.post_id
               AND t.keeper_id = auth.uid()
        )
    );

NOTIFY pgrst, 'reload schema';
