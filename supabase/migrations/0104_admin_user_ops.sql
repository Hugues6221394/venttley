-- 0104_admin_user_ops.sql
-- Super-admin user management the console was missing: reset a password, edit
-- profile fields, and hard-delete a user (BOTH auth.users + public.users, since
-- there's no FK between them). All are SECURITY DEFINER with an internal
-- is_staff() gate + admin_log audit, so they work through the console's
-- cookie-bound RPC helper (no service-role key required).

-- ---- Reset password --------------------------------------------------------
-- Writes a fresh bcrypt hash straight into GoTrue's auth.users.encrypted_password.
-- pgcrypto (crypt/gen_salt) lives in the `extensions` schema on Supabase.
CREATE OR REPLACE FUNCTION public.admin_reset_user_password(
    p_target       UUID,
    p_new_password TEXT,
    p_reason       TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
    v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can reset passwords';
    END IF;
    IF length(coalesce(p_new_password, '')) < 8 THEN
        RAISE EXCEPTION 'password must be at least 8 characters';
    END IF;

    SELECT '@' || anonymous_pseudonym INTO v_label
      FROM users WHERE user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

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

REVOKE ALL ON FUNCTION public.admin_reset_user_password(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reset_user_password(UUID, TEXT, TEXT) TO authenticated;

-- ---- Edit profile fields ---------------------------------------------------
-- NULL args leave a field unchanged.
CREATE OR REPLACE FUNCTION public.admin_update_user_profile(
    p_target       UUID,
    p_pseudonym    TEXT    DEFAULT NULL,
    p_is_verified  BOOLEAN DEFAULT NULL,
    p_safety_tier  TEXT    DEFAULT NULL,
    p_home_city    TEXT    DEFAULT NULL,
    p_home_country TEXT    DEFAULT NULL,
    p_reason       TEXT    DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_before JSONB; v_after JSONB; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    IF p_pseudonym IS NOT NULL AND length(btrim(p_pseudonym)) < 3 THEN
        RAISE EXCEPTION 'pseudonym must be at least 3 characters';
    END IF;

    UPDATE users u SET
        anonymous_pseudonym = COALESCE(NULLIF(btrim(p_pseudonym), ''), u.anonymous_pseudonym),
        is_verified         = COALESCE(p_is_verified, u.is_verified),
        safety_tier         = COALESCE(NULLIF(p_safety_tier, ''), u.safety_tier),
        home_city           = COALESCE(p_home_city, u.home_city),
        home_country        = COALESCE(p_home_country, u.home_country),
        updated_at          = now()
     WHERE u.user_id = p_target;

    SELECT to_jsonb(u) INTO v_after FROM users u WHERE u.user_id = p_target;

    PERFORM admin_log(
        'user.edit_profile', 'user', p_target, v_label,
        v_before, v_after, p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_update_user_profile(UUID, TEXT, BOOLEAN, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_user_profile(UUID, TEXT, BOOLEAN, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ---- Hard delete -----------------------------------------------------------
-- Removes BOTH the GoTrue identity and the public profile. Audited BEFORE the
-- rows disappear. Cascades clean up posts/comments/memberships.
CREATE OR REPLACE FUNCTION public.admin_delete_user(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_before JSONB; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can delete users';
    END IF;
    IF p_target = auth.uid() THEN
        RAISE EXCEPTION 'you cannot delete your own account here';
    END IF;

    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    -- Audit first — the target rows are about to vanish.
    PERFORM admin_log(
        'user.delete', 'user', p_target, v_label,
        v_before, NULL, p_reason, '{}'::jsonb
    );

    DELETE FROM auth.users   WHERE id = p_target;
    DELETE FROM public.users WHERE user_id = p_target;
END $$;

REVOKE ALL ON FUNCTION public.admin_delete_user(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
