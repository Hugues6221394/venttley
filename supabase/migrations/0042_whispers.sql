-- 0042_whispers.sql
--
-- Whispers — short anonymous audio stories. Users record audio, pick a
-- background image, choose a category, optionally tag a voice filter,
-- and publish. Whispers feed is a vertical reels-style scroll where
-- listeners react with hugs / replies / shares.
--
-- This migration ships the metadata + storage + RPCs. The actual voice
-- DSP (deep voice / robot / echo etc) is queued as a follow-up — the
-- `voice_filter` column stores the tag selected at publish time so the
-- DSP pipeline can be swapped in later without breaking existing data.

-- =========================================================================
-- 1) whispers table
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.whispers (
    whisper_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id               UUID REFERENCES public.users(user_id)   ON DELETE SET NULL,
    persona_id              UUID REFERENCES public.personas(persona_id) ON DELETE SET NULL,
    audio_path              TEXT NOT NULL,
    audio_url               TEXT NOT NULL,
    audio_duration_seconds  INT  NOT NULL CHECK (audio_duration_seconds BETWEEN 3 AND 180),
    background_image_url    TEXT,
    voice_filter            TEXT
        CHECK (voice_filter IS NULL OR voice_filter IN (
          'none','deep_voice','robot','echo','synth','soft','dark','anonymous'
        )),
    category_name           VARCHAR(50) NOT NULL CHECK (category_name IN (
        'confessions','testimonies','relationships','family_issues','mental_health',
        'campus_life','adulting','regrets','trauma','friendship','faith_spirituality',
        'questions','secrets','vent_zone','dark_thoughts','funny_confessions',
        'dreams_goals','hot_takes','late_night','healing_corner'
    )),
    title                   TEXT CHECK (title IS NULL OR length(title) <= 80),
    description             TEXT CHECK (description IS NULL OR length(description) <= 500),
    plays_count             INT NOT NULL DEFAULT 0 CHECK (plays_count >= 0),
    likes_count             INT NOT NULL DEFAULT 0 CHECK (likes_count >= 0),
    comments_count          INT NOT NULL DEFAULT 0 CHECK (comments_count >= 0),
    crisis_level            TEXT CHECK (crisis_level IS NULL OR crisis_level IN ('elevated','high')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at              TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS whispers_recent_idx
    ON public.whispers (created_at DESC)
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS whispers_category_idx
    ON public.whispers (category_name, created_at DESC)
    WHERE deleted_at IS NULL;

ALTER TABLE public.whispers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "whispers public read" ON public.whispers;
CREATE POLICY "whispers public read"
    ON public.whispers FOR SELECT
    USING (deleted_at IS NULL);

DROP POLICY IF EXISTS "whispers author update" ON public.whispers;
CREATE POLICY "whispers author update"
    ON public.whispers FOR UPDATE
    USING (author_id = auth.uid())
    WITH CHECK (author_id = auth.uid());

DROP POLICY IF EXISTS "whispers author delete" ON public.whispers;
CREATE POLICY "whispers author delete"
    ON public.whispers FOR DELETE
    USING (author_id = auth.uid());

GRANT SELECT ON public.whispers TO anon, authenticated;

-- =========================================================================
-- 2) whispers-media storage bucket
-- =========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'whispers-media',
    'whispers-media',
    true,
    15 * 1024 * 1024,
    ARRAY[
      'audio/mpeg','audio/mp4','audio/aac','audio/ogg','audio/webm','audio/wav','audio/x-m4a',
      'image/jpeg','image/png','image/webp'
    ]
)
ON CONFLICT (id) DO UPDATE
   SET public             = EXCLUDED.public,
       file_size_limit    = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "whispers media owner insert" ON storage.objects;
CREATE POLICY "whispers media owner insert"
    ON storage.objects FOR INSERT
    WITH CHECK (
      bucket_id = 'whispers-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

DROP POLICY IF EXISTS "whispers media public read" ON storage.objects;
CREATE POLICY "whispers media public read"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'whispers-media');

DROP POLICY IF EXISTS "whispers media owner delete" ON storage.objects;
CREATE POLICY "whispers media owner delete"
    ON storage.objects FOR DELETE
    USING (
      bucket_id = 'whispers-media'
      AND owner = auth.uid()
      AND split_part(name, '/', 1) = auth.uid()::text
    );

-- =========================================================================
-- 3) whispers_feed view — joins author pseudonym/avatar, persona-aware
-- =========================================================================
DROP VIEW IF EXISTS public.whispers_feed;
CREATE VIEW public.whispers_feed WITH (security_invoker = true) AS
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
    w.deleted_at
FROM public.whispers w
LEFT JOIN public.users    u  ON u.user_id     = w.author_id
LEFT JOIN public.personas pr ON pr.persona_id = w.persona_id
                            AND pr.deleted_at IS NULL;
GRANT SELECT ON public.whispers_feed TO anon, authenticated;

-- =========================================================================
-- 4) create_whisper / list_whispers / bump_whisper_plays / like_whisper
-- =========================================================================
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
        category_name, title, description
    ) VALUES (
        v_me, p_persona_id, p_audio_path, p_audio_url, p_audio_duration_seconds,
        p_background_image_url, COALESCE(p_voice_filter, 'none'),
        p_category_name, p_title, p_description
    ) RETURNING whisper_id INTO v_id;

    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.create_whisper(TEXT, TEXT, INT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_whisper(TEXT, TEXT, INT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.bump_whisper_plays(p_whisper_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE whispers SET plays_count = plays_count + 1
     WHERE whisper_id = p_whisper_id AND deleted_at IS NULL;
END $$;

REVOKE ALL ON FUNCTION public.bump_whisper_plays(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bump_whisper_plays(UUID) TO authenticated, anon;

-- whisper_likes — denormalised tally tracked via per-user row so toggles
-- can flip without a separate counter table.
CREATE TABLE IF NOT EXISTS public.whisper_likes (
    whisper_id UUID NOT NULL REFERENCES public.whispers(whisper_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (whisper_id, user_id)
);
ALTER TABLE public.whisper_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "whisper likes self read" ON public.whisper_likes;
CREATE POLICY "whisper likes self read"
    ON public.whisper_likes FOR SELECT
    USING (user_id = auth.uid());
GRANT SELECT ON public.whisper_likes TO authenticated;

CREATE OR REPLACE FUNCTION public.toggle_whisper_like(p_whisper_id UUID)
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
    SELECT EXISTS (
        SELECT 1 FROM whisper_likes
         WHERE whisper_id = p_whisper_id AND user_id = v_me
    ) INTO v_exists;
    IF v_exists THEN
        DELETE FROM whisper_likes
         WHERE whisper_id = p_whisper_id AND user_id = v_me;
        UPDATE whispers SET likes_count = GREATEST(likes_count - 1, 0)
         WHERE whisper_id = p_whisper_id;
        RETURN FALSE;
    ELSE
        INSERT INTO whisper_likes (whisper_id, user_id)
        VALUES (p_whisper_id, v_me)
        ON CONFLICT DO NOTHING;
        UPDATE whispers SET likes_count = likes_count + 1
         WHERE whisper_id = p_whisper_id;
        RETURN TRUE;
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.toggle_whisper_like(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_whisper_like(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
