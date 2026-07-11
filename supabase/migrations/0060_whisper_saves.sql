-- 0060_whisper_saves.sql
--
-- Bookmark whispers — mirrors post_saves for the Whispers feed rail.

CREATE TABLE IF NOT EXISTS public.whisper_saves (
    save_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    whisper_id UUID NOT NULL REFERENCES public.whispers(whisper_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (whisper_id, user_id)
);

CREATE INDEX IF NOT EXISTS whisper_saves_user_idx
    ON public.whisper_saves (user_id, created_at DESC);

ALTER TABLE public.whisper_saves ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "whisper saves self" ON public.whisper_saves;
CREATE POLICY "whisper saves self"
    ON public.whisper_saves FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.whisper_saves TO authenticated;

-- Toggle save — returns TRUE when saved after the call, FALSE when removed.
CREATE OR REPLACE FUNCTION public.toggle_whisper_save(p_whisper_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_exists BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM whispers
         WHERE whisper_id = p_whisper_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'whisper not found';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM whisper_saves
         WHERE whisper_id = p_whisper_id AND user_id = v_me
    ) INTO v_exists;

    IF v_exists THEN
        DELETE FROM whisper_saves
         WHERE whisper_id = p_whisper_id AND user_id = v_me;
        RETURN FALSE;
    ELSE
        INSERT INTO whisper_saves (whisper_id, user_id)
        VALUES (p_whisper_id, v_me)
        ON CONFLICT DO NOTHING;
        RETURN TRUE;
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.toggle_whisper_save(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_whisper_save(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
