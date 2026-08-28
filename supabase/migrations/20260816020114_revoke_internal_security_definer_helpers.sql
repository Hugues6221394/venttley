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

-- Historical Supabase defaults also granted API roles EXECUTE on newly
-- created functions. These primitives are invoked only by trusted workers,
-- cron, or other SECURITY DEFINER functions. Direct client access would let
-- an attacker run maintenance jobs, forge counters, or reset their own
-- rate-limit window with attacker-selected parameters.
REVOKE ALL ON FUNCTION public.claim_rate_limit(TEXT, INT, INT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bump_moderation_hit(TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pick_spaces_for_summary(INT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.publish_scheduled_prompts()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purge_due_accounts()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purge_due_tribes()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purge_stale_moderation_verdicts()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_rate_limit(TEXT, INT, INT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.bump_moderation_hit(TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.pick_spaces_for_summary(INT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.publish_scheduled_prompts()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_due_accounts()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_due_tribes()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_stale_moderation_verdicts()
  TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
