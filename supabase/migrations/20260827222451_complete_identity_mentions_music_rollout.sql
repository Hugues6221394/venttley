BEGIN;

-- Complete the display-name rollout without changing any existing column
-- order.  CREATE OR REPLACE VIEW may append columns, which keeps older app
-- builds compatible during a rolling deployment.
CREATE OR REPLACE VIEW public.tribe_messages_feed
WITH (security_invoker = true) AS
SELECT
    m.message_id,
    m.tribe_id,
    m.sender_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS sender_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS sender_avatar_seed,
    CASE WHEN m.sender_persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
      AS sender_profile_photo_url,
    CASE WHEN m.sender_persona_id IS NULL THEN COALESCE(u.is_verified, false) ELSE false END
      AS sender_is_verified,
    m.sender_persona_id,
    m.content,
    m.image_url,
    m.audio_url,
    m.audio_duration_seconds,
    m.hugs_count,
    m.created_at,
    m.edited_at,
    m.deleted_at,
    m.reply_to_message_id,
    rm.content AS reply_content,
    COALESCE(rpr.pseudonym, ru.anonymous_pseudonym) AS reply_sender_pseudonym,
    EXISTS (
      SELECT 1 FROM public.tribe_message_hugs AS h
       WHERE h.message_id = m.message_id AND h.user_id = (SELECT auth.uid())
    ) AS hugged_by_me,
    (t.pinned_message_id = m.message_id) AS is_pinned,
    m.metadata,
    (
      SELECT pv.option_id
        FROM public.tribe_message_poll_votes AS pv
       WHERE pv.message_id = m.message_id AND pv.user_id = (SELECT auth.uid())
    ) AS poll_my_vote_option_id,
    public.tribe_poll_option_counts(m.message_id) AS poll_option_counts,
    (
      SELECT r.emoji
        FROM public.tribe_message_reactions AS r
       WHERE r.message_id = m.message_id AND r.user_id = (SELECT auth.uid())
    ) AS my_reaction,
    (
      SELECT COALESCE(jsonb_object_agg(s.emoji, s.cnt), '{}'::jsonb)
        FROM (
          SELECT tr.emoji, count(*)::INT AS cnt
            FROM public.tribe_message_reactions AS tr
           WHERE tr.message_id = m.message_id
           GROUP BY tr.emoji
        ) AS s
    ) AS reaction_counts,
    (
      SELECT count(*)::INT
        FROM public.tribe_messages AS q
       WHERE q.reply_to_message_id = m.message_id AND q.deleted_at IS NULL
    ) AS question_reply_count,
    CASE
      WHEN m.sender_persona_id IS NOT NULL THEN pr.pseudonym
      ELSE COALESCE(NULLIF(btrim(u.display_name), ''), u.anonymous_pseudonym, 'Anonymous')
    END AS sender_display_name,
    CASE
      WHEN rm.sender_persona_id IS NOT NULL THEN rpr.pseudonym
      ELSE COALESCE(NULLIF(btrim(ru.display_name), ''), ru.anonymous_pseudonym)
    END AS reply_sender_display_name
FROM public.tribe_messages AS m
JOIN public.tribes AS t ON t.tribe_id = m.tribe_id
LEFT JOIN public.users AS u ON u.user_id = m.sender_id
LEFT JOIN public.personas AS pr
  ON pr.persona_id = m.sender_persona_id AND pr.deleted_at IS NULL
LEFT JOIN public.tribe_messages AS rm ON rm.message_id = m.reply_to_message_id
LEFT JOIN public.users AS ru ON ru.user_id = rm.sender_id
LEFT JOIN public.personas AS rpr
  ON rpr.persona_id = rm.sender_persona_id AND rpr.deleted_at IS NULL;

GRANT SELECT ON public.tribe_messages_feed TO authenticated;

