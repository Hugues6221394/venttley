-- The Keeper agreement: ticked by a person, recorded by the server.
--
-- Creating a Tribe hands somebody authority over a space that 13–17 year olds
-- use. Until now the only thing standing there was an age check the person
-- never saw — for an adult it passes silently, so nothing was ever shown,
-- agreed to, or written down. There was no answer to "when did this keeper
-- accept responsibility for this space, and for what".
--
-- WHY THIS IS A TABLE AND NOT A FLAG IN p_settings
--
-- p_settings already reaches this function and would have been the shortest
-- path. It is the wrong one: settings are mutable by every later edit, so a
-- consent stored there can be rewritten or dropped by an unrelated change to
-- an unrelated preference. A record of what a person agreed to, and when, has
-- to be something no later write touches.
--
-- Modelled on tribe_rule_acknowledgements from 20260831090000, which solved
-- the same problem for members reading rules: its own table, RLS on with no
-- policy (deny-all), reachable only through SECURITY DEFINER functions, so a
-- client can neither forge somebody else's consent nor edit its own history.
--
-- WHY THE SERVER REQUIRES IT RATHER THAN TRUSTING THE CHECKBOX
--
-- A consent that can be skipped is not a consent, it is decoration. The
-- checkbox on step 3 is how a person gives it; this is what makes the record
-- true. p_keeper_attested defaults to FALSE, so anything that does not pass it
-- explicitly is refused with a named error rather than quietly creating an
-- unattested Tribe.
--
-- The version number is here so the question "which wording did they agree
-- to?" stays answerable after the wording changes. Bump
-- KEEPER_ATTESTATION_VERSION in the client when the text changes materially;
-- old rows keep pointing at the text they were shown.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tribe_keeper_attestations (
  tribe_id    UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  -- Which wording was on screen when they ticked it.
  version     INT  NOT NULL CHECK (version > 0),
  -- What the server independently believed about their age at that moment.
  -- Stored alongside rather than inferred later: birth_year and birth_month
  -- can change (birth_month is write-once, but a year can be corrected), and
  -- this needs to say what was true when the Tribe was created.
  age_status  TEXT NOT NULL,
  attested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Per keeper, not per tribe: keepership can transfer, and a new keeper
  -- accepting responsibility is a new agreement, not an overwrite of the
  -- previous keeper's.
  PRIMARY KEY (tribe_id, user_id)
);

COMMENT ON TABLE public.tribe_keeper_attestations IS
  'Record of a keeper confirming their age and accepting responsibility for a Tribe. Written only by create_managed_tribe_idempotent; never client-writable.';

-- Deny-all, exactly as tribe_rule_acknowledgements does it. No policy is
-- created on purpose: every legitimate read and write goes through a
-- SECURITY DEFINER function, so there is no path by which a client could
-- write an attestation for another account or amend one after the fact.
ALTER TABLE public.tribe_keeper_attestations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tribe_keeper_attestations
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Creation now requires the agreement.
-- ---------------------------------------------------------------------------
-- DROP then CREATE, not CREATE OR REPLACE: adding a parameter changes the
-- signature, so a replace would leave TWO overloads in place and PostgREST
-- would have to guess which one an RPC call meant. Dropping means the grant
-- goes with it, hence the re-GRANT at the bottom.
DROP FUNCTION IF EXISTS public.create_managed_tribe_idempotent(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB
);

CREATE OR REPLACE FUNCTION public.create_managed_tribe_idempotent(
  p_mutation_id UUID,
  p_name TEXT,
  p_category TEXT,
  p_description TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT 'public',
  p_tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_welcome_message TEXT DEFAULT NULL,
  p_settings JSONB DEFAULT '{}'::JSONB,
  p_rules JSONB DEFAULT '[]'::JSONB,
  -- FALSE by default so that omitting it is a refusal, never an assumption.
  p_keeper_attested BOOLEAN DEFAULT FALSE,
  p_attestation_version INT DEFAULT 1
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me         UUID := (SELECT auth.uid());
  v_existing   UUID;
  v_tribe      UUID;
  v_age_status TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_mutation_id IS NULL THEN RAISE EXCEPTION 'mutation_id_required'; END IF;

  -- Checked before the advisory lock is taken: there is no point serialising
  -- callers on a mutation that is going to be refused anyway.
  IF p_keeper_attested IS NOT TRUE THEN
    RAISE EXCEPTION 'keeper_attestation_required'
      USING HINT = 'Confirm the Keeper agreement before creating a Tribe.';
  END IF;

  IF p_attestation_version IS NULL OR p_attestation_version < 1 THEN
    RAISE EXCEPTION 'keeper_attestation_version_invalid';
  END IF;

  -- Takes the advisory lock for this (user, mutation) and returns the id of
  -- the Tribe this key already produced, if any. Two taps that arrive together
  -- serialise here: the second waits, then finds the first one's receipt.
  v_existing := private.existing_client_mutation(v_me, p_mutation_id, 'tribe');
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_tribe := public.create_managed_tribe(
    p_name,
    p_category,
    p_description,
    p_visibility,
    p_tags,
    p_welcome_message,
    p_settings,
    p_rules
  );

  -- Read after creation rather than before, so it cannot disagree with the
  -- decision that was actually made: create_managed_tribe raises adults_only
  -- or age_verification_required itself, so reaching this line means the
  -- server settled the age question in the caller's favour.
  v_age_status := private.tribe_creation_age_status(v_me);

  INSERT INTO public.tribe_keeper_attestations (
    tribe_id, user_id, version, age_status
  )
  VALUES (v_tribe, v_me, p_attestation_version, v_age_status)
  -- A retry that lands on the same Tribe must not fail on the primary key.
  -- The first agreement stands; a retry is the same act, not a new one.
  ON CONFLICT (tribe_id, user_id) DO NOTHING;

  PERFORM private.complete_client_mutation(
    v_me, p_mutation_id, 'tribe', v_tribe
  );
  RETURN v_tribe;
END $$;

REVOKE ALL ON FUNCTION public.create_managed_tribe_idempotent(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB, BOOLEAN, INT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_managed_tribe_idempotent(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB, BOOLEAN, INT
) TO authenticated;

-- ---------------------------------------------------------------------------
-- Reading your own agreement back.
-- ---------------------------------------------------------------------------
-- Without this the record exists and nobody can see it, including the person
-- who gave it. A keeper should be able to check what they agreed to and when.
-- Own rows only; the table stays deny-all.
CREATE OR REPLACE FUNCTION public.my_keeper_attestation(p_tribe_id UUID)
RETURNS TABLE (version INT, age_status TEXT, attested_at TIMESTAMPTZ)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT a.version, a.age_status, a.attested_at
    FROM public.tribe_keeper_attestations a
   WHERE a.tribe_id = p_tribe_id
     AND a.user_id = (SELECT auth.uid());
$$;

REVOKE ALL ON FUNCTION public.my_keeper_attestation(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_keeper_attestation(UUID) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20261001090000', 'keeper_attestation_at_creation'
);

NOTIFY pgrst, 'reload schema';
