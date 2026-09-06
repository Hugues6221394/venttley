-- Replace direct service-role table mutations in the admin console's Server
-- Actions with narrowly scoped admin_* RPCs, matching the existing pattern:
-- is_staff() gate, existence/before-state check, mutation, admin_log(...) in
-- the same transaction. Every one of these previously used createAdminClient()
-- (the service-role client, which bypasses RLS entirely) to write directly to
-- a table from TypeScript, then called audit() as a *separate* statement
-- afterwards — so a logging failure never rolled back the mutation, and the
-- only authorization check was the Next.js layout/route gate, not the
-- database. See admin/README.md's P0 list.

-- =========================================================================
-- 1) Automod rules — create / toggle / delete
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_create_automod_rule(
    p_pattern    TEXT,
    p_match_type TEXT,
    p_category   TEXT,
    p_action     TEXT,
    p_note       TEXT DEFAULT NULL,
    p_reason     TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID; v_after JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    INSERT INTO automod_rules (pattern, match_type, category, action, note, created_by)
    VALUES (p_pattern, p_match_type, p_category, p_action, p_note, auth.uid())
    RETURNING rule_id INTO v_id;

    SELECT to_jsonb(r) INTO v_after FROM automod_rules r WHERE r.rule_id = v_id;

    PERFORM admin_log(
        'automod.create', 'automod_rule', v_id, p_pattern,
        NULL, v_after, p_reason, '{}'::jsonb
    );
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.admin_create_automod_rule(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_automod_rule(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_toggle_automod_rule(
    p_rule   UUID,
    p_active BOOLEAN,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT; v_before JSONB; v_after JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT pattern, to_jsonb(r) INTO v_label, v_before
      FROM automod_rules r WHERE r.rule_id = p_rule;
    IF v_label IS NULL THEN RAISE EXCEPTION 'automod rule not found'; END IF;

    UPDATE automod_rules SET is_active = p_active WHERE rule_id = p_rule;

    SELECT to_jsonb(r) INTO v_after FROM automod_rules r WHERE r.rule_id = p_rule;

    PERFORM admin_log(
        'automod.toggle', 'automod_rule', p_rule, v_label,
        v_before, v_after, p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_toggle_automod_rule(UUID,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_toggle_automod_rule(UUID,BOOLEAN,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_automod_rule(
    p_rule   UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT; v_before JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT pattern, to_jsonb(r) INTO v_label, v_before
      FROM automod_rules r WHERE r.rule_id = p_rule;
    IF v_label IS NULL THEN RAISE EXCEPTION 'automod rule not found'; END IF;

    -- Audit before the delete — the row is about to vanish.
    PERFORM admin_log(
        'automod.delete', 'automod_rule', p_rule, v_label,
        v_before, NULL, p_reason, '{}'::jsonb
    );
    DELETE FROM automod_rules WHERE rule_id = p_rule;
END $$;

REVOKE ALL ON FUNCTION public.admin_delete_automod_rule(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_automod_rule(UUID,TEXT) TO authenticated;

-- =========================================================================
-- 2) Broadcasts — deactivate
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_deactivate_broadcast(
    p_broadcast UUID,
    p_reason    TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT; v_before JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT title, to_jsonb(b) INTO v_label, v_before
      FROM broadcasts b WHERE b.broadcast_id = p_broadcast;
    IF v_label IS NULL THEN RAISE EXCEPTION 'broadcast not found'; END IF;

    UPDATE broadcasts SET is_active = false WHERE broadcast_id = p_broadcast;

    PERFORM admin_log(
        'broadcast.deactivate', 'broadcast', p_broadcast, v_label,
        v_before, jsonb_build_object('is_active', false), p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_deactivate_broadcast(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_deactivate_broadcast(UUID,TEXT) TO authenticated;

-- =========================================================================
-- 3) Feature flags — fold the description write into admin_set_flag so the
--    whole create is one audited transaction instead of an RPC call followed
--    by a second, unaudited direct UPDATE.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_set_flag(
    p_key         TEXT,
    p_enabled     BOOLEAN,
    p_rollout_pct INT  DEFAULT NULL,
    p_reason      TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_after JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT to_jsonb(f) INTO v_before FROM feature_flags f WHERE flag_key = p_key;
    IF v_before IS NULL THEN
        INSERT INTO feature_flags (flag_key, enabled, rollout_pct, description, updated_by)
        VALUES (p_key, p_enabled, COALESCE(p_rollout_pct, 0), p_description, auth.uid());
    ELSE
        UPDATE feature_flags
           SET enabled = p_enabled,
               rollout_pct = COALESCE(p_rollout_pct, rollout_pct),
               description = COALESCE(p_description, description),
               updated_by = auth.uid(),
               updated_at = now()
         WHERE flag_key = p_key;
    END IF;

    SELECT to_jsonb(f) INTO v_after FROM feature_flags f WHERE flag_key = p_key;

    PERFORM admin_log(
        'flag.update', 'feature_flag', NULL, p_key,
        v_before, v_after, p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_flag(TEXT,BOOLEAN,INT,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_flag(TEXT,BOOLEAN,INT,TEXT,TEXT) TO authenticated;

-- The 4-arg overload from 0022 is superseded — drop it so there is exactly
-- one admin_set_flag and PostgREST/pg_catalog can't resolve the wrong one.
DROP FUNCTION IF EXISTS public.admin_set_flag(TEXT,BOOLEAN,INT,TEXT);

-- =========================================================================
-- 3.5) The preserve_crisis_classification trigger (20260816094705) only lets
-- auth.role() = 'service_role' clear or downgrade a crisis_level — anyone
-- else's UPDATE of that column is silently reverted back to OLD.crisis_level
-- inside the trigger. That's exactly the role the *old* direct-service-role
-- Server Actions ran as, which is why they worked. admin_clear_crisis_flag
-- below is a normal is_staff()-gated RPC invoked through the cookie-bound
-- authenticated client (auth.role() = 'authenticated'), so without this
-- change its UPDATE would be silently reverted by the very next statement in
-- the same trigger-wrapped command — the RPC would report success and write
-- an audit row claiming the flag was cleared, while the row underneath it
-- never changed and the crisis banner kept showing for the member. Trust the
-- same staff roles the RPC itself already gates on, instead of only trusting
-- service_role.
-- =========================================================================

CREATE OR REPLACE FUNCTION private.preserve_crisis_classification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
    IF OLD.crisis_level = 'high' THEN
      NEW.crisis_level := 'high';
    ELSIF OLD.crisis_level = 'elevated' AND NEW.crisis_level IS NULL THEN
      NEW.crisis_level := 'elevated';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- =========================================================================
-- 4) Crisis-flag clearing — one RPC covering all four content kinds, instead
--    of two page files each reimplementing the same UPDATE with different
--    table coverage (safety/page.tsx handled all four; moderation/page.tsx
--    handled only posts).
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_clear_crisis_flag(
    p_target_type TEXT,
    p_target_id   UUID,
    p_reason      TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF p_target_type = 'post' THEN
        SELECT to_jsonb(p) INTO v_before FROM posts p WHERE p.post_id = p_target_id;
        IF v_before IS NULL THEN RAISE EXCEPTION 'post not found'; END IF;
        UPDATE posts SET crisis_level = NULL WHERE post_id = p_target_id;
    ELSIF p_target_type = 'whisper' THEN
        SELECT to_jsonb(w) INTO v_before FROM whispers w WHERE w.whisper_id = p_target_id;
        IF v_before IS NULL THEN RAISE EXCEPTION 'whisper not found'; END IF;
        UPDATE whispers SET crisis_level = NULL WHERE whisper_id = p_target_id;
    ELSIF p_target_type = 'tribe_message' THEN
        SELECT to_jsonb(m) INTO v_before FROM tribe_messages m WHERE m.message_id = p_target_id;
        IF v_before IS NULL THEN RAISE EXCEPTION 'tribe message not found'; END IF;
        UPDATE tribe_messages SET crisis_level = NULL WHERE message_id = p_target_id;
    ELSIF p_target_type = 'chat_message' THEN
        SELECT to_jsonb(m) INTO v_before FROM chat_messages m WHERE m.message_id = p_target_id;
        IF v_before IS NULL THEN RAISE EXCEPTION 'chat message not found'; END IF;
        UPDATE chat_messages SET crisis_level = NULL WHERE message_id = p_target_id;
    ELSE
        RAISE EXCEPTION 'invalid target_type %', p_target_type;
    END IF;

    PERFORM admin_log(
        p_target_type || '.clear_crisis', p_target_type, p_target_id, NULL,
        v_before, jsonb_build_object('crisis_level', NULL), p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_clear_crisis_flag(TEXT,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_clear_crisis_flag(TEXT,UUID,TEXT) TO authenticated;

-- =========================================================================
-- 5) Password reset — fold the recovery-phrase guard into the RPC.
--
-- users/[userId]/page.tsx#resetPassword reimplemented the super_admin check
-- inline in TypeScript, then used the service-role Auth Admin API
-- (auth.admin.updateUserById) as a second, parallel mutation path to the one
-- admin_reset_user_password already provided — because only the Server
-- Action knew about the recovery_blob guard (a phrase-recovery account's
-- password can't be safely reset without also resealing the recovery blob,
-- which an admin reset can't do). Moving the guard into the RPC means there
-- is one authorization+mutation+audit path, not two.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_reset_user_password(
    p_target       UUID,
    p_new_password TEXT,
    p_reason       TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
    v_label TEXT;
    v_recovery_blob TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can reset passwords';
    END IF;
    IF length(coalesce(p_new_password, '')) < 12 THEN
        RAISE EXCEPTION 'password must be at least 12 characters';
    END IF;

    SELECT '@' || anonymous_pseudonym, recovery_blob INTO v_label, v_recovery_blob
      FROM users WHERE user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
    IF v_recovery_blob IS NOT NULL THEN
        RAISE EXCEPTION 'this account is protected by a recovery phrase; the member must recover or change the password with that phrase';
    END IF;

    UPDATE auth.users
       SET encrypted_password = crypt(p_new_password, gen_salt('bf')),
           updated_at = now()
     WHERE id = p_target;
    IF NOT FOUND THEN RAISE EXCEPTION 'auth user not found'; END IF;

    -- Never log the password itself.
    PERFORM admin_log(
        'user.reset_password', 'user', p_target, v_label,
        NULL, NULL, p_reason, '{}'::jsonb
    );
END $$;

NOTIFY pgrst, 'reload schema';