CREATE OR REPLACE VIEW public.friend_requests_inbox
WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    f.requested_by AS from_user_id,
    u.anonymous_pseudonym AS from_pseudonym,
    u.avatar_seed AS from_avatar_seed,
    u.karma_points AS from_karma,
    f.note,
    f.created_at,
    u.profile_photo_url AS from_profile_photo_url,
    COALESCE(NULLIF(btrim(u.display_name), ''), u.anonymous_pseudonym, 'Anonymous')
      AS from_display_name
FROM public.friendships AS f
JOIN public.users AS u ON u.user_id = f.requested_by
WHERE f.status = 'pending'
  AND (SELECT auth.uid()) IN (f.user_a, f.user_b)
  AND f.requested_by <> (SELECT auth.uid());

CREATE OR REPLACE VIEW public.friend_requests_outbox
WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    CASE WHEN f.user_a = (SELECT auth.uid()) THEN f.user_b ELSE f.user_a END AS to_user_id,
    u.anonymous_pseudonym AS to_pseudonym,
    u.avatar_seed AS to_avatar_seed,
    u.karma_points AS to_karma,
    f.note,
    f.created_at,
    u.profile_photo_url AS to_profile_photo_url,
    COALESCE(NULLIF(btrim(u.display_name), ''), u.anonymous_pseudonym, 'Anonymous')
      AS to_display_name
FROM public.friendships AS f
JOIN public.users AS u
  ON u.user_id = CASE
      WHEN f.user_a = (SELECT auth.uid()) THEN f.user_b ELSE f.user_a
    END
WHERE f.status = 'pending'
  AND (SELECT auth.uid()) IN (f.user_a, f.user_b)
  AND f.requested_by = (SELECT auth.uid());

GRANT SELECT ON public.friend_requests_inbox TO authenticated;
GRANT SELECT ON public.friend_requests_outbox TO authenticated;

-- Shared-post snapshots are server-authored.  Add the display label at the
-- point of capture so deleted posts remain renderable without a later profile
-- lookup.  Persona posts keep the persona label and never expose the account's
-- display name.
CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_room_id UUID,
  p_payload TEXT,
  p_attached_post_id UUID DEFAULT NULL,
  p_media_path TEXT DEFAULT NULL,
  p_media_type TEXT DEFAULT NULL
) RETURNS TABLE (
  message_id UUID,
  room_id UUID,
  sender_id UUID,
  payload TEXT,
  attached_post_id UUID,
  attached_post_snapshot JSONB,
  attached_media_path TEXT,
  attached_media_type TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room public.chat_rooms%ROWTYPE;
  v_snapshot JSONB;
  v_row public.chat_messages%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO v_room FROM public.chat_rooms AS r WHERE r.room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'room not found'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  IF v_room.room_status <> 'active' THEN RAISE EXCEPTION 'room is not active'; END IF;
  IF (p_media_path IS NULL) <> (p_media_type IS NULL) THEN
    RAISE EXCEPTION 'media path and type must be provided together';
  END IF;
  IF p_media_path IS NOT NULL AND p_media_path !~ ('^' || p_room_id::TEXT || '/') THEN
    RAISE EXCEPTION 'media path must be in room prefix';
  END IF;
  IF p_media_type IS NOT NULL AND p_media_type NOT IN ('image', 'audio') THEN
    RAISE EXCEPTION 'unsupported media type';
  END IF;
  IF btrim(COALESCE(p_payload, '')) = ''
     AND p_attached_post_id IS NULL AND p_media_path IS NULL THEN
    RAISE EXCEPTION 'message must have content or an attachment';
  END IF;
  IF p_attached_post_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'post_id', p.post_id,
      'content', left(p.content, 400),
      'author_id', p.author_id,
      'category', p.category_name,
      'mood', p.post_mood,
      'is_whisper', p.is_whisper,
      'created_at', p.created_at,
      'author_pseudonym', COALESCE('@' || pr.pseudonym, '@' || u.anonymous_pseudonym),
      'author_display_name', CASE
        WHEN p.persona_id IS NOT NULL THEN pr.pseudonym
        ELSE COALESCE(NULLIF(btrim(u.display_name), ''), u.anonymous_pseudonym, 'Anonymous')
      END,
      'author_avatar_seed', COALESCE(pr.avatar_seed, u.avatar_seed)
    ) INTO v_snapshot
      FROM public.posts AS p
      LEFT JOIN public.users AS u ON u.user_id = p.author_id
      LEFT JOIN public.personas AS pr
        ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
     WHERE p.post_id = p_attached_post_id
       AND p.deleted_at IS NULL
       AND (
         p.tribe_id IS NULL
         OR NOT EXISTS (
           SELECT 1 FROM public.tribes AS tr
            WHERE tr.tribe_id = p.tribe_id AND tr.is_private
         )
         OR EXISTS (
           SELECT 1 FROM public.tribe_members AS tm
            WHERE tm.tribe_id = p.tribe_id AND tm.user_id = v_me
         )
       );
    IF v_snapshot IS NULL THEN
      RAISE EXCEPTION 'attached post not found or not readable';
    END IF;
  END IF;
  INSERT INTO public.chat_messages (
    room_id, sender_id, encrypted_payload, nonce_iv, attached_post_id,
    attached_post_snapshot, attached_media_path, attached_media_type
  ) VALUES (
    p_room_id, v_me, COALESCE(p_payload, ''), 'v1-plaintext',
    p_attached_post_id, v_snapshot, p_media_path, p_media_type
  ) RETURNING * INTO v_row;
  message_id := v_row.message_id;
  room_id := v_row.room_id;
  sender_id := v_row.sender_id;
  payload := v_row.encrypted_payload;
  attached_post_id := v_row.attached_post_id;
  attached_post_snapshot := v_row.attached_post_snapshot;
  attached_media_path := v_row.attached_media_path;
  attached_media_type := v_row.attached_media_type;
  created_at := v_row.created_at;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.send_chat_message(UUID, TEXT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID, TEXT, UUID, TEXT, TEXT)
  TO authenticated;

