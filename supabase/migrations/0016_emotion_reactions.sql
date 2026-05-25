-- =====================================================================
-- Migration 0016 — emotion-based reactions
-- =====================================================================
-- Replaces the binary "like" with a small palette of emotionally
-- meaningful reactions, while keeping the existing posts.likes_count
-- semantics (total reactions of any kind). One reaction per user per
-- post — switching reaction is an UPDATE, not a stack.
--
--   like         a quiet "I see you"  (legacy default)
--   relate       "this is me"
--   hug          "sending warmth"
--   stay_strong  "rooting for you"
--   been_there   "I've lived this"
--   crazy        "wow / unexpected"
-- =====================================================================

-- 1. Enum. Idempotent guard so the migration is re-runnable.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'reaction_type') THEN
        CREATE TYPE public.reaction_type AS ENUM (
            'like', 'relate', 'hug', 'stay_strong', 'been_there', 'crazy'
        );
    END IF;
END $$;

-- 2. Column on post_likes. Default 'like' covers the backfill.
ALTER TABLE public.post_likes
    ADD COLUMN IF NOT EXISTS reaction_type public.reaction_type
        NOT NULL DEFAULT 'like';

CREATE INDEX IF NOT EXISTS idx_post_likes_reaction
    ON public.post_likes(post_id, reaction_type);

-- 3. RPC: set_reaction(post_id, reaction_type)
--    - If the caller has no reaction on the post  → INSERT
--    - If the caller's existing reaction == p_reaction → DELETE (toggle off)
--    - Otherwise                                  → UPDATE the type
--    Returns the resulting reaction (or NULL when toggled off) so the
--    caller can update local state without a follow-up read.
CREATE OR REPLACE FUNCTION public.set_reaction(
    p_post_id  UUID,
    p_reaction public.reaction_type
) RETURNS public.reaction_type
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid     UUID := auth.uid();
    v_current public.reaction_type;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated';
    END IF;

    SELECT reaction_type INTO v_current
      FROM post_likes
     WHERE post_id = p_post_id AND user_id = v_uid;

    IF v_current IS NULL THEN
        INSERT INTO post_likes(post_id, user_id, reaction_type)
        VALUES (p_post_id, v_uid, p_reaction);
        RETURN p_reaction;
    END IF;

    IF v_current = p_reaction THEN
        DELETE FROM post_likes
         WHERE post_id = p_post_id AND user_id = v_uid;
        RETURN NULL;
    END IF;

    UPDATE post_likes
       SET reaction_type = p_reaction
     WHERE post_id = p_post_id AND user_id = v_uid;
    RETURN p_reaction;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_reaction(UUID, public.reaction_type)
    TO authenticated;

-- =====================================================================
-- 0016 done.
-- =====================================================================
