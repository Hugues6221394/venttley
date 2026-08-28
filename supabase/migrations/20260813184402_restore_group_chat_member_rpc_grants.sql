-- Repair the complete privilege chain used by PostgREST when an authenticated
-- client calls public.group_chat_members(uuid).
--
-- public.group_chat_members intentionally remains SECURITY INVOKER: table
-- grants and RLS continue to apply to the caller. Its membership predicate is
-- private.is_chat_room_member, a narrowly scoped SECURITY DEFINER helper that
-- must bypass chat_room_members RLS to avoid recursive policy evaluation. The
-- helper derives identity exclusively from auth.uid() and returns only a
-- boolean, so granting authenticated callers EXECUTE does not disclose the
-- membership table.

-- PostgreSQL checks schema USAGE before function EXECUTE. Reassert both grants
-- explicitly because either one drifting produces API error 42501/HTTP 403.
GRANT USAGE ON SCHEMA private TO authenticated;

ALTER FUNCTION private.is_chat_room_member(UUID) SECURITY DEFINER;
ALTER FUNCTION private.is_chat_room_member(UUID) SET search_path TO '';
REVOKE ALL ON FUNCTION private.is_chat_room_member(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_chat_room_member(UUID)
  TO authenticated;

-- Do not solve the permission error by elevating the public RPC. Keeping it
-- invoker-security preserves column privileges and RLS on both source tables.
ALTER FUNCTION public.group_chat_members(UUID) SECURITY INVOKER;
ALTER FUNCTION public.group_chat_members(UUID) SET search_path TO '';
REVOKE ALL ON FUNCTION public.group_chat_members(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.group_chat_members(UUID)
  TO authenticated;

-- The invoker needs only the read surface consumed by the RPC. RLS on
-- chat_room_members still reduces rows to rooms accepted by the helper.
GRANT SELECT ON public.chat_room_members TO authenticated;

NOTIFY pgrst, 'reload schema';
