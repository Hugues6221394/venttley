-- 0100_private_tribes_and_categories.sql
-- Two Create-Tribe fixes:
--  1) PRIVATE TRIBE POSTS were NOT actually hidden. The "posts readable" policy
--     was USING (deleted_at IS NULL) — every post visible to everyone. Now a
--     post that belongs to a PRIVATE tribe is readable ONLY by members (and
--     insertable only by members). Public-tribe + global (tribe_id NULL) posts
--     are unaffected. feed_posts is security_invoker, so it inherits this.
--  2) CUSTOM CATEGORIES: the tribes.category CHECK hard-coded 6 values, blocking
--     new presets and user-created categories. Relaxed to free text (bounded).

-- ---- 1) Private-tribe post gating -----------------------------------------
DROP POLICY IF EXISTS "posts readable" ON public.posts;
CREATE POLICY "posts readable"
    ON public.posts FOR SELECT
    USING (
        deleted_at IS NULL
        AND (
            tribe_id IS NULL
            OR NOT EXISTS (
                SELECT 1 FROM public.tribes t
                 WHERE t.tribe_id = posts.tribe_id AND t.is_private
            )
            OR EXISTS (
                SELECT 1 FROM public.tribe_members tm
                 WHERE tm.tribe_id = posts.tribe_id AND tm.user_id = auth.uid()
            )
        )
    );

DROP POLICY IF EXISTS "posts insert auth" ON public.posts;
CREATE POLICY "posts insert auth"
    ON public.posts FOR INSERT
    WITH CHECK (
        auth.uid() IS NOT NULL
        AND author_id = auth.uid()
        AND (
            tribe_id IS NULL
            OR NOT EXISTS (
                SELECT 1 FROM public.tribes t
                 WHERE t.tribe_id = posts.tribe_id AND t.is_private
            )
            OR EXISTS (
                SELECT 1 FROM public.tribe_members tm
                 WHERE tm.tribe_id = posts.tribe_id AND tm.user_id = auth.uid()
            )
        )
    );

-- ---- 2) Free-text tribe categories (presets + custom) ---------------------
ALTER TABLE public.tribes DROP CONSTRAINT IF EXISTS tribes_category_check;
ALTER TABLE public.tribes
    ADD CONSTRAINT tribes_category_check
    CHECK (category IS NULL OR char_length(btrim(category)) BETWEEN 2 AND 40);

NOTIFY pgrst, 'reload schema';
