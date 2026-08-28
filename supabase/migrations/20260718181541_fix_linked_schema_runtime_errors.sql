-- Repair runtime functions reported by `supabase db lint --linked`.
-- Keep signatures stable so existing Flutter and admin-console clients do not
-- need a coordinated release.

CREATE OR REPLACE FUNCTION public.start_chat_room(
  p_target UUID,
  p_preview TEXT,
  p_origin_post_id UUID DEFAULT NULL
) RETURNS TABLE (
  room_id UUID,
  request_preview TEXT,
  room_status TEXT,
  created_at TIMESTAMPTZ,
  initiated_by_me BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_row public.chat_rooms%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_target IS NULL OR p_target = v_me THEN
    RAISE EXCEPTION 'invalid target';
  END IF;
  IF NOT public.can_dm(p_target) THEN
    RAISE EXCEPTION 'DM blocked: send a friend request first';
  END IF;

  SELECT cr.* INTO v_row
    FROM public.chat_rooms AS cr
   WHERE (cr.initiated_by = v_me AND cr.received_by = p_target)
      OR (cr.initiated_by = p_target AND cr.received_by = v_me)
   ORDER BY cr.created_at ASC
   LIMIT 1;

  IF FOUND THEN
    IF v_row.room_status = 'declined' THEN
      UPDATE public.chat_rooms AS cr
         SET room_status = 'active', updated_at = now()
       WHERE cr.room_id = v_row.room_id
       RETURNING cr.* INTO v_row;
    END IF;
    room_id := v_row.room_id;
    request_preview := v_row.request_preview;
    room_status := v_row.room_status;
    created_at := v_row.created_at;
    initiated_by_me := v_row.initiated_by = v_me;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO public.chat_rooms (
    initiated_by, received_by, origin_post_id, request_preview, room_status
  ) VALUES (
    v_me, p_target, p_origin_post_id, p_preview, 'active'
  ) RETURNING * INTO v_row;

  room_id := v_row.room_id;
  request_preview := v_row.request_preview;
  room_status := v_row.room_status;
  created_at := v_row.created_at;
  initiated_by_me := TRUE;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.start_chat_room(UUID, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_chat_room(UUID, TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.friend_suggestions(p_limit INT DEFAULT 6)
RETURNS TABLE (
  user_id UUID,
  pseudonym TEXT,
  avatar_seed TEXT,
  profile_photo_url TEXT,
  is_verified BOOLEAN,
  shared_tribes INT,
  rationale TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  RETURN QUERY
  WITH my_tribes AS (
    SELECT tm.tribe_id
      FROM public.tribe_members AS tm
     WHERE tm.user_id = v_me
  ),
  my_blocks AS (
    SELECT ub.blocked_id AS other_id
      FROM public.user_blocks AS ub
     WHERE ub.blocker_id = v_me
    UNION
    SELECT ub.blocker_id AS other_id
      FROM public.user_blocks AS ub
     WHERE ub.blocked_id = v_me
  ),
  my_friends AS (
    SELECT CASE WHEN f.user_a = v_me THEN f.user_b ELSE f.user_a END AS other_id
      FROM public.friendships AS f
     WHERE f.status IN ('accepted', 'pending')
       AND (f.user_a = v_me OR f.user_b = v_me)
  ),
  eligible AS (
    SELECT u.user_id,
           u.anonymous_pseudonym,
           u.avatar_seed,
           u.profile_photo_url,
           COALESCE(u.is_verified, FALSE) AS is_verified,
           COALESCE(u.karma_points, 0) AS karma_points,
           COALESCE(u.connections_count, 0) AS connections_count
      FROM public.users AS u
     WHERE u.user_id <> v_me
       AND u.account_status = 'active'
       AND u.deactivated_at IS NULL
       AND COALESCE(u.safety_tier, 'standard') <> 'restricted_minor'
       AND NOT EXISTS (
         SELECT 1 FROM my_friends AS f WHERE f.other_id = u.user_id
       )
       AND NOT EXISTS (
         SELECT 1 FROM my_blocks AS b WHERE b.other_id = u.user_id
       )
  ),
  shared AS (
    SELECT tm.user_id, COUNT(DISTINCT tm.tribe_id)::INT AS shared_tribes
      FROM public.tribe_members AS tm
     WHERE tm.tribe_id IN (SELECT mt.tribe_id FROM my_tribes AS mt)
     GROUP BY tm.user_id
  )
  SELECT e.user_id,
         e.anonymous_pseudonym::TEXT,
         COALESCE(e.avatar_seed, 'default-orb')::TEXT,
         e.profile_photo_url::TEXT,
         e.is_verified,
         COALESCE(s.shared_tribes, 0)::INT,
         CASE
           WHEN COALESCE(s.shared_tribes, 0) = 1 THEN '1 Mutual Tribe'
           WHEN COALESCE(s.shared_tribes, 0) > 1
             THEN s.shared_tribes::TEXT || ' Mutual Tribes'
           WHEN e.is_verified THEN 'Verified - trending'
           ELSE 'Trending on Venttly'
         END::TEXT
    FROM eligible AS e
    LEFT JOIN shared AS s ON s.user_id = e.user_id
   ORDER BY COALESCE(s.shared_tribes, 0) DESC,
            e.is_verified DESC,
            (e.karma_points + e.connections_count * 5) DESC,
            e.user_id
   LIMIT GREATEST(1, LEAST(p_limit, 20));
END;
$$;

REVOKE ALL ON FUNCTION public.friend_suggestions(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_suggestions(INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_new_user_retention(p_weeks INT DEFAULT 6)
RETURNS TABLE (
  cohort_week DATE,
  cohort_size INT,
  week_offset INT,
  retained INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_staff(
    auth.uid(), ARRAY['super_admin', 'admin', 'analyst', 'read_only_auditor']
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  WITH weeks AS (
    SELECT GREATEST(1, LEAST(p_weeks, 12)) AS week_count
  ),
  cohorts AS (
    SELECT u.user_id,
           date_trunc('week', u.created_at)::DATE AS joined_week
      FROM public.users AS u
      CROSS JOIN weeks AS w
     WHERE u.created_at >= date_trunc('week', now())
           - ((w.week_count - 1) * INTERVAL '1 week')
  ),
  cohort_sizes AS (
    SELECT c.joined_week, COUNT(*)::INT AS member_count
      FROM cohorts AS c
     GROUP BY c.joined_week
  ),
  user_weeks AS (
    SELECT DISTINCT uad.user_id AS active_user_id,
           date_trunc('week', uad.day)::DATE AS active_week
      FROM public.user_active_days AS uad
     WHERE uad.user_id IN (SELECT c.user_id FROM cohorts AS c)
  ),
  retention AS (
    SELECT c.joined_week,
           ((uw.active_week - c.joined_week) / 7)::INT AS offset_weeks,
           COUNT(DISTINCT c.user_id)::INT AS retained_count
      FROM cohorts AS c
      JOIN user_weeks AS uw
        ON uw.active_user_id = c.user_id
       AND uw.active_week >= c.joined_week
     GROUP BY c.joined_week, offset_weeks
  )
  SELECT cs.joined_week,
         cs.member_count,
         r.offset_weeks,
         r.retained_count
    FROM cohort_sizes AS cs
    JOIN retention AS r ON r.joined_week = cs.joined_week
   WHERE r.offset_weeks >= 0
     AND r.offset_weeks < (SELECT w.week_count FROM weeks AS w)
   ORDER BY cs.joined_week, r.offset_weeks;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_new_user_retention(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_new_user_retention(INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_recent_ips(p_limit INT DEFAULT 100)
RETURNS TABLE (
  ip TEXT,
  user_id UUID,
  pseudonym TEXT,
  last_seen TIMESTAMPTZ,
  session_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin']) THEN
    RAISE EXCEPTION 'forbidden: super_admin only';
  END IF;
  RETURN QUERY
  SELECT host(s.ip)::TEXT,
         s.user_id,
         u.anonymous_pseudonym::TEXT,
         MAX(s.updated_at),
         COUNT(*)::BIGINT
    FROM auth.sessions AS s
    LEFT JOIN public.users AS u ON u.user_id = s.user_id
   WHERE s.ip IS NOT NULL
   GROUP BY host(s.ip)::TEXT, s.user_id, u.anonymous_pseudonym
   ORDER BY MAX(s.updated_at) DESC NULLS LAST
   LIMIT GREATEST(1, LEAST(p_limit, 500));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_recent_ips(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_recent_ips(INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_update_user_profile(
  p_target UUID,
  p_pseudonym TEXT DEFAULT NULL,
  p_is_verified BOOLEAN DEFAULT NULL,
  p_safety_tier TEXT DEFAULT NULL,
  p_home_city TEXT DEFAULT NULL,
  p_home_country TEXT DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before JSONB;
  v_after JSONB;
  v_label TEXT;
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin', 'admin']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT to_jsonb(u), '@' || u.anonymous_pseudonym
    INTO v_before, v_label
    FROM public.users AS u
   WHERE u.user_id = p_target;
  IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

  IF p_pseudonym IS NOT NULL AND length(btrim(p_pseudonym)) < 3 THEN
    RAISE EXCEPTION 'pseudonym must be at least 3 characters';
  END IF;

  UPDATE public.users AS u
     SET anonymous_pseudonym = COALESCE(
           NULLIF(btrim(p_pseudonym), ''), u.anonymous_pseudonym
         ),
         is_verified = COALESCE(p_is_verified, u.is_verified),
         safety_tier = COALESCE(
           NULLIF(p_safety_tier, '')::public.safety_tier_type, u.safety_tier
         ),
         home_city = COALESCE(p_home_city, u.home_city),
         home_country = COALESCE(p_home_country, u.home_country),
         updated_at = now()
   WHERE u.user_id = p_target;

  SELECT to_jsonb(u) INTO v_after
    FROM public.users AS u
   WHERE u.user_id = p_target;

  PERFORM public.admin_log(
    'user.edit_profile', 'user', p_target, v_label,
    v_before, v_after, p_reason, '{}'::JSONB
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_user_profile(
  UUID, TEXT, BOOLEAN, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_user_profile(
  UUID, TEXT, BOOLEAN, TEXT, TEXT, TEXT, TEXT
) TO authenticated;

CREATE OR REPLACE FUNCTION public.search_suggestions(
  p_prefix TEXT,
  p_limit INT DEFAULT 8
) RETURNS TABLE (kind TEXT, value TEXT, display TEXT)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_q TEXT := trim(COALESCE(p_prefix, ''));
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 8), 1), 20);
BEGIN
  IF length(v_q) < 2 THEN RETURN; END IF;
  RETURN QUERY
  (
    SELECT 'user'::TEXT,
           u.anonymous_pseudonym::TEXT,
           ('@' || u.anonymous_pseudonym)::TEXT
      FROM public.users AS u
     WHERE u.deactivated_at IS NULL
       AND u.shadow_banned IS NOT TRUE
       AND (
         u.anonymous_pseudonym ILIKE v_q || '%'
         OR public.similarity(u.anonymous_pseudonym::TEXT, v_q) > 0.3
       )
     ORDER BY public.similarity(u.anonymous_pseudonym::TEXT, v_q) DESC
     LIMIT v_limit
  )
  UNION ALL
  (
    SELECT 'tribe'::TEXT, t.slug::TEXT, t.name::TEXT
      FROM public.tribes AS t
     WHERE t.name ILIKE v_q || '%'
        OR public.similarity(t.name::TEXT, v_q) > 0.3
     ORDER BY public.similarity(t.name::TEXT, v_q) DESC
     LIMIT v_limit
  )
  UNION ALL
  (
    SELECT DISTINCT 'category'::TEXT,
           p.category_name::TEXT,
           initcap(replace(p.category_name, '_', ' '))::TEXT
      FROM public.posts AS p
     WHERE p.category_name ILIKE v_q || '%'
     LIMIT 3
  )
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.search_suggestions(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_suggestions(TEXT, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_threaded_comment(
  p_post_id UUID,
  p_parent_id UUID,
  p_author_id UUID,
  p_content TEXT,
  p_persona_id UUID DEFAULT NULL,
  p_image_url TEXT DEFAULT NULL,
  p_image_path TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  new_id UUID := pg_catalog.gen_random_uuid();
  new_label TEXT := replace(new_id::TEXT, '-', '');
  parent_path public.ltree;
  new_path public.ltree;
BEGIN
  IF auth.uid() IS NULL OR p_author_id <> auth.uid() THEN
    RAISE EXCEPTION 'author_mismatch';
  END IF;

  IF p_persona_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
      FROM public.personas AS persona
     WHERE persona.persona_id = p_persona_id
       AND persona.user_id = p_author_id
       AND persona.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'persona not owned by author';
  END IF;

  IF btrim(COALESCE(p_content, '')) = ''
     AND COALESCE(p_image_url, '') = '' THEN
    RAISE EXCEPTION 'empty comment';
  END IF;

  IF p_parent_id IS NULL THEN
    new_path := public.text2ltree(new_label);
  ELSE
    SELECT c.path INTO parent_path
      FROM public.posts_comments AS c
     WHERE c.comment_id = p_parent_id;
    IF parent_path IS NULL THEN RAISE EXCEPTION 'parent comment not found'; END IF;
    new_path := parent_path || public.text2ltree(new_label);
  END IF;

  INSERT INTO public.posts_comments (
    comment_id, post_id, parent_id, author_id, content, path,
    persona_id, image_url, image_path
  ) VALUES (
    new_id, p_post_id, p_parent_id, p_author_id, COALESCE(p_content, ''),
    new_path, p_persona_id, p_image_url, p_image_path
  );
  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_threaded_comment(
  UUID, UUID, UUID, TEXT, UUID, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_threaded_comment(
  UUID, UUID, UUID, TEXT, UUID, TEXT, TEXT
) TO authenticated;

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

  IF v_actor_role NOT IN ('keeper', 'mod') THEN RAISE EXCEPTION 'not_tribe_manager'; END IF;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_target_role = 'keeper' THEN RAISE EXCEPTION 'cannot_manage_owner'; END IF;
  IF v_actor_role = 'mod' AND v_target_role = 'mod' THEN RAISE EXCEPTION 'owner_action_required'; END IF;
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

REVOKE ALL ON FUNCTION public.manage_tribe_member(
  UUID, UUID, TEXT, TEXT, TIMESTAMPTZ
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manage_tribe_member(
  UUID, UUID, TEXT, TEXT, TIMESTAMPTZ
) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_safety_queue(
  p_include_resolved BOOLEAN DEFAULT FALSE,
  p_limit INT DEFAULT 200
) RETURNS TABLE (
  item_type TEXT,
  severity TEXT,
  severity_rank INT,
  ref_id UUID,
  report_id UUID,
  reason TEXT,
  note TEXT,
  author_id UUID,
  author_pseudonym TEXT,
  preview TEXT,
  is_open BOOLEAN,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_staff(
    auth.uid(), ARRAY['super_admin', 'admin', 'moderator', 'support']
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  WITH items (
    item_type, severity, severity_rank, ref_id, report_id, reason, note,
    author_id, author_pseudonym, preview, is_open, created_at
  ) AS (
    SELECT 'crisis_post'::TEXT,
           p.crisis_level::TEXT,
           CASE p.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           p.post_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           p.author_id, u.anonymous_pseudonym::TEXT,
           left(COALESCE(p.content, ''), 200)::TEXT,
           p.deleted_at IS NULL, p.created_at
      FROM public.posts AS p
      LEFT JOIN public.users AS u ON u.user_id = p.author_id
     WHERE p.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_whisper'::TEXT,
           w.crisis_level::TEXT,
           CASE w.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           w.whisper_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           w.author_id, u.anonymous_pseudonym::TEXT,
           left(COALESCE(w.title, w.description, 'Voice whisper'), 200)::TEXT,
           w.deleted_at IS NULL, w.created_at
      FROM public.whispers AS w
      LEFT JOIN public.users AS u ON u.user_id = w.author_id
     WHERE w.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_tribe_message'::TEXT,
           tm.crisis_level::TEXT,
           CASE tm.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           tm.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           tm.sender_id, u.anonymous_pseudonym::TEXT,
           left(COALESCE(tm.content, ''), 200)::TEXT,
           tm.deleted_at IS NULL, tm.created_at
      FROM public.tribe_messages AS tm
      LEFT JOIN public.users AS u ON u.user_id = tm.sender_id
     WHERE tm.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_dm'::TEXT,
           cm.crisis_level::TEXT,
           CASE cm.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           cm.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           cm.sender_id, u.anonymous_pseudonym::TEXT,
           '(private DM - server-readable; access restricted)'::TEXT,
           TRUE, cm.created_at
      FROM public.chat_messages AS cm
      LEFT JOIN public.users AS u ON u.user_id = cm.sender_id
     WHERE cm.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'self_harm_report'::TEXT,
           'high'::TEXT,
           3,
           r.report_id,
           r.report_id,
           r.reason::TEXT,
           r.note::TEXT,
           COALESCE(p.author_id, tm.sender_id, cm.sender_id),
           COALESCE(
             pu.anonymous_pseudonym,
             tmu.anonymous_pseudonym,
             cmu.anonymous_pseudonym
           )::TEXT,
           COALESCE(
             left(p.content, 200),
             left(tm.content, 200),
             CASE WHEN r.target_chat_message_id IS NOT NULL
               THEN '(private DM - server-readable; access restricted)' END,
             CASE WHEN r.target_comment_id IS NOT NULL
               THEN '(reported comment)' END,
             CASE WHEN r.target_room_id IS NOT NULL
               THEN '(reported conversation)' END,
             '(reported content)'
           )::TEXT,
           NOT r.is_resolved,
           r.created_at
      FROM public.reports AS r
      LEFT JOIN public.posts AS p ON p.post_id = r.post_id
      LEFT JOIN public.users AS pu ON pu.user_id = p.author_id
      LEFT JOIN public.tribe_messages AS tm
        ON tm.message_id = r.target_tribe_message_id
      LEFT JOIN public.users AS tmu ON tmu.user_id = tm.sender_id
      LEFT JOIN public.chat_messages AS cm
        ON cm.message_id = r.target_chat_message_id
      LEFT JOIN public.users AS cmu ON cmu.user_id = cm.sender_id
     WHERE r.reason = 'self_harm'
  )
  SELECT i.*
    FROM items AS i
   WHERE p_include_resolved OR i.is_open
   ORDER BY i.is_open DESC, i.severity_rank DESC, i.created_at DESC
   LIMIT GREATEST(1, LEAST(p_limit, 1000));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_safety_queue(BOOLEAN, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_safety_queue(BOOLEAN, INT) TO authenticated;

-- A moderator must still manage the selected post after the update. The old
-- WITH CHECK (TRUE) allowed changing post_id to a report outside their tribe.
DROP POLICY IF EXISTS "reports mod update" ON public.reports;
CREATE POLICY "reports mod update"
ON public.reports
FOR UPDATE
USING (
  post_id IS NOT NULL
  AND EXISTS (
    SELECT 1
      FROM public.posts AS p
      JOIN public.tribe_members AS tm ON tm.tribe_id = p.tribe_id
     WHERE p.post_id = reports.post_id
       AND tm.user_id = (SELECT auth.uid())
       AND tm.role IN ('mod', 'keeper')
  )
)
WITH CHECK (
  post_id IS NOT NULL
  AND EXISTS (
    SELECT 1
      FROM public.posts AS p
      JOIN public.tribe_members AS tm ON tm.tribe_id = p.tribe_id
     WHERE p.post_id = reports.post_id
       AND tm.user_id = (SELECT auth.uid())
       AND tm.role IN ('mod', 'keeper')
  )
);

-- These buckets are public, so object URLs remain readable without a broad
-- SELECT policy. Removing list access prevents enumeration of every user's
-- media while preserving uploads through the existing owner policies.
DROP POLICY IF EXISTS "post media public read" ON storage.objects;
DROP POLICY IF EXISTS "tribe chat media public read" ON storage.objects;
DROP POLICY IF EXISTS "whispers media public read" ON storage.objects;

-- Freeze the lookup path of application-owned functions that still inherit a
-- role-mutable path. Preserve `extensions` for existing pgcrypto/uuid calls.
DO $$
DECLARE
  v_function REGPROCEDURE;
BEGIN
  FOR v_function IN
    SELECT p.oid::REGPROCEDURE
      FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = ANY (ARRAY[
         'trg_inc_tribe_member_count',
         'trg_dec_tribe_member_count',
         'trg_inc_author_karma',
         'trg_dec_author_karma',
         'trg_tribe_keeper_badge',
         'trg_notify_tribe_invite',
         'trg_stamp_location_bucket',
         'trg_block_banned_joins',
         'trg_post_events',
         'trg_like_events',
         'trg_comment_events',
         '_venttly_age_decay',
         'trg_validate_post_persona',
         'trg_reject_locked_comments',
         '_guard_write',
         'audit_log_immutable',
         'is_staff',
         'friendship_pair',
         'has_block',
         'is_tribe_keeper_or_mod',
         'is_tribe_keeper',
         '_bump_post_view_count',
         'enforce_blocked_media',
         'recompute_tribe_member_count',
         'sanitize_user_text'
       ])
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %s SET search_path TO public, extensions, pg_temp',
      v_function
    );
  END LOOP;
END;
$$;

-- Trigger functions and underscore-prefixed SECURITY DEFINER helpers are
-- internal implementation details, never client RPCs. Trigger execution does
-- not depend on these grants; revoking them closes an unnecessary API surface.
DO $$
DECLARE
  v_function REGPROCEDURE;
BEGIN
  FOR v_function IN
    SELECT p.oid::REGPROCEDURE
      FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosecdef
       AND (
         p.prorettype = 'trigger'::REGTYPE
         OR p.proname LIKE '\_%' ESCAPE '\'
       )
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',
      v_function
    );
  END LOOP;
END;
$$;

NOTIFY pgrst, 'reload schema';
