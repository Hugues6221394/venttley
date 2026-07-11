-- 0081_report_chat_messages.sql
-- Let members report a single offensive message (tribe hub OR DM), not just a
-- whole post/comment/room. Extends the consolidated `reports` table (0007)
-- with two new mutually-exclusive targets and keeps the "exactly one target"
-- invariant. The existing insert RLS policy (reporter_id = auth.uid()) is
-- target-agnostic, so no policy change is needed; super_admin/staff read stays
-- as-is. Dedup mirrors the other targets (one report per user per message).

ALTER TABLE public.reports
    ADD COLUMN IF NOT EXISTS target_tribe_message_id UUID
        REFERENCES public.tribe_messages(message_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS target_chat_message_id UUID
        REFERENCES public.chat_messages(message_id) ON DELETE CASCADE;

-- Re-assert "exactly one target" across all five columns.
ALTER TABLE public.reports DROP CONSTRAINT IF EXISTS reports_one_target;
ALTER TABLE public.reports
    ADD CONSTRAINT reports_one_target CHECK (
        (CASE WHEN post_id                 IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN target_comment_id       IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN target_room_id          IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN target_tribe_message_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN target_chat_message_id  IS NOT NULL THEN 1 ELSE 0 END) = 1
    );

-- One flag per user per message.
CREATE UNIQUE INDEX IF NOT EXISTS reports_unique_tribe_message
    ON public.reports(target_tribe_message_id, reporter_id)
    WHERE target_tribe_message_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS reports_unique_chat_message
    ON public.reports(target_chat_message_id, reporter_id)
    WHERE target_chat_message_id IS NOT NULL;

-- Triage lookups by message.
CREATE INDEX IF NOT EXISTS idx_reports_tribe_message
    ON public.reports(target_tribe_message_id, created_at DESC)
    WHERE target_tribe_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_reports_chat_message
    ON public.reports(target_chat_message_id, created_at DESC)
    WHERE target_chat_message_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';
