-- Production-grade Tribe ownership and lifecycle management.
--
-- Design goals:
--   * sensitive writes are atomic RPCs with explicit owner/mod checks;
--   * deletion is a 30-day soft-delete request, never an immediate cascade;
--   * ownership transfers require recipient acceptance;
--   * settings, member actions, spaces, content and lifecycle changes are
--     recorded in an immutable audit trail;
--   * RLS remains the final authority for every Data API read.

-- -------------------------------------------------------------------------
-- 1. Tribe lifecycle, discovery, and safety configuration
-- -------------------------------------------------------------------------

ALTER TABLE public.tribes
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS lifecycle_status TEXT NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'public',
  ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
  ADD COLUMN IF NOT EXISTS paused_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deletion_requested_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deletion_purge_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lifecycle_reason TEXT;

UPDATE public.tribes
   SET visibility = CASE WHEN is_private THEN 'private' ELSE 'public' END
 WHERE visibility IS NULL
    OR visibility NOT IN ('public', 'private', 'invite_only')
    OR (is_private AND visibility = 'public');

ALTER TABLE public.tribes
  DROP CONSTRAINT IF EXISTS tribes_lifecycle_status_check,
  DROP CONSTRAINT IF EXISTS tribes_visibility_check,
  DROP CONSTRAINT IF EXISTS tribes_tags_check,
  DROP CONSTRAINT IF EXISTS tribes_name_management_check,
  DROP CONSTRAINT IF EXISTS tribes_description_management_check;

ALTER TABLE public.tribes
  ADD CONSTRAINT tribes_lifecycle_status_check
    CHECK (lifecycle_status IN ('active', 'paused', 'archived', 'pending_deletion')),
  ADD CONSTRAINT tribes_visibility_check
    CHECK (visibility IN ('public', 'private', 'invite_only')),
  ADD CONSTRAINT tribes_tags_check
    CHECK (cardinality(tags) <= 8),
  ADD CONSTRAINT tribes_name_management_check
    CHECK (char_length(btrim(name)) BETWEEN 3 AND 50),
  ADD CONSTRAINT tribes_description_management_check
    CHECK (description IS NULL OR char_length(description) <= 500);

CREATE INDEX IF NOT EXISTS tribes_keeper_lifecycle_idx
  ON public.tribes (keeper_id, lifecycle_status, updated_at DESC);
CREATE INDEX IF NOT EXISTS tribes_deletion_purge_idx
  ON public.tribes (deletion_purge_at)
  WHERE lifecycle_status = 'pending_deletion';
CREATE INDEX IF NOT EXISTS tribes_tags_gin_idx
  ON public.tribes USING GIN (tags);

-- Normalized defaults keep the client and database in agreement while the
-- JSONB column remains forward-compatible for future settings.
UPDATE public.tribes
   SET settings = jsonb_build_object(
         'join_approval_required', COALESCE((settings->>'join_approval_required')::BOOLEAN, FALSE),
         'minimum_account_age_days', COALESCE((settings->>'minimum_account_age_days')::INT, 0),
         'post_approval_mode', COALESCE(settings->>'post_approval_mode', 'off'),
         'posting_permission', COALESCE(settings->>'posting_permission', 'members'),
         'slow_mode_seconds', COALESCE((settings->>'slow_mode_seconds')::INT, 0),
         'allow_whispers', COALESCE((settings->>'allow_whispers')::BOOLEAN, TRUE),
         'allow_polls', COALESCE((settings->>'allow_polls')::BOOLEAN, TRUE),
         'allow_anonymous_reactions', COALESCE((settings->>'allow_anonymous_reactions')::BOOLEAN, TRUE),
         'content_sensitivity_filter', COALESCE(settings->>'content_sensitivity_filter', 'standard'),
         'show_content_when_paused', COALESCE((settings->>'show_content_when_paused')::BOOLEAN, TRUE),
         'invite_links_enabled', COALESCE((settings->>'invite_links_enabled')::BOOLEAN, TRUE)
       ) || settings;

-- -------------------------------------------------------------------------
-- 2. Structured rules, approvals, ownership transfer, and audit records
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tribe_rule_items (
  rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tribe_id UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
  position INT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  template_key TEXT,
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tribe_id, position),
  CHECK (position BETWEEN 0 AND 49),
  CHECK (char_length(btrim(title)) BETWEEN 2 AND 100),
  CHECK (description IS NULL OR char_length(description) <= 500)
);

