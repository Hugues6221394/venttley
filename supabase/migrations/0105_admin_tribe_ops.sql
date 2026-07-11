-- 0105_admin_tribe_ops.sql
-- Super-admin tribe management for the console: activate/deactivate a tribe,
-- change its keeper (leader), add/remove members, and create a tribe on behalf
-- of a keeper. All SECURITY DEFINER with is_staff() gate + admin_log audit.
-- Member add/remove ride the self-healing member_count trigger (0096).

-- ---- Activate / deactivate -------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_tribe_active(
    p_tribe  UUID,
    p_active BOOLEAN,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before BOOLEAN; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT is_active, name INTO v_before, v_label FROM tribes WHERE tribe_id = p_tribe;
    IF v_label IS NULL THEN RAISE EXCEPTION 'tribe not found'; END IF;

    UPDATE tribes SET is_active = p_active WHERE tribe_id = p_tribe;

    PERFORM admin_log(
        'tribe.set_active', 'tribe', p_tribe, v_label,
        jsonb_build_object('is_active', v_before),
        jsonb_build_object('is_active', p_active),
        p_reason, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_set_tribe_active(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_tribe_active(UUID, BOOLEAN, TEXT) TO authenticated;

-- ---- Change keeper (leader) ------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_tribe_keeper(
    p_tribe      UUID,
    p_new_keeper UUID,
    p_reason     TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old UUID; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT keeper_id, name INTO v_old, v_label FROM tribes WHERE tribe_id = p_tribe;
    IF v_label IS NULL THEN RAISE EXCEPTION 'tribe not found'; END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_new_keeper) THEN
        RAISE EXCEPTION 'new keeper user not found';
    END IF;

    -- New keeper must be a member, promoted to 'keeper'.
    INSERT INTO tribe_members (tribe_id, user_id, role)
    VALUES (p_tribe, p_new_keeper, 'keeper')
    ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = 'keeper';

    -- Demote the previous keeper to a regular member (if different + still in).
    IF v_old IS NOT NULL AND v_old <> p_new_keeper THEN
        UPDATE tribe_members SET role = 'member'
         WHERE tribe_id = p_tribe AND user_id = v_old;
    END IF;

    UPDATE tribes SET keeper_id = p_new_keeper WHERE tribe_id = p_tribe;

    PERFORM admin_log(
        'tribe.set_keeper', 'tribe', p_tribe, v_label,
        jsonb_build_object('keeper_id', v_old),
        jsonb_build_object('keeper_id', p_new_keeper),
        p_reason, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_set_tribe_keeper(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_tribe_keeper(UUID, UUID, TEXT) TO authenticated;

-- ---- Add member ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_add_tribe_member(
    p_tribe  UUID,
    p_user   UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT name INTO v_label FROM tribes WHERE tribe_id = p_tribe;
    IF v_label IS NULL THEN RAISE EXCEPTION 'tribe not found'; END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_user) THEN
        RAISE EXCEPTION 'user not found';
    END IF;

    INSERT INTO tribe_members (tribe_id, user_id, role)
    VALUES (p_tribe, p_user, 'member')
    ON CONFLICT (tribe_id, user_id) DO NOTHING;

    PERFORM admin_log(
        'tribe.add_member', 'tribe', p_tribe, v_label,
        NULL, jsonb_build_object('user_id', p_user), p_reason, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_add_tribe_member(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_add_tribe_member(UUID, UUID, TEXT) TO authenticated;

-- ---- Remove member ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_remove_tribe_member(
    p_tribe  UUID,
    p_user   UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT; v_keeper UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT name, keeper_id INTO v_label, v_keeper FROM tribes WHERE tribe_id = p_tribe;
    IF v_label IS NULL THEN RAISE EXCEPTION 'tribe not found'; END IF;
    IF p_user = v_keeper THEN
        RAISE EXCEPTION 'reassign the keeper before removing them';
    END IF;

    DELETE FROM tribe_members WHERE tribe_id = p_tribe AND user_id = p_user;

    PERFORM admin_log(
        'tribe.remove_member', 'tribe', p_tribe, v_label,
        jsonb_build_object('user_id', p_user), NULL, p_reason, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_remove_tribe_member(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_remove_tribe_member(UUID, UUID, TEXT) TO authenticated;

-- ---- Create tribe on behalf of a keeper ------------------------------------
CREATE OR REPLACE FUNCTION public.admin_create_tribe(
    p_name       TEXT,
    p_category   TEXT,
    p_keeper     UUID,
    p_description TEXT   DEFAULT NULL,
    p_is_private BOOLEAN DEFAULT FALSE,
    p_reason     TEXT    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID; v_slug TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF length(btrim(coalesce(p_name, ''))) < 3 THEN
        RAISE EXCEPTION 'tribe name must be at least 3 characters';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_keeper) THEN
        RAISE EXCEPTION 'keeper user not found';
    END IF;

    v_slug := lower(regexp_replace(btrim(p_name), '[^a-zA-Z0-9]+', '-', 'g'))
              || '-' || substr(md5(random()::text), 1, 6);

    INSERT INTO tribes (name, slug, category, description, is_private, keeper_id, is_active)
    VALUES (p_name, v_slug, p_category, p_description, p_is_private, p_keeper, TRUE)
    RETURNING tribe_id INTO v_id;

    INSERT INTO tribe_members (tribe_id, user_id, role)
    VALUES (v_id, p_keeper, 'keeper')
    ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = 'keeper';

    PERFORM admin_log(
        'tribe.create', 'tribe', v_id, p_name,
        NULL,
        jsonb_build_object('keeper_id', p_keeper, 'slug', v_slug, 'category', p_category),
        p_reason, '{}'::jsonb);

    RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.admin_create_tribe(TEXT, TEXT, UUID, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_tribe(TEXT, TEXT, UUID, TEXT, BOOLEAN, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
