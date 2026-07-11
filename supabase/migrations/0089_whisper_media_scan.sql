-- 0089_whisper_media_scan.sql
-- Extend media safety (migration 0087) to WHISPER background images. Mirrors
-- the post path: a whisper created with a background image starts 'pending'
-- (veiled) and the client fires media-scan; the verdict flows back the same way
-- (blocked → trigger soft-deletes it; sensitive → veil). Whispers without a
-- custom image stay 'clean'.

-- 1) create_whisper now stamps media_status atomically at insert (no unsafe
--    window where the image is 'clean' before the scan lands).
CREATE OR REPLACE FUNCTION public.create_whisper(
    p_audio_path             TEXT,
    p_audio_url              TEXT,
    p_audio_duration_seconds INT,
    p_category_name          TEXT,
    p_background_image_url   TEXT DEFAULT NULL,
    p_voice_filter           TEXT DEFAULT 'none',
    p_title                  TEXT DEFAULT NULL,
    p_description            TEXT DEFAULT NULL,
    p_persona_id             UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    INSERT INTO whispers (
        author_id, persona_id, audio_path, audio_url, audio_duration_seconds,
        background_image_url, voice_filter,
        category_name, title, description, media_status
    ) VALUES (
        v_me, p_persona_id, p_audio_path, p_audio_url, p_audio_duration_seconds,
        p_background_image_url, COALESCE(p_voice_filter, 'none'),
        p_category_name, p_title, p_description,
        CASE WHEN p_background_image_url IS NOT NULL THEN 'pending' ELSE 'clean' END
    ) RETURNING whisper_id INTO v_id;

    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.create_whisper(TEXT, TEXT, INT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_whisper(TEXT, TEXT, INT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO authenticated;

-- 2) Expose media_status in whispers_feed (append; keep every existing column).
CREATE OR REPLACE VIEW public.whispers_feed WITH (security_invoker = true) AS
SELECT
    w.whisper_id,
    w.author_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')      AS author_avatar_seed,
    CASE WHEN w.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
                                                                AS author_profile_photo_url,
    COALESCE(u.is_verified, false) AS author_is_verified,
    w.persona_id,
    w.audio_url,
    w.audio_duration_seconds,
    w.background_image_url,
    w.voice_filter,
    w.category_name,
    w.title,
    w.description,
    w.plays_count,
    w.likes_count,
    w.comments_count,
    w.crisis_level,
    w.created_at,
    w.deleted_at,
    w.media_status
FROM public.whispers w
LEFT JOIN public.users    u  ON u.user_id     = w.author_id
LEFT JOIN public.personas pr ON pr.persona_id = w.persona_id
                            AND pr.deleted_at IS NULL;
GRANT SELECT ON public.whispers_feed TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
