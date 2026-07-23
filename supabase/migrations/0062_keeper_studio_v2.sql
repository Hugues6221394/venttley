-- 0062_keeper_studio_v2.sql
--
-- Plugz Creator Studio V2 — authoritative keeper mode + studio RPCs.
-- Development accounts and communities belong in explicit local seed files;
-- schema migrations must never create or promote runtime identities.

-- =========================================================================
-- 1) Helpers
-- =========================================================================
CREATE OR REPLACE FUNCTION public.can_manage_tribe(p_tribe UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = p_tribe AND t.keeper_id = auth.uid()
    ) OR EXISTS (
        SELECT 1 FROM tribe_members tm
         WHERE tm.tribe_id = p_tribe AND tm.user_id = auth.uid()
           AND tm.role IN ('keeper', 'mod')
    );
$$;

GRANT EXECUTE ON FUNCTION public.can_manage_tribe(UUID) TO authenticated;

-- Authoritative keeper-mode flag for the client shell.
CREATE OR REPLACE FUNCTION public.is_keeper_mode()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_role TEXT;
    v_kept INT;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object(
            'is_keeper', false,
            'display_role', 'guest',
            'user_role', null,
            'tribes_kept', 0
        );
    END IF;

    SELECT u.user_role::text INTO v_role FROM users u WHERE u.user_id = v_me;
    SELECT count(*)::INT INTO v_kept FROM tribes t WHERE t.keeper_id = v_me;

    RETURN jsonb_build_object(
        'is_keeper', (v_role IN ('plug', 'super_admin') OR v_kept > 0),
        'display_role', CASE
            WHEN v_role = 'super_admin' THEN 'super_admin'
            WHEN v_role = 'plug' THEN 'plug'
            WHEN v_kept > 0 THEN 'keeper'
            ELSE 'member'
        END,
        'user_role', v_role,
        'tribes_kept', v_kept
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_keeper_mode() TO authenticated;

-- =========================================================================
-- 2) Moderation queue (reports + keyword hits summary)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.keeper_moderation_queue(
    p_tribe_id UUID,
    p_limit    INT DEFAULT 30,
    p_offset   INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_items JSONB;
    v_kw INT;
    v_warn INT;
BEGIN
    IF NOT can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT coalesce(jsonb_agg(row_to_json(x) ORDER BY x.created_at DESC), '[]'::jsonb)
      INTO v_items
      FROM (
        SELECT
            r.report_id,
            r.post_id,
            r.reason,
            r.note,
            r.created_at,
            left(p.content, 180) AS post_snippet,
            u.anonymous_pseudonym AS reporter_pseudonym
        FROM reports r
        JOIN posts p ON p.post_id = r.post_id
        LEFT JOIN users u ON u.user_id = r.reporter_id
        WHERE p.tribe_id = p_tribe_id
          AND r.is_resolved = false
        ORDER BY r.created_at DESC
        LIMIT greatest(p_limit, 1)
        OFFSET greatest(p_offset, 0)
      ) x;

    SELECT count(*)::INT INTO v_kw
      FROM tribe_keyword_filters WHERE tribe_id = p_tribe_id;

    SELECT count(*)::INT INTO v_warn
      FROM tribe_member_warnings WHERE tribe_id = p_tribe_id
        AND created_at > now() - interval '30 days';

    RETURN jsonb_build_object(
        'items', coalesce(v_items, '[]'::jsonb),
        'keyword_filter_count', v_kw,
        'warnings_30d', v_warn
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.keeper_moderation_queue(UUID, INT, INT) TO authenticated;

-- =========================================================================
-- 3) Engagement calendar (scheduled prompts + suggested slots)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.keeper_engagement_calendar(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_scheduled JSONB;
    v_published JSONB;
    v_suggestions JSONB;
BEGIN
    IF NOT can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT coalesce(jsonb_agg(row_to_json(x) ORDER BY x.scheduled_for ASC NULLS LAST), '[]'::jsonb)
      INTO v_scheduled
      FROM (
        SELECT prompt_id, prompt_text, scheduled_for, published_at, is_active
        FROM plug_prompts
        WHERE tribe_id = p_tribe_id
          AND scheduled_for IS NOT NULL
          AND published_at IS NULL
        ORDER BY scheduled_for ASC
        LIMIT 40
      ) x;

    SELECT coalesce(jsonb_agg(row_to_json(x) ORDER BY x.published_at DESC NULLS LAST), '[]'::jsonb)
      INTO v_published
      FROM (
        SELECT prompt_id, prompt_text, scheduled_for, published_at
        FROM plug_prompts
        WHERE tribe_id = p_tribe_id
          AND published_at IS NOT NULL
        ORDER BY published_at DESC
        LIMIT 12
      ) x;

    -- Lightweight suggestions derived from studio stats cadence.
    SELECT jsonb_build_array(
        jsonb_build_object('title', 'Morning check-in', 'slot', 'weekday_morning',
            'hint', 'Post a gentle prompt before 9am local.'),
        jsonb_build_object('title', 'Weekend reflection', 'slot', 'sunday_evening',
            'hint', 'Schedule a longer-form question for Sunday.'),
        jsonb_build_object('title', 'Mid-week pulse', 'slot', 'wednesday',
            'hint', 'Short poll to measure how members are feeling.')
    ) INTO v_suggestions;

    RETURN jsonb_build_object(
        'scheduled', coalesce(v_scheduled, '[]'::jsonb),
        'recent_published', coalesce(v_published, '[]'::jsonb),
        'suggestions', v_suggestions
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.keeper_engagement_calendar(UUID) TO authenticated;

-- =========================================================================
-- 4) AI insights (heuristic analytics — no external LLM)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.keeper_ai_insights(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_stats RECORD;
    v_moods JSONB;
    v_insights JSONB := '[]'::jsonb;
    v_score INT := 72;
    v_retention TEXT := 'stable';
    v_safety INT := 100;
BEGIN
    IF NOT can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO v_stats FROM tribe_studio_stats WHERE tribe_id = p_tribe_id;

    SELECT coalesce(jsonb_agg(row_to_json(m) ORDER BY m.cnt DESC), '[]'::jsonb)
      INTO v_moods
      FROM (
        SELECT p.post_mood::text AS mood, count(*)::INT AS cnt
        FROM posts p
        WHERE p.tribe_id = p_tribe_id
          AND p.deleted_at IS NULL
          AND p.created_at > now() - interval '14 days'
        GROUP BY p.post_mood
        ORDER BY cnt DESC
        LIMIT 5
      ) m;

    IF coalesce(v_stats.open_reports, 0) > 0 THEN
        v_insights := v_insights || jsonb_build_array(jsonb_build_object(
            'kind', 'safety',
            'severity', 'high',
            'title', 'Open reports need review',
            'body', format('%s unresolved report(s) — triage within 24h to protect trust.',
                v_stats.open_reports),
            'action', 'moderation'
        ));
        v_safety := greatest(40, 100 - v_stats.open_reports * 12);
        v_score := v_score - 15;
    END IF;

    IF coalesce(v_stats.posts_7d, 0) < greatest(coalesce(v_stats.member_count, 1) / 5, 3) THEN
        v_insights := v_insights || jsonb_build_array(jsonb_build_object(
            'kind', 'engagement',
            'severity', 'medium',
            'title', 'Posting pace is quiet',
            'body', 'Fewer vents than expected for your size. Try a scheduled prompt this week.',
            'action', 'calendar'
        ));
        v_score := v_score - 8;
    END IF;

    IF coalesce(v_stats.members_7d, 0) * 4 < coalesce(v_stats.members_30d, 0) THEN
        v_retention := 'at_risk';
        v_insights := v_insights || jsonb_build_array(jsonb_build_object(
            'kind', 'retention',
            'severity', 'medium',
            'title', 'New-member momentum slowing',
            'body', 'Weekly joins are trailing monthly pace. Spotlight a welcoming member.',
            'action', 'members'
        ));
        v_score := v_score - 10;
    ELSIF coalesce(v_stats.members_7d, 0) > 0 THEN
        v_retention := 'growing';
        v_insights := v_insights || jsonb_build_array(jsonb_build_object(
            'kind', 'growth',
            'severity', 'positive',
            'title', 'Healthy join velocity',
            'body', format('%s new member(s) this week — keep the welcome message warm.',
                v_stats.members_7d),
            'action', 'members'
        ));
        v_score := v_score + 5;
    END IF;

    IF coalesce(v_stats.active_posters_7d, 0) >= 3 THEN
        v_insights := v_insights || jsonb_build_array(jsonb_build_object(
            'kind', 'community',
            'severity', 'positive',
            'title', 'Active voices this week',
            'body', format('%s unique posters — consider pinning a standout vent.',
                v_stats.active_posters_7d),
            'action', 'content'
        ));
    END IF;

    RETURN jsonb_build_object(
        'health_score', greatest(0, least(100, v_score)),
        'retention_label', v_retention,
        'safety_score', v_safety,
        'mood_trends', coalesce(v_moods, '[]'::jsonb),
        'insights', v_insights,
        'stats', jsonb_build_object(
            'members', coalesce(v_stats.member_count, 0),
            'members_7d', coalesce(v_stats.members_7d, 0),
            'posts_7d', coalesce(v_stats.posts_7d, 0),
            'open_reports', coalesce(v_stats.open_reports, 0)
        )
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.keeper_ai_insights(UUID) TO authenticated;

-- =========================================================================
-- 5) Co-mod permissions grid
-- =========================================================================
CREATE OR REPLACE FUNCTION public.keeper_comod_matrix(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_rows JSONB;
    v_is_keeper BOOLEAN;
BEGIN
    IF NOT can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = p_tribe_id AND t.keeper_id = auth.uid()
    ) INTO v_is_keeper;

    SELECT coalesce(jsonb_agg(row_to_json(x) ORDER BY
        CASE x.role WHEN 'keeper' THEN 0 WHEN 'mod' THEN 1 ELSE 2 END,
        x.pseudonym), '[]'::jsonb)
      INTO v_rows
      FROM (
        SELECT
            tm.user_id,
            u.anonymous_pseudonym AS pseudonym,
            u.avatar_seed,
            tm.role,
            (tm.role = 'keeper') AS can_promote,
            (tm.role IN ('keeper', 'mod')) AS can_warn,
            (tm.role IN ('keeper', 'mod')) AS can_review_reports,
            (tm.role IN ('keeper', 'mod')) AS can_pin,
            (tm.role IN ('keeper', 'mod')) AS can_schedule,
            (tm.role = 'keeper') AS can_kick_mods,
            (tm.role IN ('keeper', 'mod')) AS can_kick_members,
            tm.joined_at
        FROM tribe_members tm
        JOIN users u ON u.user_id = tm.user_id
        WHERE tm.tribe_id = p_tribe_id
          AND tm.role IN ('keeper', 'mod')
      ) x;

    RETURN jsonb_build_object(
        'mods', coalesce(v_rows, '[]'::jsonb),
        'caller_is_keeper', v_is_keeper
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.keeper_comod_matrix(UUID) TO authenticated;

-- =========================================================================
-- 6) Export report (markdown / json text bundle)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.keeper_export_report(
    p_tribe_id UUID,
    p_format   TEXT DEFAULT 'markdown'
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_tribe RECORD;
    v_stats RECORD;
    v_insights JSONB;
    v_md TEXT;
    v_generated TIMESTAMPTZ := now();
BEGIN
    IF NOT can_manage_tribe(p_tribe_id) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT name, slug, member_count INTO v_tribe
      FROM tribes WHERE tribe_id = p_tribe_id;

    SELECT * INTO v_stats FROM tribe_studio_stats WHERE tribe_id = p_tribe_id;
    v_insights := keeper_ai_insights(p_tribe_id);

    v_md := format(
        E'# %s Studio Report\nGenerated: %s\n\n## Snapshot\n- Members: %s\n- New (7d): %s\n- Posts (7d): %s\n- Open reports: %s\n- Health score: %s\n- Safety score: %s\n- Retention: %s\n',
        v_tribe.name,
        to_char(v_generated AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI UTC'),
        coalesce(v_stats.member_count, 0),
        coalesce(v_stats.members_7d, 0),
        coalesce(v_stats.posts_7d, 0),
        coalesce(v_stats.open_reports, 0),
        v_insights->>'health_score',
        v_insights->>'safety_score',
        v_insights->>'retention_label'
    );

    RETURN jsonb_build_object(
        'format', lower(coalesce(p_format, 'markdown')),
        'tribe_name', v_tribe.name,
        'tribe_slug', v_tribe.slug,
        'generated_at', v_generated,
        'markdown', v_md,
        'payload', jsonb_build_object(
            'stats', to_jsonb(v_stats),
            'insights', v_insights
        )
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.keeper_export_report(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
