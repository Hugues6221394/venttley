-- Record the birth month at signup, so the age gate stops asking for it later.
--
-- Creating a Tribe calls private.tribe_creation_age_status(), which needs the
-- month in exactly one situation: when year arithmetic makes somebody 18 this
-- calendar year and it cannot tell whether the birthday has happened yet. With
-- no month on the row it returns 'month_required' and create_managed_tribe
-- raises 'age_verification_required', which the app renders as:
--
--     "We need one more detail about your age first."
--
-- and that is where it ended. AgeCompletionScreen exists, is routed at
-- /onboarding/age, calls set_my_birth_month, and NOTHING in the app navigates
-- to it — grep for the path outside the router returns nothing. So the server
-- asked for a detail the app had no way to supply: a dead end for anyone who
-- turns 18 this year.
--
-- The information was never missing. Signup already collects a full date of
-- birth — the picker asks for a day, a month and a year — and then sends only
-- the year:
--
--     data: { 'pseudonym': …, 'avatar_seed': …, 'birth_year': …, 'safety_tier': … }
--
-- and this trigger only reads birth_year. The month was discarded at the door
-- and then demanded back months later.
--
-- WHY THIS IS SAFE TO TAKE FROM METADATA
--
-- Nothing is trusted that was not already trusted. birth_year comes from the
-- same client metadata and is already sanity-checked here; the month gets the
-- same treatment, and anything outside 1..12 is stored as NULL rather than
-- believed. It cannot be used to gain anything either: the month only ever
-- decides whether an exactly-18 account has had its birthday, and the
-- safety_tier — the signal that actually gates minors — is still derived from
-- the year alone, exactly as before.
--
-- set_my_birth_month stays as the path for existing accounts, and it remains
-- write-once (it raises birth_month_already_set on a conflicting change), so
-- this does not open a way to launder an age.

BEGIN;

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
$$;

COMMIT;

-- Ledger backfill for two migrations that shipped without recording themselves.
--
-- 20260908120000_personal_feed_keyset and 20260908130000_chat_reactions_room_scope
-- were applied to the live database but never called record_migration, so they
-- were invisible to the manifest check — the same blind spot that made it
-- impossible to tell whether 0067 had ever run, which cost two wrong diagnoses
-- of the Tribe image upload failure. Both files now end with their own
-- record_migration call, which covers any fresh database; this covers the one
-- that already ran them.
--
-- Safe to state as fact rather than guess: these two are strictly older than
-- migrations this database has demonstrably applied since, and migrations are
-- applied in version order. record_migration is ON CONFLICT DO NOTHING, so a
-- database that recorded them properly is unaffected.
SELECT public.record_migration('20260908120000', 'personal_feed_keyset');
SELECT public.record_migration('20260908130000', 'chat_reactions_room_scope');

SELECT public.record_migration(
  '20260930090000', 'record_birth_month_at_signup'
);

NOTIFY pgrst, 'reload schema';
