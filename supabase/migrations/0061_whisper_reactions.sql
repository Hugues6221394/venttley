-- 0061_whisper_reactions.sql
--
-- Upgrade whisper "likes" to the full Venttly seven-reaction palette.
-- Uses TEXT (not post_likes.reaction_type enum) so this works whether
-- or not migration 0052 has been applied to posts.

CREATE TABLE IF NOT EXISTS public.whisper_reactions (
    whisper_id    UUID NOT NULL REFERENCES public.whispers(whisper_id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    reaction_type TEXT NOT NULL CHECK (
        reaction_type IN ('hug', 'love', 'strong', 'hope', 'pray', 'felt', 'proud')
    ) DEFAULT 'love',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (whisper_id, user_id)
);

CREATE INDEX IF NOT EXISTS whisper_reactions_whisper_idx
    ON public.whisper_reactions (whisper_id);

ALTER TABLE public.whisper_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "whisper reactions read" ON public.whisper_reactions;
CREATE POLICY "whisper reactions read"
    ON public.whisper_reactions FOR SELECT
    USING (true);

GRANT SELECT ON public.whisper_reactions TO authenticated;

-- Migrate legacy heart-only likes.
INSERT INTO public.whisper_reactions (whisper_id, user_id, reaction_type, created_at)
SELECT whisper_id, user_id, 'love', created_at
  FROM public.whisper_likes
ON CONFLICT DO NOTHING;

DROP TABLE IF EXISTS public.whisper_likes CASCADE;

-- Keep likes_count in sync with total reaction rows.
CREATE OR REPLACE FUNCTION public._sync_whisper_reaction_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_whisper UUID;
    v_count   INT;
BEGIN
    v_whisper := COALESCE(NEW.whisper_id, OLD.whisper_id);
    SELECT count(*)::INT INTO v_count
      FROM whisper_reactions
     WHERE whisper_id = v_whisper;
    UPDATE whispers
       SET likes_count = v_count
     WHERE whisper_id = v_whisper;
    RETURN COALESCE(NEW, OLD);
END $$;

DROP TRIGGER IF EXISTS whisper_reactions_count_trg ON public.whisper_reactions;
CREATE TRIGGER whisper_reactions_count_trg
    AFTER INSERT OR UPDATE OR DELETE ON public.whisper_reactions
    FOR EACH ROW EXECUTE FUNCTION public._sync_whisper_reaction_count();

-- Backfill counts after migration.
UPDATE whispers w
   SET likes_count = COALESCE((
       SELECT count(*)::INT FROM whisper_reactions r WHERE r.whisper_id = w.whisper_id
   ), 0);

-- ---------------------------------------------------------------------------
-- set_whisper_reaction — toggle / swap / clear (mirrors set_reaction)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_whisper_reaction(
    p_whisper_id UUID,
    p_reaction   TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me      UUID := auth.uid();
    v_current TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_reaction IS NOT NULL AND p_reaction NOT IN (
        'hug', 'love', 'strong', 'hope', 'pray', 'felt', 'proud'
    ) THEN
        RAISE EXCEPTION 'invalid reaction';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM whispers
         WHERE whisper_id = p_whisper_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'whisper not found';
    END IF;

    SELECT reaction_type INTO v_current
      FROM whisper_reactions
     WHERE whisper_id = p_whisper_id AND user_id = v_me;

    IF v_current IS NULL THEN
        INSERT INTO whisper_reactions (whisper_id, user_id, reaction_type)
        VALUES (p_whisper_id, v_me, p_reaction);
        RETURN p_reaction;
    END IF;

    IF v_current = p_reaction THEN
        DELETE FROM whisper_reactions
         WHERE whisper_id = p_whisper_id AND user_id = v_me;
        RETURN NULL;
    END IF;

    UPDATE whisper_reactions
       SET reaction_type = p_reaction
     WHERE whisper_id = p_whisper_id AND user_id = v_me;
    RETURN p_reaction;
END $$;

REVOKE ALL ON FUNCTION public.set_whisper_reaction(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_whisper_reaction(UUID, TEXT) TO authenticated;

-- Back-compat heart toggle — maps to love reaction.
CREATE OR REPLACE FUNCTION public.toggle_whisper_like(p_whisper_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result TEXT;
BEGIN
    v_result := set_whisper_reaction(p_whisper_id, 'love');
    RETURN v_result IS NOT NULL;
END $$;

REVOKE ALL ON FUNCTION public.toggle_whisper_like(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_whisper_like(UUID) TO authenticated;

-- Summary view — counts + caller's reaction in one read.
DROP VIEW IF EXISTS public.whisper_reactions_summary;
CREATE VIEW public.whisper_reactions_summary
WITH (security_invoker = true) AS
SELECT
    r.whisper_id,
    jsonb_object_agg(r.reaction_type, c) AS reaction_counts,
    (
        SELECT reaction_type
          FROM whisper_reactions
         WHERE whisper_id = r.whisper_id AND user_id = auth.uid()
    ) AS my_reaction
FROM (
    SELECT whisper_id, reaction_type, count(*)::int AS c
      FROM whisper_reactions
     GROUP BY whisper_id, reaction_type
) r
GROUP BY r.whisper_id;

GRANT SELECT ON public.whisper_reactions_summary TO authenticated;

NOTIFY pgrst, 'reload schema';
