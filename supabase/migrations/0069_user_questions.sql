-- ============================================================================
-- 0069: Member questions — every user can ask their connections (or everyone)
--
-- plug_prompts was plug-only (plug_id NOT NULL → plug_profiles, RLS write
-- gated on plug_id = auth.uid()). This opens authorship to members:
--   * plug_id becomes optional
--   * author_id references users for member-authored questions
--   * audience: 'everyone' | 'friends' (friends = accepted connections)
--   * RLS: members insert/update/delete their own; friends-only questions
--     are visible only to accepted connections of the author
-- ============================================================================

ALTER TABLE public.plug_prompts
    ALTER COLUMN plug_id DROP NOT NULL;

ALTER TABLE public.plug_prompts
    ADD COLUMN IF NOT EXISTS author_id UUID
        REFERENCES public.users(user_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS audience TEXT NOT NULL DEFAULT 'everyone'
        CHECK (audience IN ('everyone', 'friends'));

CREATE INDEX IF NOT EXISTS idx_plug_prompts_author
    ON public.plug_prompts(author_id);

-- Either a plug question or a member question — never both, never neither.
ALTER TABLE public.plug_prompts
    DROP CONSTRAINT IF EXISTS plug_prompts_one_author;
ALTER TABLE public.plug_prompts
    ADD CONSTRAINT plug_prompts_one_author
    CHECK (
        (plug_id IS NOT NULL AND author_id IS NULL)
        OR (plug_id IS NULL AND author_id IS NOT NULL)
    ) NOT VALID;  -- NOT VALID: legacy rows predate author_id

-- 0008 added plug_prompts_anchor_check (plug_id OR tribe_id) — before member
-- authorship existed. A member question is anchored by author_id alone, so
-- widen the anchor to accept it, otherwise the insert violates 0008's check.
ALTER TABLE public.plug_prompts
    DROP CONSTRAINT IF EXISTS plug_prompts_anchor_check;
ALTER TABLE public.plug_prompts
    ADD CONSTRAINT plug_prompts_anchor_check
    CHECK (
        plug_id IS NOT NULL OR tribe_id IS NOT NULL OR author_id IS NOT NULL
    ) NOT VALID;  -- NOT VALID: skip validating any pre-existing rows

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

-- Visibility: public questions for all; friends-only for accepted
-- connections of the author (and the author + plug owners themselves).
DROP POLICY IF EXISTS "prompts readable" ON public.plug_prompts;
CREATE POLICY "prompts readable" ON public.plug_prompts
    FOR SELECT USING (
        audience = 'everyone'
        OR plug_id = auth.uid()
        OR author_id = auth.uid()
        OR (
            audience = 'friends'
            AND EXISTS (
                SELECT 1 FROM public.friendships f
                WHERE f.status = 'accepted'
                  AND (
                    (f.user_a = plug_prompts.author_id AND f.user_b = auth.uid())
                    OR (f.user_b = plug_prompts.author_id AND f.user_a = auth.uid())
                  )
            )
        )
    );

DROP POLICY IF EXISTS "prompts member insert" ON public.plug_prompts;
CREATE POLICY "prompts member insert" ON public.plug_prompts
    FOR INSERT WITH CHECK (
        auth.uid() IS NOT NULL
        AND author_id = auth.uid()
        AND plug_id IS NULL
    );

DROP POLICY IF EXISTS "prompts member update" ON public.plug_prompts;
CREATE POLICY "prompts member update" ON public.plug_prompts
    FOR UPDATE
    USING (author_id = auth.uid())
    WITH CHECK (author_id = auth.uid());

DROP POLICY IF EXISTS "prompts member delete" ON public.plug_prompts;
CREATE POLICY "prompts member delete" ON public.plug_prompts
    FOR DELETE USING (author_id = auth.uid());

NOTIFY pgrst, 'reload schema';
