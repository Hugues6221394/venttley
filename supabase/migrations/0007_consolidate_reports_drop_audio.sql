-- ============================================================================
-- Venttly | Migration 0007 — consolidate report tables, drop voice/audio
--
-- Two clean-ups bundled together because they're both v1-scope honesty:
--
-- (a) The codebase had two report tables — `moderation_reports` (from the
--     original schema, supports post + comment + room targets but with a
--     stale category list) and `post_reports` (migration 0006, post-only,
--     up-to-date category list with the safety-AI mapping). Consolidate
--     into a single `reports` table whose category list matches the safety
--     pipeline and whose target columns cover all three cases.
--
-- (b) Voice masking + voice posting were cut from v1 scope. The audio
--     columns on `posts` are dead schema; dropping them simplifies the
--     `feed_posts` view as well.
-- ============================================================================

-- 1) ============ Reports: generalize + replace =============================

DROP TABLE IF EXISTS public.moderation_reports CASCADE;

ALTER TABLE public.post_reports RENAME TO reports;
ALTER TABLE public.reports ALTER COLUMN post_id DROP NOT NULL;

ALTER TABLE public.reports
    ADD COLUMN IF NOT EXISTS target_comment_id UUID
        REFERENCES public.posts_comments(comment_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS target_room_id UUID
        REFERENCES public.chat_rooms(room_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS is_resolved BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS resolved_by UUID
        REFERENCES public.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;

-- One target per report — and exactly one.
ALTER TABLE public.reports DROP CONSTRAINT IF EXISTS reports_one_target;
ALTER TABLE public.reports
    ADD CONSTRAINT reports_one_target CHECK (
        (CASE WHEN post_id           IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN target_comment_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN target_room_id    IS NOT NULL THEN 1 ELSE 0 END) = 1
    );

-- The renamed table inherited the old UNIQUE(post_id, reporter_id) under
-- its previous name. Drop it and replace with per-target partial uniques
-- so the same flow works for posts, comments, and chats.
ALTER TABLE public.reports
    DROP CONSTRAINT IF EXISTS post_reports_post_id_reporter_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS reports_unique_post
    ON public.reports(post_id, reporter_id)
    WHERE post_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS reports_unique_comment
    ON public.reports(target_comment_id, reporter_id)
    WHERE target_comment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS reports_unique_room
    ON public.reports(target_room_id, reporter_id)
    WHERE target_room_id IS NOT NULL;

-- Backfill the old index name on post_id to use the new column reference.
DROP INDEX IF EXISTS idx_post_reports_post;
CREATE INDEX IF NOT EXISTS idx_reports_post
    ON public.reports(post_id, created_at DESC)
    WHERE post_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_reports_room
    ON public.reports(target_room_id, created_at DESC)
    WHERE target_room_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_reports_unresolved
    ON public.reports(is_resolved, created_at ASC)
    WHERE is_resolved = false;

-- Rotate the RLS policy names so they describe the renamed table.
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "post_reports insert auth" ON public.reports;
DROP POLICY IF EXISTS "post_reports admin read"  ON public.reports;
DROP POLICY IF EXISTS "reports insert auth"      ON public.reports;
DROP POLICY IF EXISTS "reports admin read"       ON public.reports;

CREATE POLICY "reports insert auth"
    ON public.reports FOR INSERT
    WITH CHECK (
        auth.uid() IS NOT NULL
        AND reporter_id = auth.uid()
    );

CREATE POLICY "reports admin read"
    ON public.reports FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.users u
             WHERE u.user_id   = auth.uid()
               AND u.user_role = 'super_admin'
        )
    );

-- 2) ============ Drop audio scaffolding from posts =========================

-- feed_posts depends on the audio columns; drop & recreate without them.
DROP VIEW IF EXISTS public.feed_posts;

ALTER TABLE public.posts
    DROP COLUMN IF EXISTS is_audio,
    DROP COLUMN IF EXISTS audio_url,
    DROP COLUMN IF EXISTS audio_duration_ms;

CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(u.avatar_seed, 'default-orb')               AS author_avatar_seed,
    COALESCE(u.is_verified, false)                       AS author_is_verified,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users  u ON u.user_id  = p.author_id
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
