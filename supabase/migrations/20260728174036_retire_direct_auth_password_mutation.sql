BEGIN;

-- GoTrue owns auth.users password lifecycle. Direct SQL hash mutation can
-- drift from the Auth service's current contract, so password resets now use
-- the server-only Auth Admin API.
REVOKE ALL ON FUNCTION public.admin_reset_user_password(UUID, TEXT, TEXT)
FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.admin_reset_user_password(UUID, TEXT, TEXT) IS
  'Deprecated: use the server-only Supabase Auth Admin updateUserById API.';

COMMIT;
