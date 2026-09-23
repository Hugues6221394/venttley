-- The second person to sign in with Google could not create an account.
--
-- handle_new_auth_user builds the profile row for every new auth user, and it
-- took the public handle from raw_user_meta_data->>'pseudonym'. The app's own
-- signup puts one there. A provider sign-in does not: Google sends a name, an
-- email and a picture, and nothing this app would use as a handle.
--
-- So the fallback fired — the literal string 'SilentSoul'. The first Google
-- user got it. The second hit users_pseudonym_lower_unique, and since the
-- INSERT's ON CONFLICT clause only covers user_id, that violation propagated
-- out of the trigger and failed the signup itself. GoTrue would have answered
-- "Database error saving new user" and the person would have been told their
-- account could not be created, with nothing to explain why.
--
-- Found before anybody hit it, by reading what the trigger does with metadata
-- a provider does not send.

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
    -- Deliberately NOT cast here. See below.
    byear     INT;
    bmonth    INT;
    v_age     INT;
    v_safety  TEXT;
BEGIN
    -- These were DECLARE-time casts: byear INT := NULLIF(meta->>'birth_year','')::INT.
    -- A DECLARE initialiser cannot be guarded, and this function runs inside
    -- the INSERT on auth.users, so any cast failure aborts the whole signup:
    --
    --   ERROR: invalid input syntax for type integer: "March"
    --   CONTEXT: PL/pgSQL function handle_new_auth_user() line 7
    --            during statement block local variable initialization
    --
    -- Reproduced on a scratch cluster before shipping this. Metadata is
    -- client-supplied JSON — a stale build, a web client, or anything sending
    -- a month by name rather than by number would not get a validation
    -- message, it would get a failed account creation with a raw Postgres cast
    -- error. Nobody should lose a signup over a malformed optional field.
    --
    -- So the casts move inside guarded blocks and unparseable input becomes
    -- NULL. NULL is the safe answer in both cases: a missing year already
    -- fails closed to restricted_minor below, and the router already redirects
    -- an account with no birth_year to /onboarding/age to supply one — so the
    -- account self-heals instead of never existing.
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

    -- A birth year outside plausible human range is treated as absent rather
    -- than trusted, so a caller cannot buy 'standard' with birth_year = 1900.
    IF byear IS NOT NULL
       AND (byear < 1900 OR byear > EXTRACT(YEAR FROM now())::INT) THEN
        byear := NULL;
    END IF;

    -- Same treatment for the month: out of range means absent, not believed.
    -- A NULL here simply leaves the account where it was before this migration
    -- — asked for the month at the age gate — rather than failing signup.
    IF bmonth IS NOT NULL AND (bmonth < 1 OR bmonth > 12) THEN
        bmonth := NULL;
    END IF;

    IF byear IS NOT NULL THEN
        v_age := EXTRACT(YEAR FROM now())::INT - byear;

        -- The product's minimum-age floor. Raising here aborts the auth.users
        -- insert, so the signUp call fails and no account exists.
        IF v_age < 13 THEN
            RAISE EXCEPTION 'age_below_minimum'
                USING HINT = 'Venttly is not available under 13.';
        END IF;

        -- Derived, never read from client metadata. Deliberately still keyed
        -- on the year only: the month must not be able to move an account
        -- between tiers.
        v_safety := CASE WHEN v_age <= 17 THEN 'restricted_minor'
                         ELSE 'standard' END;
    ELSE
        -- Unknown age fails CLOSED. Paths that create an auth user without a
        -- DOB (Google sign-in, phone OTP) land in the restricted tier instead
        -- of silently receiving adult privileges. The client can lift this by
        -- collecting a DOB and calling set_my_birth_year below.
        v_safety := 'restricted_minor';
    END IF;

    -- A provider sign-in carries no pseudonym.
    --
    -- This used to fall back to the literal 'SilentSoul'. The first Google
    -- user would get it; the second would hit users_pseudonym_lower_unique,
    -- and because the ON CONFLICT below only covers user_id, that violation
    -- propagates out of the trigger and fails the signup itself. Everybody
    -- after the first person to use Google would have been told their account
    -- could not be created, with nothing on screen to say why.
    --
    -- Random rather than derived from the Google profile. The name and email
    -- are right there in the metadata, and using either would turn a
    -- pseudonymous account into a named one at the moment of creation. The
    -- handle is public and this app is pseudonymous by default.
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
    RETURN NEW;
END;
$function$;

SELECT public.record_migration(
  '20261042090000', 'provider_signups_get_a_unique_handle'
);

NOTIFY pgrst, 'reload schema';