CREATE TABLE IF NOT EXISTS public.tribe_join_requests (
  request_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tribe_id UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  note TEXT,
  decided_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at TIMESTAMPTZ,
  UNIQUE (tribe_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.tribe_ownership_transfers (
  transfer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tribe_id UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
  from_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  to_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  keep_previous_owner_as_mod BOOLEAN NOT NULL DEFAULT TRUE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '7 days',
  responded_at TIMESTAMPTZ,
  CHECK (from_user_id <> to_user_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS tribe_transfer_one_pending_idx
  ON public.tribe_ownership_transfers (tribe_id)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS public.tribe_audit_log (
  audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tribe_id UUID REFERENCES public.tribes(tribe_id) ON DELETE SET NULL,
  actor_id UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  target_type TEXT,
  target_id TEXT,
  reason TEXT,
  before_state JSONB,
  after_state JSONB,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tribe_audit_log_tribe_created_idx
  ON public.tribe_audit_log (tribe_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tribe_join_requests_pending_idx
  ON public.tribe_join_requests (tribe_id, created_at ASC)
  WHERE status = 'pending';

ALTER TABLE public.tribe_members
  ADD COLUMN IF NOT EXISTS muted_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS warning_count INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_warned_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS member_note TEXT;

ALTER TABLE public.spaces
  ADD COLUMN IF NOT EXISTS icon_name TEXT,
  ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS posting_permission TEXT NOT NULL DEFAULT 'members',
  ADD COLUMN IF NOT EXISTS activates_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deactivates_at TIMESTAMPTZ;

ALTER TABLE public.spaces
  DROP CONSTRAINT IF EXISTS spaces_posting_permission_check;
ALTER TABLE public.spaces
  ADD CONSTRAINT spaces_posting_permission_check
  CHECK (posting_permission IN ('members', 'mods', 'keeper', 'read_only'));

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS featured_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hidden_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sensitive_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

-- Ownership transfer notifications are actionable in the app. Keep the
-- complete notification-kind contract synchronized with migration 0113.
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind::TEXT IN (
    'comment_reply', 'post_like', 'comment_like', 'mention',
    'new_follower', 'friend_request', 'friend_accepted',
    'message_request', 'message_accepted',
    'tribe_prompt', 'tribe_invite', 'tribe_ownership_transfer',
    'whisper_reply', 'whisper_reaction',
    'moderation_action', 'admin_broadcast', 'system'
  ));

ALTER TABLE public.tribe_rule_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tribe_join_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tribe_ownership_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tribe_audit_log ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.tribe_rule_items TO anon, authenticated;
GRANT SELECT ON public.tribe_join_requests TO authenticated;
GRANT SELECT ON public.tribe_ownership_transfers TO authenticated;
GRANT SELECT ON public.tribe_audit_log TO authenticated;

DROP POLICY IF EXISTS "tribe rules visible" ON public.tribe_rule_items;
CREATE POLICY "tribe rules visible"
  ON public.tribe_rule_items FOR SELECT
  USING (
    EXISTS (
      SELECT 1
        FROM public.tribes t
       WHERE t.tribe_id = tribe_rule_items.tribe_id
         AND (
           t.visibility = 'public'
           OR t.keeper_id = (SELECT auth.uid())
           OR EXISTS (
             SELECT 1 FROM public.tribe_members tm
              WHERE tm.tribe_id = t.tribe_id
                AND tm.user_id = (SELECT auth.uid())
           )
         )
    )
  );

DROP POLICY IF EXISTS "join requests participants read" ON public.tribe_join_requests;
CREATE POLICY "join requests participants read"
  ON public.tribe_join_requests FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR public.can_manage_tribe(tribe_id)
  );

DROP POLICY IF EXISTS "ownership transfers participants read" ON public.tribe_ownership_transfers;
CREATE POLICY "ownership transfers participants read"
  ON public.tribe_ownership_transfers FOR SELECT TO authenticated
  USING (
    from_user_id = (SELECT auth.uid())
    OR to_user_id = (SELECT auth.uid())
    OR public.can_manage_tribe(tribe_id)
  );

DROP POLICY IF EXISTS "tribe audit managers read" ON public.tribe_audit_log;
CREATE POLICY "tribe audit managers read"
  ON public.tribe_audit_log FOR SELECT TO authenticated
  USING (
    public.can_manage_tribe(tribe_id)
    OR public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin'])
  );

-- -------------------------------------------------------------------------
-- 3. Internal helpers
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.log_tribe_action(
  p_tribe_id UUID,
  p_action TEXT,
  p_target_type TEXT DEFAULT NULL,
  p_target_id TEXT DEFAULT NULL,
  p_reason TEXT DEFAULT NULL,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.tribe_audit_log (
    tribe_id, actor_id, action, target_type, target_id, reason,
    before_state, after_state, metadata
  ) VALUES (
    p_tribe_id, (SELECT auth.uid()), p_action, p_target_type, p_target_id,
    NULLIF(btrim(p_reason), ''), p_before, p_after, COALESCE(p_metadata, '{}'::JSONB)
  ) RETURNING audit_id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.log_tribe_action(UUID, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.require_tribe_owner(p_tribe_id UUID)
RETURNS public.tribes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tribe public.tribes;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = p_tribe_id FOR UPDATE;
  IF v_tribe.tribe_id IS NULL THEN
    RAISE EXCEPTION 'tribe_not_found';
  END IF;
  IF v_tribe.keeper_id <> (SELECT auth.uid()) THEN
    RAISE EXCEPTION 'not_tribe_owner';
  END IF;
  RETURN v_tribe;
END;
$$;

REVOKE ALL ON FUNCTION public.require_tribe_owner(UUID) FROM PUBLIC;

-- -------------------------------------------------------------------------
-- 4. Management read model and configuration update
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.tribe_management_overview(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tribe public.tribes; v_result JSONB;
BEGIN
  v_tribe := public.require_tribe_owner(p_tribe_id);
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

REVOKE ALL ON FUNCTION public.tribe_management_overview(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tribe_management_overview(UUID) TO authenticated;

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
  v_before := public.require_tribe_owner(p_tribe_id);
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

REVOKE ALL ON FUNCTION public.update_tribe_configuration(UUID, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_tribe_configuration(UUID, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated;

-- Every Tribe must have a durable landing Space, regardless of whether it was
-- created by the mobile app, an admin tool, or a future trusted integration.
CREATE OR REPLACE FUNCTION public.ensure_default_tribe_space()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.spaces (
    tribe_id, slug, name, description, created_by, is_default
  ) VALUES (
    NEW.tribe_id,
    'general',
    'General',
    'The main room for ' || NEW.name || '. Everything starts here.',
    NEW.keeper_id,
    TRUE
  )
  ON CONFLICT (tribe_id, slug) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_default_tribe_space() FROM PUBLIC;
DROP TRIGGER IF EXISTS ensure_default_tribe_space ON public.tribes;
CREATE TRIGGER ensure_default_tribe_space
  AFTER INSERT ON public.tribes
  FOR EACH ROW EXECUTE FUNCTION public.ensure_default_tribe_space();

CREATE OR REPLACE FUNCTION public.create_managed_tribe(
  p_name TEXT,
  p_category TEXT,
  p_description TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT 'public',
  p_tags TEXT[] DEFAULT '{}'::TEXT[],
  p_welcome_message TEXT DEFAULT NULL,
  p_settings JSONB DEFAULT '{}'::JSONB,
  p_rules JSONB DEFAULT '[]'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_tribe_id UUID;
  v_slug TEXT;
  v_item JSONB;
  v_position INT := 0;
  v_settings JSONB;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.users u
     WHERE u.user_id = v_me
       AND (
         u.user_role::TEXT IN ('plug', 'super_admin')
         OR EXISTS (
           SELECT 1 FROM public.plug_profiles pp
            WHERE pp.plug_id = v_me AND pp.approved_at IS NOT NULL
         )
       )
  ) THEN
    RAISE EXCEPTION 'plug_approval_required';
  END IF;
  IF char_length(btrim(COALESCE(p_name, ''))) NOT BETWEEN 3 AND 50 THEN
    RAISE EXCEPTION 'tribe_name_length';
  END IF;
  IF char_length(btrim(COALESCE(p_category, ''))) NOT BETWEEN 2 AND 40 THEN
    RAISE EXCEPTION 'tribe_category_length';
  END IF;
  IF p_description IS NOT NULL AND char_length(p_description) > 500 THEN
    RAISE EXCEPTION 'tribe_description_length';
  END IF;
  IF p_visibility NOT IN ('public', 'private', 'invite_only') THEN
    RAISE EXCEPTION 'invalid_visibility';
  END IF;
  IF cardinality(COALESCE(p_tags, '{}'::TEXT[])) > 8 THEN
    RAISE EXCEPTION 'too_many_tags';
  END IF;
  IF jsonb_typeof(COALESCE(p_rules, '[]'::JSONB)) <> 'array'
     OR jsonb_array_length(COALESCE(p_rules, '[]'::JSONB)) > 50 THEN
    RAISE EXCEPTION 'invalid_rules';
  END IF;

  v_slug := btrim(regexp_replace(lower(btrim(p_name)), '[^a-z0-9]+', '-', 'g'), '-');
  IF v_slug = '' THEN v_slug := 'tribe'; END IF;
  WHILE EXISTS (SELECT 1 FROM public.tribes WHERE slug = v_slug) LOOP
    v_slug := v_slug || '-' || substr(md5(random()::TEXT), 1, 5);
  END LOOP;
  v_settings := jsonb_build_object(
    'join_approval_required', FALSE,
    'minimum_account_age_days', 0,
    'post_approval_mode', 'off',
    'posting_permission', 'members',
    'slow_mode_seconds', 0,
    'allow_whispers', TRUE,
    'allow_polls', TRUE,
    'allow_anonymous_reactions', TRUE,
    'content_sensitivity_filter', 'standard',
    'show_content_when_paused', TRUE,
    'invite_links_enabled', TRUE
  ) || COALESCE(p_settings, '{}'::JSONB);

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
  IF COALESCE(v_settings->>'content_sensitivity_filter', 'standard') NOT IN ('off', 'standard', 'strict') THEN
    RAISE EXCEPTION 'invalid_sensitivity_filter';
  END IF;

  INSERT INTO public.tribes (
    name, slug, category, description, is_private, keeper_id,
    visibility, tags, welcome_message, settings, lifecycle_status, is_active
  ) VALUES (
    btrim(p_name), v_slug, btrim(p_category), NULLIF(btrim(p_description), ''),
    p_visibility <> 'public', v_me, p_visibility, COALESCE(p_tags, '{}'::TEXT[]),
    NULLIF(btrim(p_welcome_message), ''), v_settings, 'active', TRUE
  ) RETURNING tribe_id INTO v_tribe_id;

  INSERT INTO public.tribe_members (tribe_id, user_id, role)
  VALUES (v_tribe_id, v_me, 'keeper')
  ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = 'keeper';

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(COALESCE(p_rules, '[]'::JSONB))
  LOOP
    IF char_length(btrim(COALESCE(v_item->>'title', ''))) NOT BETWEEN 2 AND 100 THEN
      RAISE EXCEPTION 'invalid_rule_title';
    END IF;
    INSERT INTO public.tribe_rule_items (
      tribe_id, position, title, description, template_key, is_enabled, created_by
    ) VALUES (
      v_tribe_id, v_position, btrim(v_item->>'title'),
      NULLIF(btrim(v_item->>'description'), ''),
      NULLIF(v_item->>'template_key', ''),
      COALESCE((v_item->>'is_enabled')::BOOLEAN, TRUE),
      v_me
    );
    v_position := v_position + 1;
  END LOOP;

  IF v_position > 0 THEN
    UPDATE public.tribes
       SET rules = (
         SELECT string_agg((position + 1)::TEXT || '. ' || title, E'\n' ORDER BY position)
           FROM public.tribe_rule_items
          WHERE tribe_id = v_tribe_id AND is_enabled
       )
     WHERE tribe_id = v_tribe_id;
  END IF;
  PERFORM public.log_tribe_action(
    v_tribe_id,
    'TRIBE_CREATED',
    'tribe',
    v_tribe_id::TEXT,
    NULL,
    NULL,
    jsonb_build_object('name', btrim(p_name), 'visibility', p_visibility)
  );
  RETURN v_tribe_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_managed_tribe(TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_managed_tribe(TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, JSONB, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.replace_tribe_rules(p_tribe_id UUID, p_rules JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_item JSONB; v_position INT := 0;
BEGIN
  PERFORM public.require_tribe_owner(p_tribe_id);
  IF jsonb_typeof(COALESCE(p_rules, '[]'::JSONB)) <> 'array' OR jsonb_array_length(COALESCE(p_rules, '[]'::JSONB)) > 50 THEN
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
  PERFORM public.log_tribe_action(
    p_tribe_id, 'TRIBE_RULES_REPLACED', 'rules', p_tribe_id::TEXT,
    NULL, NULL, jsonb_build_object('count', v_position)
  );
  RETURN public.tribe_management_overview(p_tribe_id);
END;
$$;

REVOKE ALL ON FUNCTION public.replace_tribe_rules(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_tribe_rules(UUID, JSONB) TO authenticated;

-- -------------------------------------------------------------------------
-- 5. Membership requests and member administration
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_tribe_membership(p_tribe_id UUID, p_note TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_tribe public.tribes; v_requires_approval BOOLEAN; v_invited BOOLEAN;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = p_tribe_id FOR UPDATE;
  IF v_tribe.tribe_id IS NULL THEN RAISE EXCEPTION 'tribe_not_found'; END IF;
  IF v_tribe.lifecycle_status <> 'active' THEN RAISE EXCEPTION 'tribe_not_accepting_members'; END IF;
  IF EXISTS (SELECT 1 FROM public.tribe_bans b WHERE b.tribe_id = p_tribe_id AND b.user_id = v_me) THEN
    RAISE EXCEPTION 'member_banned';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tribe_members m WHERE m.tribe_id = p_tribe_id AND m.user_id = v_me) THEN
    RETURN 'joined';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM public.users u
     WHERE u.user_id = v_me
       AND u.created_at > now() - make_interval(
         days => COALESCE((v_tribe.settings->>'minimum_account_age_days')::INT, 0)
       )
  ) THEN
    RAISE EXCEPTION 'minimum_account_age_not_met';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.tribe_invites i
     WHERE i.tribe_id = p_tribe_id AND i.invited_user_id = v_me AND i.status = 'pending'
  ) INTO v_invited;
  v_requires_approval := COALESCE((v_tribe.settings->>'join_approval_required')::BOOLEAN, FALSE)
                         OR v_tribe.visibility IN ('private', 'invite_only');
  IF v_tribe.visibility = 'invite_only' AND NOT v_invited THEN
    RAISE EXCEPTION 'invite_required';
  END IF;
  IF v_requires_approval AND NOT v_invited THEN
    INSERT INTO public.tribe_join_requests (tribe_id, user_id, note, status, created_at, decided_at, decided_by)
    VALUES (p_tribe_id, v_me, NULLIF(btrim(p_note), ''), 'pending', now(), NULL, NULL)
    ON CONFLICT (tribe_id, user_id) DO UPDATE SET
      status = 'pending', note = EXCLUDED.note, created_at = now(), decided_at = NULL, decided_by = NULL;
    RETURN 'pending';
  END IF;
  INSERT INTO public.tribe_members (tribe_id, user_id, role)
  VALUES (p_tribe_id, v_me, 'member') ON CONFLICT DO NOTHING;
  UPDATE public.tribe_invites SET status = 'accepted', decided_at = now()
   WHERE tribe_id = p_tribe_id AND invited_user_id = v_me AND status = 'pending';
  RETURN 'joined';
END;
$$;

REVOKE ALL ON FUNCTION public.request_tribe_membership(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_tribe_membership(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.respond_tribe_join_request(p_request_id UUID, p_approve BOOLEAN, p_reason TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_request public.tribe_join_requests;
BEGIN
  SELECT * INTO v_request FROM public.tribe_join_requests WHERE request_id = p_request_id FOR UPDATE;
  IF v_request.request_id IS NULL THEN RAISE EXCEPTION 'join_request_not_found'; END IF;
  IF NOT public.can_manage_tribe(v_request.tribe_id) THEN RAISE EXCEPTION 'not_tribe_manager'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'join_request_already_decided'; END IF;
  UPDATE public.tribe_join_requests SET
    status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    decided_by = (SELECT auth.uid()), decided_at = now()
  WHERE request_id = p_request_id;
  IF p_approve THEN
    INSERT INTO public.tribe_members (tribe_id, user_id, role)
    VALUES (v_request.tribe_id, v_request.user_id, 'member') ON CONFLICT DO NOTHING;
  END IF;
  PERFORM public.log_tribe_action(
    v_request.tribe_id,
    CASE WHEN p_approve THEN 'JOIN_REQUEST_APPROVED' ELSE 'JOIN_REQUEST_REJECTED' END,
    'user', v_request.user_id::TEXT, p_reason
  );
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_tribe_join_request(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_tribe_join_request(UUID, BOOLEAN, TEXT) TO authenticated;

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
DECLARE v_actor_role TEXT; v_target_role TEXT;
BEGIN
  SELECT role INTO v_actor_role FROM public.tribe_members
   WHERE tribe_id = p_tribe_id AND user_id = (SELECT auth.uid());
  SELECT role INTO v_target_role FROM public.tribe_members
   WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
  IF v_actor_role NOT IN ('keeper', 'mod') THEN RAISE EXCEPTION 'not_tribe_manager'; END IF;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_target_role = 'keeper' THEN RAISE EXCEPTION 'cannot_manage_owner'; END IF;
  IF v_actor_role = 'mod' AND v_target_role = 'mod' THEN RAISE EXCEPTION 'owner_action_required'; END IF;
  IF p_action IN ('promote', 'demote') AND v_actor_role <> 'keeper' THEN RAISE EXCEPTION 'owner_action_required'; END IF;

  CASE p_action
    WHEN 'warn' THEN
      UPDATE public.tribe_members SET warning_count = warning_count + 1, last_warned_at = now()
       WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    WHEN 'mute' THEN
      UPDATE public.tribe_members SET muted_until = COALESCE(p_mute_until, now() + INTERVAL '24 hours')
       WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    WHEN 'unmute' THEN
      UPDATE public.tribe_members SET muted_until = NULL
       WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    WHEN 'promote' THEN
      UPDATE public.tribe_members SET role = 'mod'
       WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    WHEN 'demote' THEN
      UPDATE public.tribe_members SET role = 'member'
       WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    WHEN 'remove' THEN
      DELETE FROM public.tribe_members WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    WHEN 'ban' THEN
      INSERT INTO public.tribe_bans (tribe_id, user_id, reason, banned_by)
      VALUES (p_tribe_id, p_user_id, NULLIF(btrim(p_reason), ''), (SELECT auth.uid()))
      ON CONFLICT (tribe_id, user_id) DO UPDATE SET reason = EXCLUDED.reason, banned_by = EXCLUDED.banned_by, created_at = now();
      DELETE FROM public.tribe_members WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    ELSE RAISE EXCEPTION 'invalid_member_action';
  END CASE;

  PERFORM public.log_tribe_action(
    p_tribe_id, 'MEMBER_' || upper(p_action), 'user', p_user_id::TEXT, p_reason,
    jsonb_build_object('role', v_target_role), NULL,
    jsonb_build_object('mute_until', p_mute_until)
  );
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.manage_tribe_member(UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manage_tribe_member(UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;

-- -------------------------------------------------------------------------
-- 6. Ownership transfer and lifecycle authority
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.initiate_tribe_transfer(
  p_tribe_id UUID,
  p_to_user_id UUID,
  p_keep_previous_owner_as_mod BOOLEAN DEFAULT TRUE
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tribe public.tribes; v_transfer UUID;
BEGIN
  v_tribe := public.require_tribe_owner(p_tribe_id);
  IF p_to_user_id = (SELECT auth.uid()) THEN RAISE EXCEPTION 'cannot_transfer_to_self'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.tribe_members tm
     JOIN public.users u ON u.user_id = tm.user_id
    WHERE tm.tribe_id = p_tribe_id AND tm.user_id = p_to_user_id
      AND u.account_status = 'active'
  ) THEN RAISE EXCEPTION 'recipient_must_be_active_member'; END IF;
  UPDATE public.tribe_ownership_transfers SET status = 'cancelled', responded_at = now()
   WHERE tribe_id = p_tribe_id AND status = 'pending';
  INSERT INTO public.tribe_ownership_transfers (
    tribe_id, from_user_id, to_user_id, keep_previous_owner_as_mod
  ) VALUES (
    p_tribe_id, (SELECT auth.uid()), p_to_user_id, p_keep_previous_owner_as_mod
  ) RETURNING transfer_id INTO v_transfer;
  INSERT INTO public.notifications (user_id, kind, payload, is_read)
  VALUES (p_to_user_id, 'tribe_ownership_transfer', jsonb_build_object(
    'title', 'Tribe ownership request',
    'body', 'You were invited to become the Plug of ' || v_tribe.name,
    'tribe_id', p_tribe_id,
    'transfer_id', v_transfer
  ), FALSE);
  PERFORM public.log_tribe_action(
    p_tribe_id, 'OWNERSHIP_TRANSFER_INITIATED', 'user', p_to_user_id::TEXT,
    NULL, NULL, jsonb_build_object('keep_previous_owner_as_mod', p_keep_previous_owner_as_mod)
  );
  RETURN v_transfer;
END;
$$;

REVOKE ALL ON FUNCTION public.initiate_tribe_transfer(UUID, UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.initiate_tribe_transfer(UUID, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.respond_tribe_transfer(p_transfer_id UUID, p_accept BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_transfer public.tribe_ownership_transfers;
BEGIN
  SELECT * INTO v_transfer FROM public.tribe_ownership_transfers
   WHERE transfer_id = p_transfer_id FOR UPDATE;
  IF v_transfer.transfer_id IS NULL THEN RAISE EXCEPTION 'transfer_not_found'; END IF;
  IF v_transfer.to_user_id <> (SELECT auth.uid()) THEN RAISE EXCEPTION 'not_transfer_recipient'; END IF;
  IF v_transfer.status <> 'pending' OR v_transfer.expires_at <= now() THEN RAISE EXCEPTION 'transfer_not_pending'; END IF;
  IF p_accept THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tribes WHERE tribe_id = v_transfer.tribe_id AND keeper_id = v_transfer.from_user_id
    ) THEN RAISE EXCEPTION 'ownership_changed'; END IF;
    INSERT INTO public.tribe_members (tribe_id, user_id, role)
    VALUES (v_transfer.tribe_id, v_transfer.to_user_id, 'keeper')
    ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = 'keeper';
    UPDATE public.tribe_members SET role = CASE WHEN v_transfer.keep_previous_owner_as_mod THEN 'mod' ELSE 'member' END
     WHERE tribe_id = v_transfer.tribe_id AND user_id = v_transfer.from_user_id;
    UPDATE public.tribes SET keeper_id = v_transfer.to_user_id, updated_at = now()
     WHERE tribe_id = v_transfer.tribe_id;
  END IF;
  UPDATE public.tribe_ownership_transfers SET
    status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END,
    responded_at = now()
  WHERE transfer_id = p_transfer_id;
  PERFORM public.log_tribe_action(
    v_transfer.tribe_id,
    CASE WHEN p_accept THEN 'OWNERSHIP_TRANSFER_ACCEPTED' ELSE 'OWNERSHIP_TRANSFER_DECLINED' END,
    'user', v_transfer.to_user_id::TEXT
  );
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_tribe_transfer(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_tribe_transfer(UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_tribe_lifecycle(
  p_tribe_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT NULL,
  p_confirmed_name TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_before public.tribes; v_after public.tribes;
BEGIN
  v_before := public.require_tribe_owner(p_tribe_id);
  CASE p_action
    WHEN 'pause' THEN
      UPDATE public.tribes SET lifecycle_status = 'paused', paused_at = now(), archived_at = NULL,
        lifecycle_reason = NULLIF(btrim(p_reason), ''), is_active = FALSE, updated_at = now()
      WHERE tribe_id = p_tribe_id;
    WHEN 'activate' THEN
      UPDATE public.tribes SET lifecycle_status = 'active', paused_at = NULL, archived_at = NULL,
        deletion_requested_at = NULL, deletion_purge_at = NULL, lifecycle_reason = NULL,
        is_active = TRUE, updated_at = now()
      WHERE tribe_id = p_tribe_id;
    WHEN 'archive' THEN
      UPDATE public.tribes SET lifecycle_status = 'archived', archived_at = now(),
        lifecycle_reason = NULLIF(btrim(p_reason), ''), is_active = FALSE, updated_at = now()
      WHERE tribe_id = p_tribe_id;
    WHEN 'request_delete' THEN
      IF p_confirmed_name IS NULL OR btrim(p_confirmed_name) <> v_before.name THEN
        RAISE EXCEPTION 'tribe_name_confirmation_failed';
      END IF;
      UPDATE public.tribes SET lifecycle_status = 'pending_deletion', deletion_requested_at = now(),
        deletion_purge_at = now() + INTERVAL '30 days', lifecycle_reason = NULLIF(btrim(p_reason), ''),
        is_active = FALSE, updated_at = now()
      WHERE tribe_id = p_tribe_id;
    WHEN 'cancel_delete' THEN
      IF v_before.lifecycle_status <> 'pending_deletion' THEN RAISE EXCEPTION 'deletion_not_pending'; END IF;
      UPDATE public.tribes SET lifecycle_status = 'active', deletion_requested_at = NULL,
        deletion_purge_at = NULL, lifecycle_reason = NULL, is_active = TRUE, updated_at = now()
      WHERE tribe_id = p_tribe_id;
    ELSE RAISE EXCEPTION 'invalid_lifecycle_action';
  END CASE;
  SELECT * INTO v_after FROM public.tribes WHERE tribe_id = p_tribe_id;
  PERFORM public.log_tribe_action(
    p_tribe_id, 'TRIBE_' || upper(p_action), 'tribe', p_tribe_id::TEXT, p_reason,
    jsonb_build_object('status', v_before.lifecycle_status),
    jsonb_build_object('status', v_after.lifecycle_status, 'purge_at', v_after.deletion_purge_at)
  );
  RETURN public.tribe_management_overview(p_tribe_id);
END;
$$;

REVOKE ALL ON FUNCTION public.set_tribe_lifecycle(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_tribe_lifecycle(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- Super Admin recovery is deliberately separate from owner lifecycle actions.
-- It only works while the soft-deletion recovery window still exists.
CREATE OR REPLACE FUNCTION public.admin_restore_tribe(
  p_tribe_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_before public.tribes;
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin']) THEN
    RAISE EXCEPTION 'staff_required';
  END IF;
  SELECT * INTO v_before
    FROM public.tribes
   WHERE tribe_id = p_tribe_id
   FOR UPDATE;
  IF v_before.tribe_id IS NULL THEN RAISE EXCEPTION 'tribe_not_found'; END IF;
  IF v_before.lifecycle_status <> 'pending_deletion'
     OR v_before.deletion_purge_at IS NULL
     OR v_before.deletion_purge_at <= now() THEN
    RAISE EXCEPTION 'tribe_not_recoverable';
  END IF;
  UPDATE public.tribes
     SET lifecycle_status = 'active',
         deletion_requested_at = NULL,
         deletion_purge_at = NULL,
         lifecycle_reason = NULL,
         is_active = TRUE,
         updated_at = now()
   WHERE tribe_id = p_tribe_id;
  PERFORM public.log_tribe_action(
    p_tribe_id,
    'TRIBE_ADMIN_RESTORED',
    'tribe',
    p_tribe_id::TEXT,
    NULLIF(btrim(p_reason), ''),
    jsonb_build_object('status', v_before.lifecycle_status, 'purge_at', v_before.deletion_purge_at),
    jsonb_build_object('status', 'active')
  );
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_restore_tribe(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_restore_tribe(UUID, TEXT) TO authenticated;

-- Service-role/scheduled maintenance only. Tribe posts are soft-deleted first
-- so the existing ON DELETE SET NULL FK cannot leak them into the global feed.
CREATE OR REPLACE FUNCTION public.purge_due_tribes()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_count INT;
BEGIN
  UPDATE public.posts p SET deleted_at = COALESCE(p.deleted_at, now())
   WHERE p.tribe_id IN (
     SELECT t.tribe_id FROM public.tribes t
      WHERE t.lifecycle_status = 'pending_deletion' AND t.deletion_purge_at <= now()
   );
  WITH removed AS (
    DELETE FROM public.tribes
     WHERE lifecycle_status = 'pending_deletion' AND deletion_purge_at <= now()
     RETURNING tribe_id
  ) SELECT count(*)::INT INTO v_count FROM removed;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_due_tribes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_due_tribes() TO service_role;

-- -------------------------------------------------------------------------
-- 7. Space and content administration
-- -------------------------------------------------------------------------

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
  PERFORM public.require_tribe_owner(p_tribe_id);
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

REVOKE ALL ON FUNCTION public.manage_tribe_space(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manage_tribe_space(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated;

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
  IF v_role NOT IN ('keeper', 'mod') THEN RAISE EXCEPTION 'not_tribe_manager'; END IF;
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

REVOKE ALL ON FUNCTION public.manage_tribe_post(UUID, UUID, TEXT, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manage_tribe_post(UUID, UUID, TEXT, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.managed_tribe_posts(
  p_tribe_id UUID,
  p_limit INT DEFAULT 100
) RETURNS TABLE (
  post_id UUID,
  author_id UUID,
  author_pseudonym TEXT,
  author_avatar_seed TEXT,
  author_profile_photo_url TEXT,
  content TEXT,
  category_name TEXT,
  post_mood TEXT,
  space_id UUID,
  space_name TEXT,
  likes_count INT,
  comments_count INT,
  created_at TIMESTAMPTZ,
  is_approved BOOLEAN,
  is_pinned BOOLEAN,
  featured_at TIMESTAMPTZ,
  hidden_at TIMESTAMPTZ,
  locked_at TIMESTAMPTZ,
  sensitive_at TIMESTAMPTZ,
  archived_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_role TEXT;
BEGIN
  SELECT tm.role INTO v_role
    FROM public.tribe_members tm
   WHERE tm.tribe_id = p_tribe_id
     AND tm.user_id = (SELECT auth.uid());
  IF v_role NOT IN ('keeper', 'mod')
     AND NOT public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin', 'moderator']) THEN
    RAISE EXCEPTION 'not_tribe_manager';
  END IF;
  RETURN QUERY
  SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || persona.pseudonym::TEXT, '@' || u.anonymous_pseudonym::TEXT, '@anonymous'),
    COALESCE(persona.avatar_seed::TEXT, u.avatar_seed::TEXT, 'default-orb'),
    CASE WHEN p.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END,
    p.content,
    p.category_name::TEXT,
    p.post_mood::TEXT,
    p.space_id,
    s.name::TEXT,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.is_approved,
    EXISTS (
      SELECT 1 FROM public.tribe_pinned_posts pin
       WHERE pin.tribe_id = p_tribe_id AND pin.post_id = p.post_id
    ),
    p.featured_at,
    p.hidden_at,
    p.locked_at,
    p.sensitive_at,
    p.archived_at
  FROM public.posts p
  LEFT JOIN public.users u ON u.user_id = p.author_id
  LEFT JOIN public.personas persona
    ON persona.persona_id = p.persona_id AND persona.deleted_at IS NULL
  LEFT JOIN public.spaces s ON s.space_id = p.space_id
  WHERE p.tribe_id = p_tribe_id
    AND p.deleted_at IS NULL
  ORDER BY
    CASE WHEN NOT COALESCE(p.is_approved, TRUE) THEN 0 ELSE 1 END,
    p.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 250);
END;
$$;

REVOKE ALL ON FUNCTION public.managed_tribe_posts(UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.managed_tribe_posts(UUID, INT) TO authenticated;

-- A helpful-response highlight uses the existing single pinned comment.
-- The post author retains control, while Tribe managers can curate replies
-- inside communities they manage. Manager actions enter the Tribe audit log.
CREATE OR REPLACE FUNCTION public.pin_comment(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_post_id UUID; v_owner UUID; v_tribe_id UUID; v_manager BOOLEAN;
BEGIN
  SELECT c.post_id, p.author_id, p.tribe_id
    INTO v_post_id, v_owner, v_tribe_id
    FROM public.posts_comments c
    JOIN public.posts p ON p.post_id = c.post_id
   WHERE c.comment_id = p_comment_id;
  IF v_post_id IS NULL THEN RAISE EXCEPTION 'comment_not_found'; END IF;
  v_manager := v_tribe_id IS NOT NULL AND public.can_manage_tribe(v_tribe_id);
  IF v_owner <> (SELECT auth.uid()) AND NOT v_manager THEN
    RAISE EXCEPTION 'not_allowed_to_highlight_comment';
  END IF;
  UPDATE public.posts_comments SET pinned_at = NULL
   WHERE post_id = v_post_id AND pinned_at IS NOT NULL;
  UPDATE public.posts_comments SET pinned_at = now()
   WHERE comment_id = p_comment_id;
  IF v_manager THEN
    PERFORM public.log_tribe_action(
      v_tribe_id, 'COMMENT_HIGHLIGHTED', 'comment', p_comment_id::TEXT
    );
  END IF;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.unpin_comment(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_owner UUID; v_tribe_id UUID; v_manager BOOLEAN;
BEGIN
  SELECT p.author_id, p.tribe_id INTO v_owner, v_tribe_id
    FROM public.posts_comments c
    JOIN public.posts p ON p.post_id = c.post_id
   WHERE c.comment_id = p_comment_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'comment_not_found'; END IF;
  v_manager := v_tribe_id IS NOT NULL AND public.can_manage_tribe(v_tribe_id);
  IF v_owner <> (SELECT auth.uid()) AND NOT v_manager THEN
    RAISE EXCEPTION 'not_allowed_to_highlight_comment';
  END IF;
  UPDATE public.posts_comments SET pinned_at = NULL
   WHERE comment_id = p_comment_id;
  IF v_manager THEN
    PERFORM public.log_tribe_action(
      v_tribe_id, 'COMMENT_HIGHLIGHT_REMOVED', 'comment', p_comment_id::TEXT
    );
  END IF;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.pin_comment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unpin_comment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pin_comment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unpin_comment(UUID) TO authenticated;

-- -------------------------------------------------------------------------
-- 8. Enforcement guards and directory read model
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.guard_tribe_content_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_tribe public.tribes;
  v_role TEXT;
  v_joined_at TIMESTAMPTZ;
  v_slow_mode INT;
  v_approval_mode TEXT;
  v_space public.spaces;
BEGIN
  IF NEW.tribe_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO v_tribe FROM public.tribes WHERE tribe_id = NEW.tribe_id;
  IF v_tribe.tribe_id IS NULL THEN RAISE EXCEPTION 'tribe_not_found'; END IF;
  IF v_tribe.lifecycle_status <> 'active' THEN RAISE EXCEPTION 'tribe_is_read_only'; END IF;
  SELECT role, joined_at INTO v_role, v_joined_at FROM public.tribe_members
   WHERE tribe_id = NEW.tribe_id AND user_id = v_me;
  IF v_tribe.keeper_id = v_me THEN
    v_role := 'keeper';
    v_joined_at := COALESCE(v_joined_at, v_tribe.created_at, now());
  END IF;
  IF v_role IS NULL THEN RAISE EXCEPTION 'tribe_membership_required'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.tribe_members tm
     WHERE tm.tribe_id = NEW.tribe_id
       AND tm.user_id = v_me
       AND tm.muted_until > now()
  ) THEN
    RAISE EXCEPTION 'member_is_muted';
  END IF;
  IF COALESCE(v_tribe.settings->>'posting_permission', 'members') = 'mods'
     AND v_role NOT IN ('keeper', 'mod') THEN RAISE EXCEPTION 'posting_restricted'; END IF;
  IF COALESCE(v_tribe.settings->>'posting_permission', 'members') = 'keeper'
     AND v_role <> 'keeper' THEN RAISE EXCEPTION 'posting_restricted'; END IF;
  IF NEW.space_id IS NOT NULL THEN
    SELECT * INTO v_space FROM public.spaces
     WHERE space_id = NEW.space_id AND tribe_id = NEW.tribe_id;
    IF v_space.space_id IS NULL THEN RAISE EXCEPTION 'space_not_found'; END IF;
    IF v_space.archived_at IS NOT NULL
       OR (v_space.activates_at IS NOT NULL AND v_space.activates_at > now())
       OR (v_space.deactivates_at IS NOT NULL AND v_space.deactivates_at <= now()) THEN
      RAISE EXCEPTION 'space_is_read_only';
    END IF;
    IF v_space.posting_permission = 'read_only'
       OR (v_space.posting_permission = 'mods' AND v_role NOT IN ('keeper', 'mod'))
       OR (v_space.posting_permission = 'keeper' AND v_role <> 'keeper') THEN
      RAISE EXCEPTION 'space_posting_restricted';
    END IF;
  END IF;
  v_slow_mode := COALESCE((v_tribe.settings->>'slow_mode_seconds')::INT, 0);
  IF v_slow_mode > 0 AND v_role NOT IN ('keeper', 'mod') AND EXISTS (
    SELECT 1 FROM public.posts recent
     WHERE recent.tribe_id = NEW.tribe_id
       AND recent.author_id = v_me
       AND recent.deleted_at IS NULL
       AND recent.created_at > now() - make_interval(secs => v_slow_mode)
  ) THEN
    RAISE EXCEPTION 'tribe_slow_mode_active';
  END IF;
  v_approval_mode := COALESCE(v_tribe.settings->>'post_approval_mode', 'off');
  IF v_role NOT IN ('keeper', 'mod') THEN
    IF v_approval_mode = 'all'
       OR (v_approval_mode = 'new_members' AND v_joined_at > now() - INTERVAL '7 days') THEN
      NEW.is_approved := FALSE;
    END IF;
  END IF;
  IF NEW.is_whisper AND NOT COALESCE((v_tribe.settings->>'allow_whispers')::BOOLEAN, TRUE) THEN
    RAISE EXCEPTION 'whispers_disabled';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_tribe_content_write ON public.posts;
CREATE TRIGGER guard_tribe_content_write
  BEFORE INSERT ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.guard_tribe_content_write();

-- Centralize Tribe content visibility in a SECURITY DEFINER predicate so
-- archived rows cannot become visible merely because Tribe RLS hides the
-- parent row from a correlated posts policy.
CREATE OR REPLACE FUNCTION public.can_read_tribe_content(
  p_tribe_id UUID,
  p_viewer_id UUID DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_tribe_id IS NULL OR EXISTS (
    SELECT 1
      FROM public.tribes t
     WHERE t.tribe_id = p_tribe_id
       AND (
         (
           t.visibility = 'public'
           AND (
             t.lifecycle_status = 'active'
             OR (
               t.lifecycle_status = 'paused'
               AND COALESCE((t.settings->>'show_content_when_paused')::BOOLEAN, TRUE)
             )
           )
         )
         OR t.keeper_id = p_viewer_id
         OR EXISTS (
           SELECT 1
             FROM public.tribe_members m
           WHERE m.tribe_id = t.tribe_id
              AND m.user_id = p_viewer_id
              AND NOT EXISTS (
                SELECT 1
                  FROM public.tribe_bans b
                 WHERE b.tribe_id = m.tribe_id
                   AND b.user_id = m.user_id
              )
         )
         OR public.is_staff(p_viewer_id, ARRAY['super_admin', 'admin', 'moderator'])
       )
  );
$$;

REVOKE ALL ON FUNCTION public.can_read_tribe_content(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_read_tribe_content(UUID, UUID) TO anon, authenticated;

-- Pending approvals are visible to the author, Tribe managers, and staff,
-- but never leak into the public feed before review.
DROP POLICY IF EXISTS "posts readable" ON public.posts;
CREATE POLICY "posts readable"
  ON public.posts FOR SELECT
  TO anon, authenticated
  USING (
    deleted_at IS NULL
    AND (SELECT private.can_view_post_author(author_id))
    AND (
      COALESCE(is_approved, TRUE)
      OR author_id = (SELECT auth.uid())
      OR public.can_manage_tribe(tribe_id)
      OR public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin', 'moderator'])
    )
    AND (
      (hidden_at IS NULL AND archived_at IS NULL)
      OR author_id = (SELECT auth.uid())
      OR public.can_manage_tribe(tribe_id)
      OR public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin', 'moderator'])
    )
    AND (
      public.can_read_tribe_content(tribe_id, (SELECT auth.uid()))
    )
  );

-- Public directory hides archived/deletion-pending communities from
-- non-members while keeping paused tribes visible with a clear status.
DROP POLICY IF EXISTS "tribes readable" ON public.tribes;
CREATE POLICY "tribes readable"
  ON public.tribes FOR SELECT
  USING (
    (
      lifecycle_status IN ('active', 'paused')
      AND visibility = 'public'
    )
    OR keeper_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.tribe_members m
       WHERE m.tribe_id = tribes.tribe_id AND m.user_id = (SELECT auth.uid())
    )
    OR public.is_staff((SELECT auth.uid()), ARRAY['super_admin', 'admin'])
  );

CREATE OR REPLACE VIEW public.tribe_directory
WITH (security_invoker = true)
AS
SELECT
  t.tribe_id,
  t.name,
  t.slug,
  t.description,
  t.category,
  t.member_count,
  t.is_private,
  t.created_at,
  t.rules,
  t.avatar_url,
  t.banner_url,
  t.is_featured,
  t.is_suspended,
  t.keeper_id,
  u.anonymous_pseudonym AS keeper_pseudonym,
  u.avatar_seed AS keeper_avatar_seed,
  u.is_verified AS keeper_is_verified,
  u.karma_points AS keeper_karma,
  t.welcome_message,
  t.theme_color,
  t.spotlight_user_id,
  sp.anonymous_pseudonym AS spotlight_pseudonym,
  sp.avatar_seed AS spotlight_avatar_seed,
  t.spotlight_note,
  t.spotlight_set_at,
  t.chat_settings,
  t.pinned_message_id,
  u.profile_photo_url AS keeper_profile_photo_url,
  sp.profile_photo_url AS spotlight_profile_photo_url,
  t.lifecycle_status,
  t.visibility,
  t.tags,
  t.paused_at,
  t.archived_at,
  t.deletion_requested_at,
  t.deletion_purge_at,
  t.lifecycle_reason,
  t.settings
FROM public.tribes t
LEFT JOIN public.users u ON u.user_id = t.keeper_id
LEFT JOIN public.users sp ON sp.user_id = t.spotlight_user_id;

GRANT SELECT ON public.tribe_directory TO anon, authenticated;

-- Keep the denormalized Space directory current with management fields.
CREATE OR REPLACE VIEW public.space_directory
WITH (security_invoker = true) AS
SELECT s.space_id,
       s.tribe_id,
       t.slug AS tribe_slug,
       t.name AS tribe_name,
       s.slug,
       s.name,
       s.description,
       s.weekly_theme,
       s.theme_color,
       s.is_default,
       s.archived_at,
       s.created_at,
       s.updated_at,
       (SELECT COUNT(*) FROM public.posts p WHERE p.space_id = s.space_id AND p.deleted_at IS NULL)::INT AS vent_count,
       (SELECT COUNT(*) FROM public.posts p WHERE p.space_id = s.space_id AND p.deleted_at IS NULL AND p.created_at > now() - INTERVAL '24 hours')::INT AS vents_today,
       (SELECT MAX(p.created_at) FROM public.posts p WHERE p.space_id = s.space_id AND p.deleted_at IS NULL) AS last_vent_at,
       s.icon_name,
       s.is_pinned,
       s.posting_permission,
       s.activates_at,
       s.deactivates_at
  FROM public.spaces s
  JOIN public.tribes t ON t.tribe_id = s.tribe_id;

GRANT SELECT ON public.space_directory TO authenticated;

COMMENT ON TABLE public.tribe_audit_log IS
  'Immutable keeper/admin audit trail for sensitive Tribe management actions.';
COMMENT ON FUNCTION public.set_tribe_lifecycle(UUID, TEXT, TEXT, TEXT) IS
  'Owner-only lifecycle state machine. request_delete starts a 30-day recovery window.';

NOTIFY pgrst, 'reload schema';
