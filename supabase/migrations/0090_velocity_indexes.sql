-- 0090_velocity_indexes.sql
-- Support indexes for the velocity/suspension triggers (migration 0088). Each
-- BEFORE INSERT guard runs a `count(*) WHERE <author> = ? AND created_at > now()
-- - 60s`; without a matching composite index that's a seq scan on the write
-- path at scale.
--
-- posts already has idx_posts_author_created, but it's PARTIAL
-- (WHERE deleted_at IS NULL) and the guard's count doesn't reference deleted_at,
-- so the planner can't use it — add a plain composite for the guard path.
--
-- NOTE @ scale: these tables are small pre-launch so a normal CREATE INDEX is
-- instant. If any table is already large when this runs, build these with
-- CREATE INDEX CONCURRENTLY *outside* a migration transaction to avoid locking
-- writes during the build.

CREATE INDEX IF NOT EXISTS idx_posts_author_created_all
    ON public.posts (author_id, created_at);

CREATE INDEX IF NOT EXISTS idx_comments_author_created
    ON public.posts_comments (author_id, created_at);

CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_created
    ON public.chat_messages (sender_id, created_at);

CREATE INDEX IF NOT EXISTS idx_tribe_messages_sender_created
    ON public.tribe_messages (sender_id, created_at);
