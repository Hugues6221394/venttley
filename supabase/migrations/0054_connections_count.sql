-- 0054_connections_count.sql
--
-- "Connections" = accepted friendships. Surfaces the count on a
-- public profile as e.g. "30K Connections" without paying a
-- COUNT(*) on every profile open.
--
-- Scale rationale:
--
--   * Denormalized column `users.connections_count` is the
--     authoritative counter. Read path is O(1).
--
--   * A pair of triggers on `friendships` keeps the counter in
--     sync as rows flip from pending → accepted, accepted → deleted,
--     or get blown away by a block. Both endpoints (user_a and
--     user_b) get incremented/decremented.
--
--   * Backfill runs once during this migration so existing data
--     starts consistent. Subsequent friend churn is handled by
--     the triggers.
--
--   * Counter is clamped at zero (GREATEST(c-1, 0)) so a stray
--     double-delete or a rogue tool never produces a negative.

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS connections_count INTEGER NOT NULL DEFAULT 0
        CHECK (connections_count >= 0);

CREATE INDEX IF NOT EXISTS users_connections_count_idx
    ON public.users (connections_count DESC)
    WHERE connections_count > 0;

-- =====================================================================
-- 1. Trigger function: react to friendship lifecycle.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.trg_friendship_connections_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- New rows usually arrive as 'pending'; only count if they
        -- somehow land as 'accepted' on insert (admin tooling, seed).
        IF NEW.status = 'accepted' THEN
            UPDATE users SET connections_count = connections_count + 1
             WHERE user_id IN (NEW.user_a, NEW.user_b);
        END IF;

    ELSIF TG_OP = 'UPDATE' THEN
        -- pending → accepted: both endpoints gain a connection.
        IF OLD.status <> 'accepted' AND NEW.status = 'accepted' THEN
            UPDATE users SET connections_count = connections_count + 1
             WHERE user_id IN (NEW.user_a, NEW.user_b);
        -- accepted → pending (rare, but defensive): both lose one.
        ELSIF OLD.status = 'accepted' AND NEW.status <> 'accepted' THEN
            UPDATE users
               SET connections_count = GREATEST(connections_count - 1, 0)
             WHERE user_id IN (NEW.user_a, NEW.user_b);
        END IF;

    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.status = 'accepted' THEN
            UPDATE users
               SET connections_count = GREATEST(connections_count - 1, 0)
             WHERE user_id IN (OLD.user_a, OLD.user_b);
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS friendships_connections_count ON public.friendships;
CREATE TRIGGER friendships_connections_count
    AFTER INSERT OR UPDATE OR DELETE ON public.friendships
    FOR EACH ROW EXECUTE FUNCTION public.trg_friendship_connections_count();

-- =====================================================================
-- 2. One-off backfill from existing accepted friendships.
--    Idempotent: zero-out first, then re-tally.
-- =====================================================================

UPDATE public.users SET connections_count = 0;

UPDATE public.users u
   SET connections_count = c.cnt
  FROM (
        SELECT user_id, COUNT(*)::INT AS cnt
          FROM (
              SELECT user_a AS user_id FROM friendships WHERE status = 'accepted'
              UNION ALL
              SELECT user_b AS user_id FROM friendships WHERE status = 'accepted'
          ) x
         GROUP BY user_id
  ) c
 WHERE u.user_id = c.user_id;

NOTIFY pgrst, 'reload schema';
