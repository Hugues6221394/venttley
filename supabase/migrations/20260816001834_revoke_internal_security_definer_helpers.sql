BEGIN;

-- These helpers are implementation details invoked by trusted trigger/RPC
-- functions. They accept actor, recipient, and target identifiers directly,
-- so exposing them through PostgREST lets a hostile signed-in client forge
-- notifications or probe another account's writer state.
--
-- Revoking direct execution does not affect calls made by their owning
-- SECURITY DEFINER functions. Keep service_role access for operational use.
REVOKE ALL ON FUNCTION public._notify(
  UUID, UUID, TEXT, TEXT, UUID, TEXT, TEXT, INTERVAL, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._notify(
  UUID, UUID, TEXT, TEXT, UUID, TEXT, TEXT, INTERVAL, JSONB
) TO service_role;

REVOKE ALL ON FUNCTION public._notify_mentions(
  UUID, TEXT, TEXT, UUID, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._notify_mentions(
  UUID, TEXT, TEXT, UUID, JSONB
) TO service_role;

REVOKE ALL ON FUNCTION public._writer_state(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._writer_state(UUID)
  TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
