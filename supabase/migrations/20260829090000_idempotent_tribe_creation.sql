-- Make Tribe creation idempotent.
--
-- create_managed_tribe had no mutation id, so every call created a Tribe. A
-- double tap on a slow connection, or a retry after the response was lost in
-- flight, produced two communities with the same name and the same owner — and
-- unlike a duplicated post, a duplicated Tribe is not something a user can
-- quietly delete: it has members, spaces, rules and an audit trail, and the
-- owner has to work out which one people actually joined.
--
-- Now that creation is open to everyone rather than gated behind plug
-- approval, the number of people who can hit that went from a handful to
-- everyone, which is what makes this worth fixing before the flow gets
-- friendlier and busier.
--
-- Uses the mechanism already here rather than inventing a second one.
-- 20260714182652 built private.client_mutation_receipts with an advisory lock
-- keyed on (user, mutation) so concurrent duplicates serialise instead of
-- racing — posts, comments, DMs and tribe messages all go through it. Tribes
-- were simply never added to its operation_kind list.

BEGIN;

-- 'tribe' joins the kinds the receipts table accepts.
ALTER TABLE private.client_mutation_receipts
  DROP CONSTRAINT IF EXISTS client_mutation_receipts_operation_kind_check;
ALTER TABLE private.client_mutation_receipts
  ADD CONSTRAINT client_mutation_receipts_operation_kind_check
    CHECK (operation_kind IN (
      'post',
      'comment',
      'whisper_comment',
      'dm',
      'tribe_message',
      'tribe'
    ));

-- Wraps create_managed_tribe rather than editing it.
--
-- Keeping the original untouched means the age floor, the rate limit, the
-- validation and the single-transaction insert of tribe + owner membership +
-- rules stay exactly as verified, and this adds one thing: the same mutation
-- id twice returns the first Tribe instead of building a second.
--
-- p_mutation_id is required. Making it optional would mean a client that
-- forgets it silently loses the protection, which is the failure this exists
-- to prevent.
CREATE OR REPLACE FUNCTION public.create_managed_tribe_idempotent(
  p_mutation_id UUID,
  p_name TEXT,
  p_category TEXT,
  p_description TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT 'public',
  p_tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_welcome_message TEXT DEFAULT NULL,
  p_settings JSONB DEFAULT '{}'::JSONB,
  p_rules JSONB DEFAULT '[]'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_existing UUID;
  v_tribe    UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_mutation_id IS NULL THEN RAISE EXCEPTION 'mutation_id_required'; END IF;

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

  PERFORM private.complete_client_mutation(
    v_me, p_mutation_id, 'tribe', v_tribe
  );
  RETURN v_tribe;
END $$;

REVOKE ALL ON FUNCTION public.create_managed_tribe_idempotent(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_managed_tribe_idempotent(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB
) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260829090000', 'idempotent_tribe_creation'
);

NOTIFY pgrst, 'reload schema';
