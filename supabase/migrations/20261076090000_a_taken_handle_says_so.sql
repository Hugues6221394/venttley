-- A taken handle answered with the constraint that caught it.
--
-- Signing up with a handle somebody already has returned this, straight from
-- Postgres, through GoTrue, to the phone:
--
--   {"code":"23505",
--    "message":"duplicate key value violates unique constraint
--               \"users_pseudonym_lower_unique\"",
--    "detail":"Key (lower(anonymous_pseudonym::text))=(first_light)
--              already exists."}
--
-- Three things wrong with that. It is unreadable. It names an internal
-- constraint and a column, which is more than anyone outside needs to know
-- about the schema. And `detail` repeats the handle that was asked for, so a
-- stranger can confirm whether a specific handle exists by reading an error
-- -- the same thing the app asks username_available() for deliberately, but
-- here as a side effect nobody chose.
--
-- The age floor three lines above already shows the better shape: it raises a
-- bare identifier, `age_below_minimum`, and GoTrue passes it through intact.
-- So the insert is wrapped and the violation re-raised the same way, as
-- `pseudonym_taken`, which the client maps to a sentence. The identifier is
-- the contract; the wording lives in the app, where it can be changed without
-- a migration.
--
-- Everything else about handle_new_auth_user is carried over unchanged from
-- 20261042090000, including the guarded casts and the provider fallback.

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    meta      JSONB := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
    pseudonym TEXT  := NULLIF(btrim(COALESCE(meta->>'pseudonym', '')), '');
    avatar    TEXT  := COALESCE(meta->>'avatar_seed', 'rose-orb-0001');
    byear     INT;
    bmonth    INT;
    v_age     INT;
    v_safety  TEXT;
BEGIN
    -- Guarded rather than cast in DECLARE: a DECLARE initialiser cannot be
    -- wrapped, and this runs inside the INSERT on auth.users, so a bad cast
    -- aborts the whole signup. Unparseable means absent, and absent already
    -- fails closed below.
    BEGIN
        byear := NULLIF(meta->>'birth_year', '')::INT;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        byear := NULL;
    END;

    BEGIN
        bmonth := NULLIF(meta->>'birth_month', '')::INT;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        bmonth := NULL;
    END;

    IF byear IS NOT NULL
       AND (byear < 1900 OR byear > EXTRACT(YEAR FROM now())::INT) THEN
        byear := NULL;
    END IF;

    IF bmonth IS NOT NULL AND (bmonth < 1 OR bmonth > 12) THEN
        bmonth := NULL;
    END IF;

    IF byear IS NOT NULL THEN
        v_age := EXTRACT(YEAR FROM now())::INT - byear;

        IF v_age < 13 THEN
            RAISE EXCEPTION 'age_below_minimum'
                USING HINT = 'Venttly is not available under 13.';
        END IF;

        v_safety := CASE WHEN v_age <= 17 THEN 'restricted_minor'
                         ELSE 'standard' END;
    ELSE
        -- Unknown age fails CLOSED: provider sign-ins and phone OTP land in
        -- the restricted tier until a DOB is collected.
        v_safety := 'restricted_minor';
    END IF;

    -- A provider sign-in carries no pseudonym. Random rather than derived
    -- from the Google or Apple profile: the handle is public and this app is
    -- pseudonymous by default.
    IF pseudonym IS NULL THEN
        FOR i IN 1 .. 8 LOOP
            pseudonym := 'soul_' ||
                substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
            EXIT WHEN NOT EXISTS (
                SELECT 1 FROM public.users u
                 WHERE lower(u.anonymous_pseudonym) = lower(pseudonym)
            );
            pseudonym := NULL;
        END LOOP;
        IF pseudonym IS NULL THEN
            RAISE EXCEPTION 'could_not_allocate_pseudonym';
        END IF;
    END IF;

    BEGIN
        INSERT INTO public.users(
            user_id, anonymous_pseudonym, avatar_seed, current_mood,
            user_role, is_verified, account_status, safety_tier, birth_year,
            birth_month, recovery_key_hash
        )
        VALUES (
            NEW.id, pseudonym, avatar, 'healing',
            'normal', false, 'active', v_safety::safety_tier_type, byear,
            bmonth, 'auth-managed'
        )
        ON CONFLICT (user_id) DO NOTHING;
    EXCEPTION
        -- ON CONFLICT above covers user_id only, so a handle collision still
        -- raises here. Re-raised as an identifier the client can map, instead
        -- of letting Postgres describe its own constraint to a stranger.
        --
        -- Narrowed to the handle's own constraint by name: any other unique
        -- violation on this insert is something unforeseen, and must not be
        -- reported as a naming problem. It keeps its own error.
        WHEN unique_violation THEN
            IF SQLERRM LIKE '%users_pseudonym_lower_unique%' THEN
                RAISE EXCEPTION 'pseudonym_taken'
                    USING HINT = 'That handle is already in use.';
            END IF;
            RAISE;
    END;

    RETURN NEW;
END;
$function$;

SELECT public.record_migration(
  '20261076090000', 'a_taken_handle_says_so'
);

NOTIFY pgrst, 'reload schema';
