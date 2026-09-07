-- Account deletion is broken, and an append-only ledger is the reason.
--
-- 20261010090000 fixed this for moderation_case_events. The same defect exists
-- in two more places, and the worst of them is not about staff at all:
--
--   audit_log.actor_id                  FK -> users, ON DELETE SET NULL
--   security_events.device_row_id       FK -> user_devices, ON DELETE SET NULL
--   security_events.device_session_id   FK -> device_sessions, ON DELETE SET NULL
--
-- Each of those tables has a BEFORE UPDATE/DELETE trigger that raises. So a
-- DELETE fires a cascade UPDATE the table's own trigger refuses, and the
-- delete fails.
--
-- Measured, not inferred:
--
--   * admin_delete_user() fails with "security_events is append-only" for any
--     member who has ever signed in on a device, because logging in writes a
--     security_events row with kind='login' and a device_row_id. That is the
--     console's Delete user button — super_admin only, AAL2-gated, type DELETE
--     to confirm — and it cannot delete a real account. A deletion request
--     cannot be fulfilled through the console at all.
--   * Separately, any staff account that has taken one audited action cannot be
--     deleted, via audit_log.actor_id. That blocks staff offboarding (P2).
--
-- The fix is to drop the foreign keys, not to weaken the immutability. Two
-- reasons, and the second is the stronger one:
--
--   1. History a cascade can rewrite is not append-only. The trigger is the
--      point of these tables; the FK is what fights it.
--   2. For audit_log the cascade is actively wrong. ON DELETE SET NULL would
--      erase which staff member took a privileged action as soon as their
--      account is removed — the trigger is currently the only thing preventing
--      that, by refusing the whole delete. Keeping the raw UUID means the
--      ledger still answers "who did this" after the account is gone, which is
--      the entire purpose of an audit trail. audit_log already denormalises
--      actor_pseudonym and actor_role for exactly this reason.
--
-- The same applies to the device columns: a security event should still say
-- which device a login came from after that device row is deleted.
--
-- Immutability is unchanged. The guards still refuse every direct UPDATE and
-- DELETE; there is a test asserting that, so this cannot be mistaken for a
-- loosening of the ledgers.

ALTER TABLE public.audit_log
    DROP CONSTRAINT IF EXISTS audit_log_actor_id_fkey;

ALTER TABLE public.security_events
    DROP CONSTRAINT IF EXISTS security_events_device_row_id_fkey;

ALTER TABLE public.security_events
    DROP CONSTRAINT IF EXISTS security_events_device_session_id_fkey;

COMMENT ON COLUMN public.audit_log.actor_id IS
  'Who took the action. Deliberately not a foreign key: audit_log is append-only, so a cascade must never rewrite it, and the id is retained after the account is deleted — an audit trail that forgets its actor is not one.';

COMMENT ON COLUMN public.security_events.device_row_id IS
  'Deliberately not a foreign key: security_events is append-only, and the event should still name the device after that device row is removed.';

SELECT public.record_migration(
  '20261011090000', 'ledgers_stop_blocking_deletion'
);

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- The FKs above were not the whole story
-- =========================================================================
-- Dropping them did not make admin_delete_user work. The remaining blocker is
-- security_events_user_id_fkey, which is ON DELETE **CASCADE** — so deleting a
-- user fires a DELETE on security_events, and that table's guard refuses
-- DELETE as well as UPDATE. Measured after dropping the SET NULL FKs: still
-- "security_events is append-only".
--
-- This one is a genuine conflict rather than an oversight, so it needs a
-- decision rather than a constraint change. A security_events row is the
-- member's own personal data — device, country, risk signals. An account
-- deletion has to remove it. But the table is append-only precisely so that
-- nobody can quietly rewrite a login history.
--
-- Both are right. What is wrong is concluding from "append-only" that an
-- account can never be deleted: the guard exists to prevent tampering, not to
-- make erasure impossible. So account deletion gets an explicit, narrow,
-- transaction-local way through, and nothing else does.
--
-- Why the flag cannot be abused: it is worthless without DELETE privilege on
-- security_events, and neither `authenticated` nor `anon` has it (verified).
-- Only a SECURITY DEFINER function owned by postgres can delete these rows,
-- and the one that sets this flag is super_admin-gated and AAL2-gated. A
-- client can set the GUC all it likes and still delete nothing.
--
-- audit_log is deliberately NOT given the same escape hatch. It records what
-- *staff* did, not the member's own activity, and it has no foreign key on
-- target_id — so deleting a member already leaves the record of the decisions
-- taken about them intact, which is what a compliance trail is for.

CREATE OR REPLACE FUNCTION private.guard_security_events_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Set only by admin_delete_user, and only for the duration of that
  -- transaction. Erasing a member's own login history as part of deleting
  -- their account is the one sanctioned reason these rows may go.
  IF TG_OP = 'DELETE'
     AND current_setting('venttly.purging_account', TRUE) = 'on' THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'security_events is append-only'
    USING ERRCODE = 'P0001';
END;
$$;

REVOKE ALL ON FUNCTION private.guard_security_events_append_only()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_user(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can delete users';
    END IF;
    PERFORM private.require_aal2();
    IF p_target = auth.uid() THEN
        RAISE EXCEPTION 'you cannot delete your own account here';
    END IF;

    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    -- Audit first — the target rows are about to vanish. This row survives the
    -- deletion: audit_log has no FK to the target, and after the change above
    -- its actor_id is retained too.
    PERFORM admin_log('user.delete', 'user', p_target, v_label, v_before, NULL, p_reason, '{}'::jsonb);

    -- Transaction-local, so it cannot leak into any later statement on this
    -- connection.
    PERFORM set_config('venttly.purging_account', 'on', true);

    DELETE FROM auth.users   WHERE id = p_target;
    DELETE FROM public.users WHERE user_id = p_target;

    PERFORM set_config('venttly.purging_account', 'off', true);
END $$;

REVOKE ALL ON FUNCTION public.admin_delete_user(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
