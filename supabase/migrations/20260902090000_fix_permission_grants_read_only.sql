-- tribe_permission_grants could never run through the API.
--
-- It is declared STABLE, and PostgREST executes STABLE functions inside a
-- READ ONLY transaction. It then called require_tribe_owner, which takes a row
-- lock — SELECT ... FROM tribes ... FOR UPDATE — and a row lock is not
-- something a read-only transaction may do. Every call failed with 25006
-- before it read a single grant, so the Helpers screen showed an error the
-- moment it opened.
--
-- The lock is right where it lives. require_tribe_owner exists to guard writes
-- that go on to mutate the tribe row, and taking the lock as part of the check
-- is what stops two concurrent edits interleaving. It is simply the wrong
-- helper for a function that only reads.
--
-- So this one performs the same ownership check without the lock. It stays
-- STABLE, because it is a read, and a read that silently upgraded itself to
-- taking locks on the tribe row would serialise the Helpers screen against
-- every other administrative write.
--
-- Everything else added in 20260901090000 was already correct here:
-- require_tribe_permission does not lock, and set_tribe_member_permissions is
-- VOLATILE and does mutate, so its use of require_tribe_owner is right.

BEGIN;

CREATE OR REPLACE FUNCTION public.tribe_permission_grants(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_owner UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT t.keeper_id INTO v_owner
    FROM public.tribes t WHERE t.tribe_id = p_tribe_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'tribe_not_found'; END IF;
  IF v_owner IS DISTINCT FROM v_me THEN RAISE EXCEPTION 'not_tribe_owner'; END IF;

  RETURN jsonb_build_object(
    'catalog', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'key', p.permission_key,
               'label', p.label,
               'description', p.description
             ) ORDER BY p.sort_order)
        FROM public.tribe_permissions p WHERE p.is_grantable
    ), '[]'::JSONB),
    'members', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'user_id', tm.user_id,
               'pseudonym', u.anonymous_pseudonym,
               'avatar_seed', u.avatar_seed,
               'role', tm.role,
               'permissions', to_jsonb(
                 public.tribe_member_permissions(p_tribe_id, tm.user_id))
             ) ORDER BY u.anonymous_pseudonym)
        FROM public.tribe_members tm
        JOIN public.users u ON u.user_id = tm.user_id
       WHERE tm.tribe_id = p_tribe_id
         AND tm.role <> 'keeper'
         AND (tm.role = 'mod' OR array_length(tm.permissions, 1) > 0)
    ), '[]'::JSONB)
  );
END $$;

REVOKE ALL ON FUNCTION public.tribe_permission_grants(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tribe_permission_grants(UUID) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260902090000', 'fix_permission_grants_read_only'
);

NOTIFY pgrst, 'reload schema';