-- Persist immutable mention targets.  Display text remains @username, but
-- notification/routing identity no longer depends on resolving that mutable
-- string again later.
CREATE TABLE IF NOT EXISTS private.content_mentions (
  mention_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_kind TEXT NOT NULL CHECK (source_kind IN ('post', 'comment', 'whisper_comment')),
  source_id UUID NOT NULL,
  mentioned_user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  handle_snapshot TEXT NOT NULL CHECK (char_length(handle_snapshot) BETWEEN 2 AND 32),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_kind, source_id, mentioned_user_id)
);

CREATE INDEX IF NOT EXISTS content_mentions_recipient_idx
  ON private.content_mentions (mentioned_user_id, created_at DESC);
REVOKE ALL ON TABLE private.content_mentions FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._notify_mentions(
  p_actor UUID,
  p_content TEXT,
  p_subject_type TEXT,
  p_subject_id UUID,
  p_extra JSONB
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_handle TEXT;
  v_target UUID;
  v_previous UUID[];
BEGIN
  IF p_subject_type NOT IN ('post', 'comment', 'whisper_comment') THEN
    RAISE EXCEPTION 'unsupported mention subject';
  END IF;

  SELECT array_agg(cm.mentioned_user_id)
    INTO v_previous
    FROM private.content_mentions AS cm
   WHERE cm.source_kind = p_subject_type AND cm.source_id = p_subject_id;

  DELETE FROM private.content_mentions AS cm
   WHERE cm.source_kind = p_subject_type AND cm.source_id = p_subject_id;

  IF p_content IS NULL THEN RETURN; END IF;
  FOR v_handle IN
    SELECT DISTINCT lower(m[1])
      FROM regexp_matches(p_content, '@([A-Za-z0-9_.-]{2,32})', 'g') AS m
     LIMIT 10
  LOOP
    v_target := NULL;
    SELECT u.user_id INTO v_target
      FROM public.users AS u
     WHERE u.username_normalized = v_handle AND u.deactivated_at IS NULL
     LIMIT 1;
    IF v_target IS NOT NULL THEN
      INSERT INTO private.content_mentions (
        source_kind, source_id, mentioned_user_id, handle_snapshot
      ) VALUES (p_subject_type, p_subject_id, v_target, v_handle)
      ON CONFLICT (source_kind, source_id, mentioned_user_id)
      DO UPDATE SET handle_snapshot = EXCLUDED.handle_snapshot;

      IF v_previous IS NULL OR NOT (v_target = ANY(v_previous)) THEN
        PERFORM public._notify(
          v_target, p_actor, 'mention', p_subject_type, p_subject_id,
          'mentioned you', left(p_content, 60), NULL, COALESCE(p_extra, '{}'::jsonb)
        );
      END IF;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_mentions_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._notify_mentions(
    NEW.author_id, NEW.content, 'post', NEW.post_id,
    jsonb_build_object('post_id', NEW.post_id)
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_mentions_post_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._notify_mentions(
    NEW.author_id, NEW.content, 'comment', NEW.comment_id,
    jsonb_build_object('post_id', NEW.post_id, 'comment_id', NEW.comment_id)
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_mentions_whisper_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._notify_mentions(
    NEW.author_id, NEW.content, 'whisper_comment', NEW.comment_id,
    jsonb_build_object('whisper_id', NEW.whisper_id, 'comment_id', NEW.comment_id)
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mentions_post_trg ON public.posts;
CREATE TRIGGER mentions_post_trg
  AFTER INSERT OR UPDATE OF content ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_post();
DROP TRIGGER IF EXISTS mentions_post_comment_trg ON public.posts_comments;
CREATE TRIGGER mentions_post_comment_trg
  AFTER INSERT OR UPDATE OF content ON public.posts_comments
  FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_post_comment();
DROP TRIGGER IF EXISTS mentions_whisper_comment_trg ON public.whisper_comments;
CREATE TRIGGER mentions_whisper_comment_trg
  AFTER INSERT OR UPDATE OF content ON public.whisper_comments
  FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_whisper_comment();

CREATE OR REPLACE FUNCTION private.clear_post_mentions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  DELETE FROM private.content_mentions WHERE source_kind = 'post' AND source_id = OLD.post_id;
  RETURN OLD;
END;
$$;
CREATE OR REPLACE FUNCTION private.clear_post_comment_mentions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  DELETE FROM private.content_mentions WHERE source_kind = 'comment' AND source_id = OLD.comment_id;
  RETURN OLD;
END;
$$;
CREATE OR REPLACE FUNCTION private.clear_whisper_comment_mentions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  DELETE FROM private.content_mentions WHERE source_kind = 'whisper_comment' AND source_id = OLD.comment_id;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS clear_post_mentions_trg ON public.posts;
CREATE TRIGGER clear_post_mentions_trg AFTER DELETE ON public.posts
  FOR EACH ROW EXECUTE FUNCTION private.clear_post_mentions();
DROP TRIGGER IF EXISTS clear_post_comment_mentions_trg ON public.posts_comments;
CREATE TRIGGER clear_post_comment_mentions_trg AFTER DELETE ON public.posts_comments
  FOR EACH ROW EXECUTE FUNCTION private.clear_post_comment_mentions();
DROP TRIGGER IF EXISTS clear_whisper_comment_mentions_trg ON public.whisper_comments;
CREATE TRIGGER clear_whisper_comment_mentions_trg AFTER DELETE ON public.whisper_comments
  FOR EACH ROW EXECUTE FUNCTION private.clear_whisper_comment_mentions();

REVOKE ALL ON FUNCTION public._notify_mentions(UUID, TEXT, TEXT, UUID, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._notify_mentions(UUID, TEXT, TEXT, UUID, JSONB)
  TO service_role;
REVOKE ALL ON FUNCTION private.clear_post_mentions()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.clear_post_comment_mentions()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.clear_whisper_comment_mentions()
  FROM PUBLIC, anon, authenticated, service_role;

-- Music is globally kill-switchable and starts internal-only. Per-user
-- overrides enable staff/testers without placing all users into an unverified
-- catalog rollout.
ALTER TABLE public.music_tracks
  ADD COLUMN IF NOT EXISTS cache_allowed BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE public.music_tracks
   SET cache_allowed = TRUE
 WHERE provider = 'venttly_original';
GRANT SELECT (cache_allowed) ON public.music_tracks TO authenticated;

UPDATE public.feature_flags
   SET enabled = TRUE,
       rollout_pct = 0,
       metadata = COALESCE(metadata, '{}'::jsonb) ||
         '{"kill_switch":true,"rollout_stage":"internal"}'::jsonb,
       updated_at = now()
 WHERE flag_key = 'vent_music';

CREATE OR REPLACE FUNCTION private.feature_enabled_for(p_flag TEXT, p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT flag.enabled AND COALESCE(
      (
        SELECT override.bool_value
          FROM public.feature_flag_overrides AS override
         WHERE override.flag_key = flag.flag_key
           AND override.user_id = p_user
           AND override.bool_value IS NOT NULL
         ORDER BY override.created_at DESC, override.override_id DESC
         LIMIT 1
      ),
      flag.rollout_pct >= 100 OR (
        (pg_catalog.hashtextextended(COALESCE(p_user::TEXT, '') || flag.flag_key, 0)
          & 9223372036854775807) % 100
      ) < flag.rollout_pct
    )
      FROM public.feature_flags AS flag
     WHERE flag.flag_key = p_flag
  ), FALSE);
$$;
REVOKE ALL ON FUNCTION private.feature_enabled_for(TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.my_feature_flags()
RETURNS TABLE (flag_key TEXT, enabled BOOLEAN, payload JSONB)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT f.flag_key,
         private.feature_enabled_for(f.flag_key, (SELECT auth.uid())),
         f.metadata
    FROM public.feature_flags AS f
   WHERE (SELECT auth.uid()) IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION public.my_feature_flags() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_feature_flags() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_user_feature_override(
  p_user_id UUID,
  p_flag_key TEXT,
  p_enabled BOOLEAN
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
BEGIN
  IF NOT public.is_staff(v_actor, ARRAY['super_admin','admin']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_user_id) THEN
    RAISE EXCEPTION 'user not found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.feature_flags WHERE flag_key = p_flag_key) THEN
    RAISE EXCEPTION 'feature flag not found';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('flag-override:' || p_user_id::TEXT || ':' || p_flag_key, 0)
  );
  DELETE FROM public.feature_flag_overrides
   WHERE user_id = p_user_id AND tribe_id IS NULL AND flag_key = p_flag_key;
  INSERT INTO public.feature_flag_overrides (flag_key, user_id, bool_value)
  VALUES (p_flag_key, p_user_id, p_enabled);
  PERFORM public.admin_log(
    'feature_flag.user_override', 'user', p_user_id, p_flag_key,
    NULL, jsonb_build_object('enabled', p_enabled), NULL, '{}'::jsonb
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_user_feature_override(UUID, TEXT, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_user_feature_override(UUID, TEXT, BOOLEAN)
  TO authenticated;

CREATE TABLE IF NOT EXISTS private.music_track_usage (
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  track_id UUID NOT NULL REFERENCES public.music_tracks(track_id) ON DELETE CASCADE,
  use_count BIGINT NOT NULL DEFAULT 1 CHECK (use_count > 0),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, track_id)
);
CREATE INDEX IF NOT EXISTS music_track_usage_trending_idx
  ON private.music_track_usage (last_used_at DESC, track_id);
REVOKE ALL ON TABLE private.music_track_usage FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_post_music(
  p_post_id UUID,
  p_music_track_id UUID,
  p_start_ms INT DEFAULT 0,
  p_duration_ms INT DEFAULT 15000,
  p_volume REAL DEFAULT 0.75
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
  v_previous_track UUID;
  v_track_duration INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.claim_music_quota(v_me, 'music_attachment', 30) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT post.author_id, post.music_track_id
    INTO v_author, v_previous_track
    FROM public.posts AS post
   WHERE post.post_id = p_post_id AND post.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'post not found'; END IF;
  IF v_author <> v_me THEN RAISE EXCEPTION 'not your post'; END IF;

  IF p_music_track_id IS NULL THEN
    UPDATE public.posts
       SET music_track_id = NULL, music_start_ms = NULL,
           music_duration_ms = NULL, music_volume = NULL
     WHERE post_id = p_post_id;
    RETURN TRUE;
  END IF;
  IF NOT private.feature_enabled_for('vent_music', v_me) THEN
    RAISE EXCEPTION 'music_feature_disabled';
  END IF;
  SELECT track.duration_ms INTO v_track_duration
    FROM public.music_tracks AS track
   WHERE track.track_id = p_music_track_id
     AND track.is_active
     AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now());
  IF NOT FOUND THEN RAISE EXCEPTION 'music_track_unavailable'; END IF;
  IF p_start_ms < 0 OR p_duration_ms NOT BETWEEN 3000 AND 30000
     OR p_start_ms + p_duration_ms > v_track_duration
     OR p_volume NOT BETWEEN 0.0 AND 1.0 THEN
    RAISE EXCEPTION 'invalid_music_window';
  END IF;

  UPDATE public.posts
     SET music_track_id = p_music_track_id,
         music_start_ms = p_start_ms,
         music_duration_ms = p_duration_ms,
         music_volume = p_volume
   WHERE post_id = p_post_id;

  IF v_previous_track IS DISTINCT FROM p_music_track_id THEN
    INSERT INTO private.music_track_usage (user_id, track_id)
    VALUES (v_me, p_music_track_id)
    ON CONFLICT (user_id, track_id) DO UPDATE
      SET use_count = private.music_track_usage.use_count + 1,
          last_used_at = now();
  END IF;
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.set_post_music(UUID, UUID, INT, INT, REAL)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_post_music(UUID, UUID, INT, INT, REAL)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.music_catalog_section(
  p_section TEXT,
  p_limit INT DEFAULT 12
) RETURNS SETOF public.music_tracks
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_section TEXT := lower(btrim(COALESCE(p_section, 'trending')));
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.feature_enabled_for('vent_music', v_me) THEN RETURN; END IF;
  IF v_section NOT IN ('trending', 'recent', 'for_you') THEN
    RAISE EXCEPTION 'unsupported catalog section';
  END IF;
  IF NOT private.claim_music_quota(v_me, 'music_catalog', 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  IF v_section = 'recent' THEN
    RETURN QUERY
    SELECT track.*
      FROM private.music_track_usage AS usage
      JOIN public.music_tracks AS track ON track.track_id = usage.track_id
     WHERE usage.user_id = v_me
       AND track.is_active
       AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now())
     ORDER BY usage.last_used_at DESC, track.track_id
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 30);
  ELSIF v_section = 'for_you' THEN
    RETURN QUERY
    WITH preferences AS (
      SELECT array_agg(DISTINCT mood_tag.value) AS moods,
             array_agg(DISTINCT used.genre) FILTER (WHERE used.genre IS NOT NULL) AS genres
        FROM private.music_track_usage AS usage
        JOIN public.music_tracks AS used ON used.track_id = usage.track_id
        LEFT JOIN LATERAL unnest(used.mood_tags) AS mood_tag(value) ON TRUE
       WHERE usage.user_id = v_me
    )
    SELECT track.*
      FROM public.music_tracks AS track
      CROSS JOIN preferences AS pref
     WHERE track.is_active
       AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now())
     ORDER BY
       ((pref.moods IS NOT NULL AND track.mood_tags && pref.moods)::INT +
        (pref.genres IS NOT NULL AND track.genre = ANY(pref.genres))::INT) DESC,
       track.created_at DESC,
       track.track_id
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 30);
  ELSE
    RETURN QUERY
    SELECT track.*
      FROM public.music_tracks AS track
      LEFT JOIN (
        SELECT usage.track_id, sum(usage.use_count) AS uses,
               max(usage.last_used_at) AS last_used_at
          FROM private.music_track_usage AS usage
         WHERE usage.last_used_at > now() - INTERVAL '30 days'
         GROUP BY usage.track_id
      ) AS score ON score.track_id = track.track_id
     WHERE track.is_active
       AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now())
     ORDER BY COALESCE(score.uses, 0) DESC,
              score.last_used_at DESC NULLS LAST,
              track.created_at DESC,
              track.track_id
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 30);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.music_catalog_section(TEXT, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.music_catalog_section(TEXT, INT)
  TO authenticated;

-- New notifications use the human-facing identity. Existing historical
-- payloads remain unchanged for auditability.
CREATE OR REPLACE FUNCTION public._notify(
  p_user UUID,
  p_actor UUID,
  p_kind TEXT,
  p_subject_type TEXT,
  p_subject_id UUID,
  p_action TEXT,
  p_preview TEXT DEFAULT NULL,
  p_window INTERVAL DEFAULT NULL,
  p_extra JSONB DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_name TEXT;
  v_row public.notifications%ROWTYPE;
  v_actors JSONB;
  v_names TEXT;
  v_count INT;
  v_extra_n INT;
BEGIN
  IF p_user IS NULL OR p_user = p_actor THEN RETURN; END IF;
  SELECT COALESCE(NULLIF(btrim(u.display_name), ''), u.anonymous_pseudonym, 'Someone')
    INTO v_actor_name
    FROM public.users AS u WHERE u.user_id = p_actor;
  v_actor_name := COALESCE(v_actor_name, 'Someone');

  IF p_window IS NOT NULL THEN
    SELECT * INTO v_row
      FROM public.notifications AS notification
     WHERE notification.user_id = p_user
       AND notification.kind = p_kind
       AND notification.subject_id = p_subject_id
       AND NOT notification.is_read
       AND notification.updated_at > now() - p_window
     ORDER BY notification.updated_at DESC
     LIMIT 1 FOR UPDATE;
    IF FOUND THEN
      v_actors := COALESCE(v_row.payload->'actors', '[]'::jsonb);
      IF NOT v_actors @> to_jsonb(v_actor_name) THEN
        v_actors := to_jsonb(v_actor_name) || v_actors;
      END IF;
      v_actors := (
        SELECT COALESCE(jsonb_agg(actor.value), '[]'::jsonb)
          FROM (SELECT value FROM jsonb_array_elements(v_actors) LIMIT 3) AS actor
      );
      v_count := v_row.group_count + 1;
      v_names := (
        SELECT string_agg(actor.value #>> '{}', ', ')
          FROM jsonb_array_elements(v_actors) AS actor
      );
      v_extra_n := v_count - jsonb_array_length(v_actors);
      UPDATE public.notifications
         SET group_count = v_count,
             actor_id = p_actor,
             updated_at = now(),
             payload = v_row.payload || COALESCE(p_extra, '{}'::jsonb) || jsonb_build_object(
               'actors', v_actors,
               'title', CASE WHEN v_extra_n > 0 THEN
                 v_names || ' and ' || v_extra_n::TEXT ||
                 CASE WHEN v_extra_n = 1 THEN ' other' ELSE ' others' END
                 ELSE v_names END,
               'body', p_action || COALESCE(' "' || left(p_preview, 60) || '"', ''),
               'count', v_count
             )
       WHERE notification_id = v_row.notification_id;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.notifications (
    user_id, kind, actor_id, subject_type, subject_id, payload
  ) VALUES (
    p_user, p_kind, p_actor, p_subject_type, p_subject_id,
    COALESCE(p_extra, '{}'::jsonb) || jsonb_build_object(
      'title', v_actor_name,
      'body', p_action || COALESCE(' "' || left(p_preview, 60) || '"', ''),
      'actors', jsonb_build_array(v_actor_name),
      'count', 1
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public._notify(
  UUID, UUID, TEXT, TEXT, UUID, TEXT, TEXT, INTERVAL, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._notify(
  UUID, UUID, TEXT, TEXT, UUID, TEXT, TEXT, INTERVAL, JSONB
) TO service_role;

SELECT public.record_migration(
  '20260827222451',
  'complete_identity_mentions_music_rollout'
);

NOTIFY pgrst, 'reload schema';
COMMIT;
