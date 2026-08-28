-- Enforce the age floor and the minor safety tier on the server.
--
-- Both were documented as shipped ("a DOB picker blocks under-13s outright and
-- places 13-17 users into the restricted_minor safety tier") but neither was
-- enforced anywhere the client could not reach:
--
--   * handle_new_auth_user() read BOTH birth_year and safety_tier out of
--     raw_user_meta_data, which is client-supplied at signUp. A caller using
--     the shipped anon key could omit birth_year entirely, or simply declare
--     safety_tier = 'standard'. The tier was untrusted input treated as fact.
--
--   * safety_tier was never read to make a decision. Its only server-side use
--     was excluding minors from friend-suggestion queries, and the client's
--     `isRestrictedMinor` getter had zero call sites.
--
-- Age precision: users.birth_year stores a year only (deliberately — it is
-- less identifying than a full date). Year arithmetic therefore cannot tell a
-- 12-year-old turning 13 this year from a 13-year-old. We take the permissive
-- bound, matching what the column can express, because the client already
-- gates on the full date it collected. The point of this migration is to stop
-- the gross bypass (absent or obviously false birth_year), not to re-derive a
-- birthday the server intentionally never stored.

-- ---------------------------------------------------------------------------
-- 1. Server-derived tier, and a hard floor on new accounts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    meta      JSONB := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
    pseudonym TEXT  := COALESCE(meta->>'pseudonym',   'SilentSoul');
    avatar    TEXT  := COALESCE(meta->>'avatar_seed', 'rose-orb-0001');
    byear     INT   := NULLIF(meta->>'birth_year', '')::INT;
    v_age     INT;
    v_safety  TEXT;
BEGIN
    -- A birth year outside plausible human range is treated as absent rather
    -- than trusted, so a caller cannot buy 'standard' with birth_year = 1900.
    IF byear IS NOT NULL
       AND (byear < 1900 OR byear > EXTRACT(YEAR FROM now())::INT) THEN
        byear := NULL;
    END IF;

    IF byear IS NOT NULL THEN
        v_age := EXTRACT(YEAR FROM now())::INT - byear;

        -- The product's minimum-age floor. Raising here aborts the auth.users
        -- insert, so the signUp call fails and no account exists.
        IF v_age < 13 THEN
            RAISE EXCEPTION 'age_below_minimum'
                USING HINT = 'Venttly is not available under 13.';
        END IF;

        -- Derived, never read from client metadata.
        v_safety := CASE WHEN v_age <= 17 THEN 'restricted_minor'
                         ELSE 'standard' END;
    ELSE
        -- Unknown age fails CLOSED. Paths that create an auth user without a
        -- DOB (Google sign-in, phone OTP) land in the restricted tier instead
        -- of silently receiving adult privileges. The client can lift this by
        -- collecting a DOB and calling set_my_birth_year below.
        v_safety := 'restricted_minor';
    END IF;

    INSERT INTO public.users(
        user_id, anonymous_pseudonym, avatar_seed, current_mood,
        user_role, is_verified, account_status, safety_tier, birth_year,
        recovery_key_hash
    )
    VALUES (
        NEW.id, pseudonym, avatar, 'healing',
        'normal', false, 'active', v_safety::safety_tier_type, byear,
        'auth-managed'
    )
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Defence in depth: the invariant holds for any write path, not just the
--    trigger. Legacy rows with a NULL birth_year are tolerated so this can be
--    applied to an existing database without a backfill; NOT VALID skips the
--    retroactive scan for the same reason.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_birth_year_age_floor;

ALTER TABLE public.users
    ADD CONSTRAINT users_birth_year_age_floor
    CHECK (
        birth_year IS NULL
        OR birth_year BETWEEN 1900 AND 2100
    ) NOT VALID;

-- ---------------------------------------------------------------------------
-- 3. Let a client supply a DOB after the fact (OAuth / phone signup) and have
--    the server — not the client — decide what tier that earns. Writes only
--    when birth_year is still unset, so this cannot be used to escape the
--    restricted tier by re-declaring an age later.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_my_birth_year(p_birth_year INT)
RETURNS TABLE (safety_tier TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_me    UUID := auth.uid();
    v_age   INT;
    v_tier  TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_birth_year IS NULL
       OR p_birth_year < 1900
       OR p_birth_year > EXTRACT(YEAR FROM now())::INT THEN
        RAISE EXCEPTION 'invalid_birth_year';
    END IF;

    v_age := EXTRACT(YEAR FROM now())::INT - p_birth_year;
    IF v_age < 13 THEN
        RAISE EXCEPTION 'age_below_minimum'
            USING HINT = 'Venttly is not available under 13.';
    END IF;

    v_tier := CASE WHEN v_age <= 17 THEN 'restricted_minor' ELSE 'standard' END;

    UPDATE public.users AS u
       SET birth_year  = p_birth_year,
           safety_tier = v_tier::safety_tier_type,
           updated_at  = now()
     WHERE u.user_id = v_me
       AND u.birth_year IS NULL;

    SELECT u.safety_tier::TEXT INTO safety_tier
      FROM public.users AS u
     WHERE u.user_id = v_me;
    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_birth_year(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_my_birth_year(INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
