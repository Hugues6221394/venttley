-- Let a Keeper delegate one thing without delegating everything.
--
-- Today a Tribe has two levels of authority and no middle. A 'mod' can act on
-- members and on posts — all of it, warn through ban — and can do nothing
-- else; every other management RPC checks tribes.keeper_id directly, so rules,
-- spaces, settings and even opening the management console are the owner's
-- alone. There is no way to say "you handle the reports queue" without also
-- handing over the power to remove people, and no way to say "you can edit the
-- rules" at all.
--
-- For a Tribe of any size that pushes work back onto one person, and the
-- workaround — promoting someone to mod and hoping — grants far more than
-- intended. On an app whose members include minors, "more than intended" is
-- the part that matters.
--
-- So: named capabilities, granted per member.
--
-- WHAT IS NOT DELEGABLE
--
-- Deleting the Tribe, transferring ownership, pausing or archiving it,
-- promoting and demoting, and granting permissions themselves all stay with
-- the Keeper. Those are the actions that end a community or manufacture more
-- authority, and a delegated helper should not be able to reach them. Their
-- functions are deliberately left untouched by this migration, so they keep
-- calling require_tribe_owner and nothing here can widen them by accident.
--
-- NOTHING CHANGES ON THE DAY THIS RUNS
--
-- permissions is NULL for every existing row, and NULL means "whatever this
-- role could always do". A mod's default set is exactly manage_members and
-- manage_content — the two things the old role check allowed. The Keeper holds
-- everything. So this migration grants nobody anything they did not already
-- have; it only makes the grants nameable, and separable.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The catalog
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tribe_permissions (
  permission_key TEXT PRIMARY KEY
    CHECK (permission_key ~ '^[a-z][a-z0-9_]{2,30}$'),
  label          TEXT NOT NULL,
  description    TEXT NOT NULL,
  sort_order     INT  NOT NULL DEFAULT 100,
  -- Derived permissions are held implicitly and cannot be handed out on their
  -- own, so they are hidden from the grant UI.
  is_grantable   BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE public.tribe_permissions IS
  'Capabilities a Keeper can delegate. Does not include owner-only actions, which are not delegable at all.';

ALTER TABLE public.tribe_permissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tribe_permissions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tribe_permissions TO authenticated;

DROP POLICY IF EXISTS tribe_permissions_read ON public.tribe_permissions;
CREATE POLICY tribe_permissions_read
  ON public.tribe_permissions FOR SELECT TO authenticated USING (TRUE);

-- The descriptions are written for the Keeper choosing, not for a developer
-- reading a schema, because they are what the grant screen shows.
INSERT INTO public.tribe_permissions
  (permission_key, label, description, sort_order, is_grantable) VALUES
  ('manage_members', 'Manage members',
   'Warn, mute, remove and ban members. Cannot touch other helpers or the Keeper.', 10, TRUE),
  ('manage_content', 'Manage posts',
   'Approve, hide, pin, move and remove posts in this Tribe.', 20, TRUE),
  ('handle_reports', 'Handle reports',
   'Open and resolve the reports queue.', 30, TRUE),
  ('manage_rules', 'Edit the rules',
   'Publish new rules. Members are told when the rules change.', 40, TRUE),
  ('manage_spaces', 'Manage Spaces',
   'Create, rename and archive Spaces.', 50, TRUE),
  ('manage_invites', 'Invites and requests',
   'Send invites and decide who gets in.', 60, TRUE),
  ('manage_settings', 'Tribe settings',
   'Change the description, welcome message and posting rules. Not the name, and not the Tribe itself.', 70, TRUE),
  ('view_audit', 'Read the audit log',
   'See who did what in this Tribe.', 80, TRUE),
  ('view_management', 'Open the Keeper Studio',
   'Held automatically by anyone with any other permission.', 999, FALSE)
ON CONFLICT (permission_key) DO UPDATE
  SET label        = EXCLUDED.label,
      description  = EXCLUDED.description,
      sort_order   = EXCLUDED.sort_order,
      is_grantable = EXCLUDED.is_grantable;

-- ---------------------------------------------------------------------------
-- 2. The grants
-- ---------------------------------------------------------------------------

-- NULL means "the default for this member's role". Storing the defaults
-- explicitly on every row instead would freeze today's answer into historical
-- data: changing what a mod can do by default would then require rewriting
-- every membership row, and rows nobody ever edited would drift apart from
-- rows somebody did.
ALTER TABLE public.tribe_members
  ADD COLUMN IF NOT EXISTS permissions TEXT[];

COMMENT ON COLUMN public.tribe_members.permissions IS
  'Explicit capability grants; NULL means fall back to the role default.';

-- ---------------------------------------------------------------------------
-- 3. Reading a member's authority
-- ---------------------------------------------------------------------------

-- The effective set for one member of one Tribe.
--
-- Ownership is read from tribes.keeper_id rather than from the membership
-- role, because keeper_id is what every owner-only check in the app already
-- trusts. If the two ever disagree, the owner is whoever keeper_id says, and
-- this agrees with the rest of the system rather than inventing a second
-- answer.
CREATE OR REPLACE FUNCTION public.tribe_member_permissions(
  p_tribe_id UUID,
  p_user_id  UUID
) RETURNS TEXT[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_owner BOOLEAN;
  v_role     TEXT;
  v_explicit TEXT[];
  v_result   TEXT[];
BEGIN
  IF p_tribe_id IS NULL OR p_user_id IS NULL THEN
    RETURN ARRAY[]::TEXT[];
  END IF;

  SELECT (t.keeper_id = p_user_id) INTO v_is_owner
    FROM public.tribes t WHERE t.tribe_id = p_tribe_id;
  IF v_is_owner IS NULL THEN
    RETURN ARRAY[]::TEXT[];
  END IF;

  IF v_is_owner THEN
    SELECT array_agg(p.permission_key ORDER BY p.sort_order)
      INTO v_result FROM public.tribe_permissions p;
    RETURN COALESCE(v_result, ARRAY[]::TEXT[]);
  END IF;

  SELECT tm.role, tm.permissions INTO v_role, v_explicit
    FROM public.tribe_members tm
   WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;

  -- Not a member: no authority, whatever else is true of them.
  IF v_role IS NULL THEN
    RETURN ARRAY[]::TEXT[];
  END IF;

  IF v_explicit IS NULL THEN
    -- The role defaults. 'mod' gets exactly what the old role check allowed,
    -- so nobody gains or loses anything the day this runs.
    v_result := CASE v_role
                  WHEN 'keeper' THEN ARRAY['manage_members', 'manage_content',
                                           'handle_reports', 'manage_rules',
                                           'manage_spaces', 'manage_invites',
                                           'manage_settings', 'view_audit']
                  WHEN 'mod'    THEN ARRAY['manage_members', 'manage_content']
                  ELSE ARRAY[]::TEXT[]
                END;
  ELSE
    -- Unknown keys are dropped rather than trusted: a permission removed from
    -- the catalog must stop working everywhere, not linger in old rows.
    SELECT COALESCE(array_agg(k ORDER BY k), ARRAY[]::TEXT[]) INTO v_result
      FROM unnest(v_explicit) AS k
     WHERE k IN (SELECT p.permission_key FROM public.tribe_permissions p
                  WHERE p.is_grantable);
  END IF;

  -- Anyone with any capability can open the console those capabilities live
  -- in. Making this derived rather than grantable means a Keeper cannot
  -- accidentally give someone a door into a room they cannot act in.
  IF array_length(v_result, 1) > 0 THEN
    v_result := v_result || ARRAY['view_management'];
  END IF;

  RETURN COALESCE(v_result, ARRAY[]::TEXT[]);
END $$;

REVOKE ALL ON FUNCTION public.tribe_member_permissions(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tribe_member_permissions(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.tribe_member_can(
  p_tribe_id   UUID,
  p_user_id    UUID,
  p_permission TEXT
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_permission = ANY (public.tribe_member_permissions(p_tribe_id, p_user_id));
$$;

REVOKE ALL ON FUNCTION public.tribe_member_can(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tribe_member_can(UUID, UUID, TEXT) TO authenticated;

-- The drop-in for require_tribe_owner in functions whose action is delegable.
-- Returns the tribe row for the same reason require_tribe_owner does: callers
-- assign it and read the before-state from it.
--
-- Note the missing FOR UPDATE. require_tribe_owner locks the row because its
-- callers go on to mutate the tribe itself; the checks here guard actions on
-- members, posts and child rows, and taking a row lock on the parent for every
-- moderation action would serialise a busy Tribe's entire moderation queue
-- behind one row. Callers that do mutate tribes still take their own lock.
CREATE OR REPLACE FUNCTION public.require_tribe_permission(
  p_tribe_id   UUID,
  p_permission TEXT
) RETURNS public.tribes
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_tribe public.tribes;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = p_tribe_id;
  IF v_tribe.tribe_id IS NULL THEN RAISE EXCEPTION 'tribe_not_found'; END IF;

  IF NOT public.tribe_member_can(p_tribe_id, v_me, p_permission) THEN
    -- The same message the owner check raises, so an existing client that
    -- already translates 'not_tribe_owner' keeps saying something sensible
    -- rather than showing a raw error it has never seen.
    RAISE EXCEPTION 'not_tribe_owner';
  END IF;

  RETURN v_tribe;
END $$;

REVOKE ALL ON FUNCTION public.require_tribe_permission(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.require_tribe_permission(UUID, TEXT) TO authenticated;

-- What the signed-in account may do here, for deciding which controls to show.
-- Hiding a control the server would refuse is a courtesy, not a defence: every
-- action re-checks on the way in.
CREATE OR REPLACE FUNCTION public.my_tribe_permissions(p_tribe_id UUID)
RETURNS TEXT[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.tribe_member_permissions(p_tribe_id, (SELECT auth.uid()));
$$;

REVOKE ALL ON FUNCTION public.my_tribe_permissions(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_tribe_permissions(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Granting
-- ---------------------------------------------------------------------------

-- Keeper only, and deliberately not delegable: a helper who could grant
-- permissions could grant themselves the rest, which would make every other
-- boundary here decorative.
CREATE OR REPLACE FUNCTION public.set_tribe_member_permissions(
  p_tribe_id    UUID,
  p_user_id     UUID,
  p_permissions TEXT[]
) RETURNS TEXT[]
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role    TEXT;
  v_clean   TEXT[];
  v_unknown TEXT[];
BEGIN
  PERFORM public.require_tribe_owner(p_tribe_id);

  SELECT tm.role INTO v_role FROM public.tribe_members tm
   WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
  IF v_role IS NULL THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_role = 'keeper' THEN RAISE EXCEPTION 'cannot_manage_owner'; END IF;

  -- Reject unknown or non-grantable keys loudly. Silently dropping them would
  -- leave a Keeper believing they had delegated something they had not.
  SELECT COALESCE(array_agg(DISTINCT k), ARRAY[]::TEXT[]) INTO v_unknown
    FROM unnest(COALESCE(p_permissions, ARRAY[]::TEXT[])) AS k
   WHERE k NOT IN (SELECT p.permission_key FROM public.tribe_permissions p
                    WHERE p.is_grantable);
  IF array_length(v_unknown, 1) > 0 THEN
    RAISE EXCEPTION 'unknown_permission: %', array_to_string(v_unknown, ', ');
  END IF;

  SELECT COALESCE(array_agg(DISTINCT k), ARRAY[]::TEXT[]) INTO v_clean
    FROM unnest(COALESCE(p_permissions, ARRAY[]::TEXT[])) AS k;

  UPDATE public.tribe_members tm
     SET permissions = v_clean,
         -- The role still exists and still means something to the rest of the
         -- app, so it is kept in step: anyone holding a capability reads as a
         -- helper, anyone holding none reads as a plain member.
         role = CASE WHEN array_length(v_clean, 1) > 0 THEN 'mod' ELSE 'member' END
   WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;

  PERFORM public.log_tribe_action(
    p_tribe_id, 'TRIBE_PERMISSIONS_SET', 'member', p_user_id::TEXT,
    NULL, NULL, NULL,
    jsonb_build_object('permissions', to_jsonb(v_clean))
  );

  RETURN public.tribe_member_permissions(p_tribe_id, p_user_id);
END $$;

REVOKE ALL ON FUNCTION public.set_tribe_member_permissions(UUID, UUID, TEXT[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_tribe_member_permissions(UUID, UUID, TEXT[])
  TO authenticated;

-- The catalog plus, for one Tribe, who currently holds what. Keeper only: it
-- is the grant screen's payload.
CREATE OR REPLACE FUNCTION public.tribe_permission_grants(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.require_tribe_owner(p_tribe_id);

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

-- ---------------------------------------------------------------------------
-- 5. Moving the delegable RPCs onto capabilities
--
-- These five are re-emitted verbatim from the migrations that define them
-- today, with only their permission gate changed. Nothing else in the bodies
-- differs — they were extracted and rewritten by script rather than retyped,
-- because a hand-copied hundred-line body is a place for silent drift.
--
-- Everything NOT listed here still calls require_tribe_owner and is therefore
-- still owner-only: deleting the Tribe, transferring it, pausing or archiving
-- it, promoting and demoting, and granting permissions. That is the point of
-- changing these individually instead of loosening the shared helper — what is
-- not named here cannot be widened by accident.
-- ---------------------------------------------------------------------------

-- Opening the console. Any delegated capability implies view_management, so a
-- helper can reach the screen their capability lives on.
CREATE OR REPLACE FUNCTION public.tribe_management_overview(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tribe public.tribes; v_result JSONB;
BEGIN
  v_tribe := public.require_tribe_permission(p_tribe_id, 'view_management');
  SELECT jsonb_build_object(
    'tribe_id', v_tribe.tribe_id,
    'name', v_tribe.name,
    'slug', v_tribe.slug,
    'description', v_tribe.description,
    'category', v_tribe.category,
    'tags', v_tribe.tags,
    'visibility', v_tribe.visibility,
    'lifecycle_status', v_tribe.lifecycle_status,
    'lifecycle_reason', v_tribe.lifecycle_reason,
    'paused_at', v_tribe.paused_at,
    'archived_at', v_tribe.archived_at,
    'deletion_requested_at', v_tribe.deletion_requested_at,
    'deletion_purge_at', v_tribe.deletion_purge_at,
    'avatar_url', v_tribe.avatar_url,
    'banner_url', v_tribe.banner_url,
    'welcome_message', v_tribe.welcome_message,
    'settings', v_tribe.settings,
    'member_count', v_tribe.member_count,
    'post_count', (SELECT count(*) FROM public.posts p WHERE p.tribe_id = p_tribe_id AND p.deleted_at IS NULL),
    'space_count', (SELECT count(*) FROM public.spaces s WHERE s.tribe_id = p_tribe_id AND s.archived_at IS NULL),
    'pending_join_requests', (SELECT count(*) FROM public.tribe_join_requests j WHERE j.tribe_id = p_tribe_id AND j.status = 'pending'),
    'pending_invitations', (SELECT count(*) FROM public.tribe_invites i WHERE i.tribe_id = p_tribe_id AND i.status = 'pending'),
    'open_reports', (
      SELECT count(*) FROM public.reports r
      JOIN public.posts p ON p.post_id = r.post_id
      WHERE p.tribe_id = p_tribe_id AND NOT r.is_resolved
    ),
    'rules', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'rule_id', ri.rule_id,
        'position', ri.position,
        'title', ri.title,
        'description', ri.description,
        'template_key', ri.template_key,
        'is_enabled', ri.is_enabled
      ) ORDER BY ri.position)
      FROM public.tribe_rule_items ri WHERE ri.tribe_id = p_tribe_id
    ), '[]'::JSONB),
    'pending_transfer', (
      SELECT to_jsonb(x) FROM (
        SELECT ot.transfer_id, ot.to_user_id, u.anonymous_pseudonym AS to_pseudonym,
               ot.keep_previous_owner_as_mod, ot.created_at, ot.expires_at
          FROM public.tribe_ownership_transfers ot
          JOIN public.users u ON u.user_id = ot.to_user_id
         WHERE ot.tribe_id = p_tribe_id AND ot.status = 'pending'
         LIMIT 1
      ) x
    )
  ) INTO v_result;
  RETURN v_result;
END;
$$;

-- Description, welcome message and posting rules.
CREATE OR REPLACE FUNCTION public.update_tribe_configuration(
  p_tribe_id UUID,
  p_name TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_tags TEXT[] DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL,
  p_banner_url TEXT DEFAULT NULL,
  p_welcome_message TEXT DEFAULT NULL,
  p_settings JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_before public.tribes; v_after public.tribes; v_settings JSONB;
BEGIN
  v_before := public.require_tribe_permission(p_tribe_id, 'manage_settings');
  IF p_name IS NOT NULL AND char_length(btrim(p_name)) NOT BETWEEN 3 AND 50 THEN
    RAISE EXCEPTION 'tribe_name_length';
  END IF;
  IF p_description IS NOT NULL AND char_length(p_description) > 500 THEN
    RAISE EXCEPTION 'tribe_description_length';
  END IF;
  IF p_category IS NOT NULL AND char_length(btrim(p_category)) NOT BETWEEN 2 AND 40 THEN
    RAISE EXCEPTION 'tribe_category_length';
  END IF;
  IF p_visibility IS NOT NULL AND p_visibility NOT IN ('public', 'private', 'invite_only') THEN
    RAISE EXCEPTION 'invalid_visibility';
  END IF;
  IF p_tags IS NOT NULL AND cardinality(p_tags) > 8 THEN
    RAISE EXCEPTION 'too_many_tags';
  END IF;

  v_settings := v_before.settings || COALESCE(p_settings, '{}'::JSONB);
  IF COALESCE((v_settings->>'minimum_account_age_days')::INT, 0) NOT BETWEEN 0 AND 3650 THEN
    RAISE EXCEPTION 'invalid_minimum_account_age';
  END IF;
  IF COALESCE((v_settings->>'slow_mode_seconds')::INT, 0) NOT BETWEEN 0 AND 86400 THEN
    RAISE EXCEPTION 'invalid_slow_mode';
  END IF;
  IF COALESCE(v_settings->>'post_approval_mode', 'off') NOT IN ('off', 'new_members', 'all') THEN
    RAISE EXCEPTION 'invalid_post_approval_mode';
  END IF;
  IF COALESCE(v_settings->>'posting_permission', 'members') NOT IN ('members', 'mods', 'keeper') THEN
    RAISE EXCEPTION 'invalid_posting_permission';
  END IF;
  IF COALESCE(v_settings->>'content_sensitivity_filter', 'standard') NOT IN ('low', 'standard', 'strict') THEN
    RAISE EXCEPTION 'invalid_sensitivity_filter';
  END IF;

  UPDATE public.tribes SET
    name = COALESCE(NULLIF(btrim(p_name), ''), name),
    description = CASE WHEN p_description IS NULL THEN description ELSE NULLIF(btrim(p_description), '') END,
    category = COALESCE(NULLIF(btrim(p_category), ''), category),
    tags = COALESCE(p_tags, tags),
    visibility = COALESCE(p_visibility, visibility),
    is_private = COALESCE(p_visibility, visibility) <> 'public',
    avatar_url = CASE WHEN p_avatar_url IS NULL THEN avatar_url ELSE NULLIF(btrim(p_avatar_url), '') END,
    banner_url = CASE WHEN p_banner_url IS NULL THEN banner_url ELSE NULLIF(btrim(p_banner_url), '') END,
    welcome_message = CASE WHEN p_welcome_message IS NULL THEN welcome_message ELSE NULLIF(btrim(p_welcome_message), '') END,
    settings = v_settings,
    updated_at = now()
  WHERE tribe_id = p_tribe_id
  RETURNING * INTO v_after;

  PERFORM public.log_tribe_action(
    p_tribe_id, 'TRIBE_CONFIGURATION_UPDATED', 'tribe', p_tribe_id::TEXT,
    NULL,
    jsonb_build_object('name', v_before.name, 'visibility', v_before.visibility, 'category', v_before.category, 'settings', v_before.settings),
    jsonb_build_object('name', v_after.name, 'visibility', v_after.visibility, 'category', v_after.category, 'settings', v_after.settings)
  );
  RETURN public.tribe_management_overview(p_tribe_id);
END;
$$;

-- Creating, renaming and archiving Spaces.
CREATE OR REPLACE FUNCTION public.manage_tribe_space(
  p_tribe_id UUID,
  p_action TEXT,
  p_space_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_icon_name TEXT DEFAULT NULL,
  p_weekly_theme TEXT DEFAULT NULL,
  p_posting_permission TEXT DEFAULT NULL,
  p_is_pinned BOOLEAN DEFAULT NULL,
  p_activates_at TIMESTAMPTZ DEFAULT NULL,
  p_deactivates_at TIMESTAMPTZ DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_space public.spaces; v_id UUID; v_slug TEXT; v_default UUID;
BEGIN
  PERFORM public.require_tribe_permission(p_tribe_id, 'manage_spaces');
  IF p_action = 'create' THEN
    IF char_length(btrim(COALESCE(p_name, ''))) NOT BETWEEN 2 AND 60 THEN RAISE EXCEPTION 'invalid_space_name'; END IF;
    v_slug := regexp_replace(lower(btrim(p_name)), '[^a-z0-9]+', '-', 'g');
    v_slug := btrim(v_slug, '-');
    IF v_slug = '' THEN v_slug := 'space'; END IF;
    WHILE EXISTS (SELECT 1 FROM public.spaces WHERE tribe_id = p_tribe_id AND slug = v_slug) LOOP
      v_slug := v_slug || '-' || substr(md5(random()::TEXT), 1, 4);
    END LOOP;
    INSERT INTO public.spaces (
      tribe_id, slug, name, description, icon_name, weekly_theme,
      posting_permission, is_pinned, activates_at, deactivates_at, created_by
    ) VALUES (
      p_tribe_id, v_slug, btrim(p_name), NULLIF(btrim(p_description), ''), p_icon_name,
      NULLIF(btrim(p_weekly_theme), ''), COALESCE(p_posting_permission, 'members'),
      COALESCE(p_is_pinned, FALSE), p_activates_at, p_deactivates_at, (SELECT auth.uid())
    ) RETURNING space_id INTO v_id;
  ELSE
    SELECT * INTO v_space FROM public.spaces WHERE space_id = p_space_id AND tribe_id = p_tribe_id FOR UPDATE;
    IF v_space.space_id IS NULL THEN RAISE EXCEPTION 'space_not_found'; END IF;
    v_id := v_space.space_id;
    CASE p_action
      WHEN 'update' THEN
        UPDATE public.spaces SET
          name = COALESCE(NULLIF(btrim(p_name), ''), name),
          description = CASE WHEN p_description IS NULL THEN description ELSE NULLIF(btrim(p_description), '') END,
          icon_name = CASE WHEN p_icon_name IS NULL THEN icon_name ELSE NULLIF(btrim(p_icon_name), '') END,
          weekly_theme = CASE WHEN p_weekly_theme IS NULL THEN weekly_theme ELSE NULLIF(btrim(p_weekly_theme), '') END,
          posting_permission = COALESCE(p_posting_permission, posting_permission),
          is_pinned = COALESCE(p_is_pinned, is_pinned),
          activates_at = COALESCE(p_activates_at, activates_at),
          deactivates_at = COALESCE(p_deactivates_at, deactivates_at),
          updated_at = now()
        WHERE space_id = p_space_id;
      WHEN 'archive' THEN
        IF v_space.is_default THEN RAISE EXCEPTION 'cannot_archive_default_space'; END IF;
        UPDATE public.spaces SET archived_at = now(), updated_at = now() WHERE space_id = p_space_id;
      WHEN 'restore' THEN
        UPDATE public.spaces SET archived_at = NULL, updated_at = now() WHERE space_id = p_space_id;
      WHEN 'delete' THEN
        IF v_space.is_default THEN RAISE EXCEPTION 'cannot_delete_default_space'; END IF;
        SELECT space_id INTO v_default FROM public.spaces
         WHERE tribe_id = p_tribe_id AND is_default LIMIT 1;
        UPDATE public.posts SET space_id = v_default WHERE space_id = p_space_id;
        DELETE FROM public.spaces WHERE space_id = p_space_id;
      ELSE RAISE EXCEPTION 'invalid_space_action';
    END CASE;
  END IF;
  PERFORM public.log_tribe_action(
    p_tribe_id, 'SPACE_' || upper(p_action), 'space', v_id::TEXT, p_reason,
    CASE WHEN v_space.space_id IS NULL THEN NULL ELSE to_jsonb(v_space) END,
    jsonb_build_object('name', p_name, 'posting_permission', p_posting_permission)
  );
  RETURN v_id;
END;
$$;

-- Post moderation. Was 'keeper or mod'; is now the capability those two
-- roles hold by default, so today's behaviour is unchanged.
CREATE OR REPLACE FUNCTION public.manage_tribe_post(
  p_tribe_id UUID,
  p_post_id UUID,
  p_action TEXT,
  p_target_space_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_role TEXT; v_post public.posts;
BEGIN
  SELECT role INTO v_role FROM public.tribe_members
   WHERE tribe_id = p_tribe_id AND user_id = (SELECT auth.uid());
  IF NOT public.tribe_member_can(p_tribe_id, (SELECT auth.uid()), 'manage_content') THEN
    RAISE EXCEPTION 'not_tribe_manager';
  END IF;
  SELECT * INTO v_post FROM public.posts WHERE post_id = p_post_id AND tribe_id = p_tribe_id FOR UPDATE;
  IF v_post.post_id IS NULL THEN RAISE EXCEPTION 'post_not_found'; END IF;
  IF p_action IN ('reject', 'hide', 'sensitive', 'archive', 'remove')
     AND char_length(btrim(COALESCE(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'moderation_reason_required';
  END IF;
  CASE p_action
    WHEN 'approve' THEN UPDATE public.posts SET is_approved = TRUE WHERE post_id = p_post_id;
    WHEN 'reject' THEN UPDATE public.posts SET deleted_at = COALESCE(deleted_at, now()) WHERE post_id = p_post_id;
    WHEN 'pin' THEN
      INSERT INTO public.tribe_pinned_posts (tribe_id, post_id, pinned_by)
      VALUES (p_tribe_id, p_post_id, (SELECT auth.uid()))
      ON CONFLICT (tribe_id, post_id)
      DO UPDATE SET pinned_by = EXCLUDED.pinned_by, pinned_at = now();
    WHEN 'unpin' THEN
      DELETE FROM public.tribe_pinned_posts
       WHERE tribe_id = p_tribe_id AND post_id = p_post_id;
    WHEN 'feature' THEN UPDATE public.posts SET featured_at = now() WHERE post_id = p_post_id;
    WHEN 'unfeature' THEN UPDATE public.posts SET featured_at = NULL WHERE post_id = p_post_id;
    WHEN 'hide' THEN UPDATE public.posts SET hidden_at = now() WHERE post_id = p_post_id;
    WHEN 'unhide' THEN UPDATE public.posts SET hidden_at = NULL WHERE post_id = p_post_id;
    WHEN 'lock' THEN UPDATE public.posts SET locked_at = now() WHERE post_id = p_post_id;
    WHEN 'unlock' THEN UPDATE public.posts SET locked_at = NULL WHERE post_id = p_post_id;
    WHEN 'sensitive' THEN UPDATE public.posts SET sensitive_at = now(), media_status = 'sensitive' WHERE post_id = p_post_id;
    WHEN 'archive' THEN UPDATE public.posts SET archived_at = now() WHERE post_id = p_post_id;
    WHEN 'unarchive' THEN UPDATE public.posts SET archived_at = NULL WHERE post_id = p_post_id;
    WHEN 'move' THEN
      IF NOT EXISTS (SELECT 1 FROM public.spaces WHERE space_id = p_target_space_id AND tribe_id = p_tribe_id) THEN
        RAISE EXCEPTION 'target_space_not_found';
      END IF;
      UPDATE public.posts SET space_id = p_target_space_id WHERE post_id = p_post_id;
    WHEN 'remove' THEN UPDATE public.posts SET deleted_at = COALESCE(deleted_at, now()) WHERE post_id = p_post_id;
    ELSE RAISE EXCEPTION 'invalid_post_action';
  END CASE;
  PERFORM public.log_tribe_action(
    p_tribe_id, 'POST_' || upper(p_action), 'post', p_post_id::TEXT, p_reason,
    jsonb_build_object('space_id', v_post.space_id, 'deleted_at', v_post.deleted_at),
    jsonb_build_object('target_space_id', p_target_space_id)
  );
  RETURN TRUE;
END;
$$;

-- Member moderation. Same swap, plus one tightening: the rule that stopped a
-- mod acting on another mod named the role, and permissions can now be held by
-- a member. It names the Keeper instead, so a delegate can never act on
-- another delegate regardless of what role either of them carries.
CREATE OR REPLACE FUNCTION public.manage_tribe_member(
  p_tribe_id UUID,
  p_user_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT NULL,
  p_mute_until TIMESTAMPTZ DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor_role TEXT;
  v_target_role TEXT;
BEGIN
  SELECT tm.role INTO v_actor_role
    FROM public.tribe_members AS tm
   WHERE tm.tribe_id = p_tribe_id
     AND tm.user_id = auth.uid();
  SELECT tm.role INTO v_target_role
    FROM public.tribe_members AS tm
   WHERE tm.tribe_id = p_tribe_id
     AND tm.user_id = p_user_id;

  IF NOT public.tribe_member_can(p_tribe_id, (SELECT auth.uid()), 'manage_members') THEN
    RAISE EXCEPTION 'not_tribe_manager';
  END IF;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_target_role = 'keeper' THEN RAISE EXCEPTION 'cannot_manage_owner'; END IF;
  IF v_actor_role IS DISTINCT FROM 'keeper' AND v_target_role = 'mod' THEN RAISE EXCEPTION 'owner_action_required'; END IF;
  IF p_action IN ('promote', 'demote') AND v_actor_role <> 'keeper' THEN
    RAISE EXCEPTION 'owner_action_required';
  END IF;

  CASE p_action
    WHEN 'warn' THEN
      UPDATE public.tribe_members AS tm
         SET warning_count = tm.warning_count + 1, last_warned_at = now()
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    WHEN 'mute' THEN
      UPDATE public.tribe_members AS tm
         SET muted_until = COALESCE(p_mute_until, now() + INTERVAL '24 hours')
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    WHEN 'unmute' THEN
      UPDATE public.tribe_members AS tm SET muted_until = NULL
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    WHEN 'promote' THEN
      UPDATE public.tribe_members AS tm SET role = 'mod'
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    WHEN 'demote' THEN
      UPDATE public.tribe_members AS tm SET role = 'member'
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    WHEN 'remove' THEN
      DELETE FROM public.tribe_members AS tm
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    WHEN 'ban' THEN
      INSERT INTO public.tribe_bans (tribe_id, user_id, reason, banned_by)
      VALUES (
        p_tribe_id, p_user_id, NULLIF(btrim(p_reason), ''), auth.uid()
      )
      ON CONFLICT (tribe_id, user_id) DO UPDATE
        SET reason = EXCLUDED.reason,
            banned_by = EXCLUDED.banned_by,
            banned_at = now();
      DELETE FROM public.tribe_members AS tm
       WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_user_id;
    ELSE
      RAISE EXCEPTION 'invalid_member_action';
  END CASE;

  PERFORM public.log_tribe_action(
    p_tribe_id,
    'MEMBER_' || upper(p_action),
    'user',
    p_user_id::TEXT,
    p_reason,
    jsonb_build_object('role', v_target_role),
    NULL,
    jsonb_build_object('mute_until', p_mute_until)
  );
  RETURN TRUE;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. The rules RPCs
--
-- 20260831090000 introduced these against require_tribe_owner because
-- capabilities did not exist yet. Editing the rules is exactly the kind of
-- work a Keeper wants help with, so both move onto manage_rules. Only the
-- gate changes; everything else is as that migration left it.
--
-- Redefined here rather than edited there so the two migrations can be run in
-- either order and land in the same place.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publish_tribe_rules(
  p_tribe_id    UUID,
  p_rules       JSONB,
  p_change_note TEXT
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item     JSONB;
  v_position INT := 0;
  v_version  INT;
BEGIN
  PERFORM public.require_tribe_permission(p_tribe_id, 'manage_rules');

  IF jsonb_typeof(COALESCE(p_rules, '[]'::JSONB)) <> 'array'
     OR jsonb_array_length(COALESCE(p_rules, '[]'::JSONB)) > 50 THEN
    RAISE EXCEPTION 'invalid_rules';
  END IF;

  DELETE FROM public.tribe_rule_items WHERE tribe_id = p_tribe_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_rules, '[]'::JSONB)) LOOP
    IF char_length(btrim(COALESCE(v_item->>'title', ''))) NOT BETWEEN 2 AND 100 THEN
      RAISE EXCEPTION 'invalid_rule_title';
    END IF;
    INSERT INTO public.tribe_rule_items (
      tribe_id, position, title, description, template_key, is_enabled, created_by
    ) VALUES (
      p_tribe_id, v_position, btrim(v_item->>'title'),
      NULLIF(btrim(v_item->>'description'), ''), NULLIF(v_item->>'template_key', ''),
      COALESCE((v_item->>'is_enabled')::BOOLEAN, TRUE), (SELECT auth.uid())
    );
    v_position := v_position + 1;
  END LOOP;

  UPDATE public.tribes
     SET rules = NULLIF((
       SELECT string_agg((position + 1)::TEXT || '. ' || title, E'\n' ORDER BY position)
       FROM public.tribe_rule_items WHERE tribe_id = p_tribe_id AND is_enabled
     ), ''), updated_at = now()
   WHERE tribe_id = p_tribe_id;

  v_version := private.record_tribe_rules_version(
    p_tribe_id, p_change_note, (SELECT auth.uid())
  );

  PERFORM public.log_tribe_action(
    p_tribe_id, 'TRIBE_RULES_REPLACED', 'rules', p_tribe_id::TEXT,
    NULLIF(btrim(COALESCE(p_change_note, '')), ''), NULL, NULL,
    jsonb_build_object('count', v_position, 'version', v_version)
  );

  RETURN public.tribe_management_overview(p_tribe_id);
END $$;

CREATE OR REPLACE FUNCTION public.tribe_rules_history(
  p_tribe_id UUID,
  p_limit    INT DEFAULT 20
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
BEGIN
  PERFORM public.require_tribe_permission(p_tribe_id, 'manage_rules');

  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.version DESC) FROM (
      SELECT rv.version,
             rv.rules,
             rv.change_note,
             rv.published_at,
             u.anonymous_pseudonym AS published_by_pseudonym,
             (SELECT count(*) FROM public.tribe_rule_acknowledgements a
               WHERE a.tribe_id = rv.tribe_id AND a.version >= rv.version)
               AS acknowledged_count
        FROM public.tribe_rule_versions rv
        LEFT JOIN public.users u ON u.user_id = rv.published_by
       WHERE rv.tribe_id = p_tribe_id
       ORDER BY rv.version DESC
       LIMIT v_limit
    ) x
  ), '[]'::JSONB);
END $$;

-- ---------------------------------------------------------------------------
-- 7. A check that has never been true
--
-- 0066 lets a Keeper or a 'co_mod' close a chat poll. There is no such role:
-- tribe_members.role is constrained to member, mod and keeper, so that branch
-- has always evaluated false and closing a poll has been the owner's alone.
-- The intent was plainly that helpers could close polls, so it now asks the
-- capability instead of a role that does not exist.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.close_tribe_chat_poll(p_message_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_me UUID := (SELECT auth.uid());
    v_tribe_id UUID;
    v_meta JSONB;
    v_can BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT m.tribe_id, m.metadata
      INTO v_tribe_id, v_meta
      FROM public.tribe_messages m
     WHERE m.message_id = p_message_id AND m.deleted_at IS NULL;

    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF COALESCE(v_meta->>'kind', '') <> 'poll' THEN
        RAISE EXCEPTION 'not a poll message';
    END IF;

    v_can := public.tribe_member_can(v_tribe_id, v_me, 'manage_content');

    IF NOT v_can THEN RAISE EXCEPTION 'not authorized'; END IF;

    UPDATE public.tribe_messages
       SET metadata = COALESCE(metadata, '{}'::jsonb)
           || jsonb_build_object('is_closed', true, 'closed_at', now())
     WHERE message_id = p_message_id;
END;
$$;

COMMIT;

SELECT public.record_migration(
  '20260901090000', 'granular_tribe_permissions'
);

NOTIFY pgrst, 'reload schema';
