-- 0120_question_engagement.sql
--
-- Engagement + moderation for member-authored questions (the "Ask" feature,
-- built on `plug_prompts` — migration 0069). Adds:
--   • plug_prompts.like_count + a question_likes table (count kept in sync by
--     a trigger) so friends can LIKE a question.
--   • question_reports (write-anyone-signed-in / read-staff) so friends can
--     REPORT a question — mirrors post_reports (migration 0006).
--   • increment_prompt_answers RPC that addPromptAnswer() already calls but
--     which was never defined (the client silently fell back to a racy update).
--   • author edit/delete policies on prompt_answers (0002 shipped only
--     SELECT + INSERT), so an answer author can edit/remove their answer.
--
-- Member questions already carry author_id + audience and author edit/delete
-- RLS from 0069, so the profile "questions asked" section, edit, and delete
-- need no new schema — only client wiring.

-- ── Likes ──────────────────────────────────────────────────────────────────
ALTER TABLE public.plug_prompts
    ADD COLUMN IF NOT EXISTS like_count INT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.question_likes (
    prompt_id  UUID NOT NULL
        REFERENCES public.plug_prompts(prompt_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL
        REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (prompt_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_question_likes_user
    ON public.question_likes(user_id);

ALTER TABLE public.question_likes ENABLE ROW LEVEL SECURITY;

-- Likes are visible only on a prompt the viewer can already see (prompt RLS
-- from 0069 governs which rows the EXISTS sub-select can match).
DROP POLICY IF EXISTS "question_likes read" ON public.question_likes;
CREATE POLICY "question_likes read"
    ON public.question_likes FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.plug_prompts p
            WHERE p.prompt_id = question_likes.prompt_id
        )
    );

DROP POLICY IF EXISTS "question_likes insert self" ON public.question_likes;
CREATE POLICY "question_likes insert self"
    ON public.question_likes FOR INSERT
    WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "question_likes delete self" ON public.question_likes;
CREATE POLICY "question_likes delete self"
    ON public.question_likes FOR DELETE
    USING (user_id = (select auth.uid()));

-- Keep plug_prompts.like_count in sync with the like rows.
CREATE OR REPLACE FUNCTION public._sync_question_like_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.plug_prompts
           SET like_count = like_count + 1
         WHERE prompt_id = NEW.prompt_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.plug_prompts
           SET like_count = GREATEST(0, like_count - 1)
         WHERE prompt_id = OLD.prompt_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_question_like_count ON public.question_likes;
CREATE TRIGGER trg_question_like_count
    AFTER INSERT OR DELETE ON public.question_likes
    FOR EACH ROW EXECUTE FUNCTION public._sync_question_like_count();

REVOKE EXECUTE ON FUNCTION public._sync_question_like_count()
    FROM PUBLIC, anon, authenticated;

-- ── Reports (write-anyone-signed-in / read-staff) ───────────────────────────
CREATE TABLE IF NOT EXISTS public.question_reports (
    report_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prompt_id   UUID NOT NULL
        REFERENCES public.plug_prompts(prompt_id) ON DELETE CASCADE,
    reporter_id UUID NOT NULL
        REFERENCES public.users(user_id) ON DELETE CASCADE,
    reason      TEXT NOT NULL
        CHECK (reason IN ('spam','harassment','hate','sexual','self_harm','other')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (prompt_id, reporter_id)
);
CREATE INDEX IF NOT EXISTS idx_question_reports_prompt
    ON public.question_reports(prompt_id);

ALTER TABLE public.question_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "question_reports insert auth" ON public.question_reports;
CREATE POLICY "question_reports insert auth"
    ON public.question_reports FOR INSERT
    WITH CHECK (
        (select auth.uid()) IS NOT NULL
        AND reporter_id = (select auth.uid())
    );

DROP POLICY IF EXISTS "question_reports staff read" ON public.question_reports;
CREATE POLICY "question_reports staff read"
    ON public.question_reports FOR SELECT
    USING (public.is_staff((select auth.uid())));

-- ── The missing increment_prompt_answers RPC ────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_prompt_answers(p_prompt_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.plug_prompts
       SET answers_count = answers_count + 1
     WHERE prompt_id = p_prompt_id;
$$;
REVOKE EXECUTE ON FUNCTION public.increment_prompt_answers(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.increment_prompt_answers(UUID) TO authenticated;

-- ── Answer edit/delete (author-only) ────────────────────────────────────────
DROP POLICY IF EXISTS "answers author update" ON public.prompt_answers;
CREATE POLICY "answers author update"
    ON public.prompt_answers FOR UPDATE
    USING (author_id = (select auth.uid()))
    WITH CHECK (author_id = (select auth.uid()));

DROP POLICY IF EXISTS "answers author delete" ON public.prompt_answers;
CREATE POLICY "answers author delete"
    ON public.prompt_answers FOR DELETE
    USING (author_id = (select auth.uid()));
