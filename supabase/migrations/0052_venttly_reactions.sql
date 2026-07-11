-- 0052_venttly_reactions.sql
--
-- Replace the original six-emotion reaction set with the Venttly
-- seven. The old set leaned generic ('like', 'crazy'); the new set
-- speaks the platform's emotional vocabulary so a Vent feels less
-- like a Facebook post and more like a moment of support.
--
--   Old enum (0016)            →  New enum (0052)
--   ─────────────────────────     ─────────────────────────
--   hug         (🫂 hug)           hug      🫂 I Relate
--   like                          love     ❤️ Sending Love
--   relate                        felt     🥺 Felt This
--   stay_strong                   strong   💪 Stay Strong
--   been_there                    felt     🥺 Felt This
--   crazy                         felt     🥺 Felt This
--                                 hope     🌱 Hope          (new)
--                                 pray     🙏 Praying       (new)
--                                 proud    👏 Proud of You  (new)
--
-- Postgres doesn't let you drop enum values, so we build a new
-- enum, migrate the column with a USING clause, drop the old
-- enum, rename the new one back to `reaction_type`. Idempotent
-- via the existence checks at the top.

DO $$
BEGIN
    -- Skip if migration has already run.
    IF EXISTS (
        SELECT 1
          FROM pg_type t
          JOIN pg_enum e ON e.enumtypid = t.oid
         WHERE t.typname = 'reaction_type'
           AND e.enumlabel = 'love'
    ) THEN
        RAISE NOTICE '0052 already applied (love enum value present), skipping.';
        RETURN;
    END IF;

    CREATE TYPE public.reaction_type_v2 AS ENUM (
        'hug', 'love', 'strong', 'hope', 'pray', 'felt', 'proud'
    );

    -- Migrate post_likes.reaction_type → v2 with explicit remap.
    ALTER TABLE public.post_likes
        ALTER COLUMN reaction_type DROP DEFAULT;

    ALTER TABLE public.post_likes
        ALTER COLUMN reaction_type TYPE public.reaction_type_v2
        USING (
            CASE reaction_type::text
                WHEN 'hug'         THEN 'hug'
                WHEN 'like'        THEN 'love'
                WHEN 'relate'      THEN 'felt'
                WHEN 'stay_strong' THEN 'strong'
                WHEN 'been_there'  THEN 'felt'
                WHEN 'crazy'       THEN 'felt'
                ELSE                    'felt'
            END
        )::public.reaction_type_v2;

    ALTER TABLE public.post_likes
        ALTER COLUMN reaction_type SET DEFAULT 'love'::public.reaction_type_v2;

    -- Drop the old set_reaction RPC (signature is tied to the old enum).
    DROP FUNCTION IF EXISTS public.set_reaction(UUID, public.reaction_type);

    -- Now safe to drop the old enum and rename v2 back to the
    -- canonical name; nothing else references reaction_type.
    DROP TYPE public.reaction_type;
    ALTER TYPE public.reaction_type_v2 RENAME TO reaction_type;
END $$;

-- Re-create set_reaction against the new enum.
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

NOTIFY pgrst, 'reload schema';
