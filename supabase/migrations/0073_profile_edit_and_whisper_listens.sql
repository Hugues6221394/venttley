-- ============================================================================
-- 0073: Editable public profiles + real whisper listen capture
--
--  1. Add public profile fields: bio + pronouns (users.avatar/photo/city already
--     exist). Expose them through the column-level SELECT grant (see 0021).
--  2. update_my_profile() — one RPC to change username (anonymous_pseudonym),
--     bio, pronouns, profile photo, and home city, with validation + a
--     case-insensitive uniqueness check on the username.
--  3. whisper_listens — capture EVERY distinct listener (whether or not they
--     liked). record_whisper_listen() upserts a listener row and refreshes the
--     denormalised whispers.plays_count so the public count is always real.
--  4. De-seed: the 0070 demo whispers were inserted with fabricated plays_count
--     (120 + gs*517 % 2600 → the uniform "2.7k"). Reset them to 0 so every
--     number the app shows reflects actual listens.
-- ============================================================================

-- 1) Public profile fields ---------------------------------------------------
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS bio      VARCHAR(160),
    ADD COLUMN IF NOT EXISTS pronouns VARCHAR(30);

-- Readable by any client (same policy as the other public display columns).
-- profile_photo_url is included defensively in case an earlier grant missed it;
-- re-granting an already-granted column is a no-op.
GRANT SELECT (bio, pronouns, profile_photo_url) ON public.users TO authenticated, anon;

-- 2) update_my_profile -------------------------------------------------------
-- All args optional; NULL means "leave unchanged". Username is validated and
-- must be unique case-insensitively (ignoring the caller's own current name).
CREATE OR REPLACE FUNCTION public.update_my_profile(
    p_pseudonym          TEXT DEFAULT NULL,
    p_bio                TEXT DEFAULT NULL,
    p_pronouns           TEXT DEFAULT NULL,
    p_profile_photo_url  TEXT DEFAULT NULL,
    p_home_city          TEXT DEFAULT NULL,
    p_clear_photo        BOOLEAN DEFAULT FALSE,
    p_clear_bio          BOOLEAN DEFAULT FALSE,
    p_clear_pronouns     BOOLEAN DEFAULT FALSE
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me   UUID := auth.uid();
    v_name TEXT := NULLIF(btrim(p_pseudonym), '');
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    IF v_name IS NOT NULL THEN
        IF length(v_name) < 3 OR length(v_name) > 24 THEN
            RAISE EXCEPTION 'Username must be 3–24 characters.';
        END IF;
        IF v_name !~ '^[A-Za-z0-9_]+$' THEN
            RAISE EXCEPTION 'Username can only use letters, numbers and underscores.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM users
             WHERE lower(anonymous_pseudonym) = lower(v_name)
               AND user_id <> v_me
        ) THEN
            RAISE EXCEPTION 'That username is taken.';
        END IF;
    END IF;

    UPDATE users SET
        anonymous_pseudonym = COALESCE(v_name, anonymous_pseudonym),
        bio                 = CASE WHEN p_clear_bio      THEN NULL
                                   ELSE COALESCE(NULLIF(btrim(p_bio), ''), bio) END,
        pronouns            = CASE WHEN p_clear_pronouns THEN NULL
                                   ELSE COALESCE(NULLIF(btrim(p_pronouns), ''), pronouns) END,
        profile_photo_url   = CASE WHEN p_clear_photo    THEN NULL
                                   ELSE COALESCE(p_profile_photo_url, profile_photo_url) END,
        home_city           = COALESCE(NULLIF(btrim(p_home_city), ''), home_city),
        updated_at          = now()
    WHERE user_id = v_me;
END $$;

REVOKE ALL ON FUNCTION public.update_my_profile(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_my_profile(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN) TO authenticated;

-- 3) Whisper listens ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.whisper_listens (
    whisper_id   UUID NOT NULL REFERENCES public.whispers(whisper_id) ON DELETE CASCADE,
    listener_id  UUID NOT NULL REFERENCES public.users(user_id)       ON DELETE CASCADE,
    first_listened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    listen_count INT  NOT NULL DEFAULT 1,
    last_listened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (whisper_id, listener_id)
);

CREATE INDEX IF NOT EXISTS idx_whisper_listens_whisper ON public.whisper_listens(whisper_id);

ALTER TABLE public.whisper_listens ENABLE ROW LEVEL SECURITY;
-- Totals are public (they drive the on-screen listen count); writes go through
-- the SECURITY DEFINER RPC only.
DROP POLICY IF EXISTS "whisper listens readable" ON public.whisper_listens;
CREATE POLICY "whisper listens readable" ON public.whisper_listens
    FOR SELECT USING (true);

-- Records that auth.uid() listened to a whisper. First listen from a given
-- user bumps the public plays_count (= distinct listeners); repeat listens
-- update their own counters but do not double-count the public total.
CREATE OR REPLACE FUNCTION public.record_whisper_listen(p_whisper_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me    UUID := auth.uid();
    v_fresh BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF NOT EXISTS (SELECT 1 FROM whispers
                    WHERE whisper_id = p_whisper_id AND deleted_at IS NULL) THEN
        RETURN;
    END IF;

    INSERT INTO whisper_listens (whisper_id, listener_id)
    VALUES (p_whisper_id, v_me)
    ON CONFLICT (whisper_id, listener_id) DO UPDATE
        SET listen_count     = whisper_listens.listen_count + 1,
            last_listened_at = now()
    RETURNING (xmax = 0) INTO v_fresh;  -- true when the row was freshly inserted

    IF v_fresh THEN
        UPDATE whispers
           SET plays_count = plays_count + 1
         WHERE whisper_id = p_whisper_id;
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.record_whisper_listen(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_whisper_listen(UUID) TO authenticated;

-- 4) De-seed fabricated play counts -----------------------------------------
-- The 0070 demo whispers all share the id prefix 'f0000000-'. Reset their
-- fake plays to 0; from now on the count only grows from real listens.
UPDATE public.whispers
   SET plays_count = 0
 WHERE whisper_id::text LIKE 'f0000000-%';

NOTIFY pgrst, 'reload schema';
