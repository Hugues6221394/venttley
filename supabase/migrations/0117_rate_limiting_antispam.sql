-- 0117: Server-side rate limiting, input sanitization, and anti-spam.
--
-- Everything here runs in BEFORE INSERT triggers on the domain tables, so
-- it covers every write path (PostgREST inserts, RPCs, future clients) and
-- cannot be bypassed by a modified client. Sliding windows count rows in
-- the domain tables themselves — no separate counter table to keep hot.
--
-- Limits (per authenticated user):
--   posts            6/min, 30/hour   (whispers additionally 10/hour)
--   comments         60/min           (posts_comments + whisper_comments)
--   chat messages    120/min          (DM + tribe)
--   friend requests  20/hour
--   reports          20/day
-- New accounts (<1 hour old) get much tighter caps until they settle.
--
-- Also introduces:
--   users.shadow_banned          — author still sees their posts; nobody else does
--   users.posting_cooldown_until — temporary mute set by admins/anti-spam
--   sanitize_user_text()         — strips zero-width & control chars, caps blank runs
--   duplicate + link-spam detection on posts and comments

-- ============================================================
-- 1. Moderation columns
-- ============================================================
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS shadow_banned BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS posting_cooldown_until TIMESTAMPTZ;

-- ============================================================
-- 2. Supporting indexes for the sliding-window counts
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_posts_author_created
  ON public.posts (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_comments_author_created
  ON public.posts_comments (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_whisper_comments_author_created
  ON public.whisper_comments (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_created
  ON public.chat_messages (sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tribe_messages_sender_created
  ON public.tribe_messages (sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_friendships_requested_by_created
  ON public.friendships (requested_by, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reports_reporter_created
  ON public.reports (reporter_id, created_at DESC);

-- ============================================================
-- 3. Text sanitization
-- ============================================================
-- Strips invisible/abusive Unicode, normalizes whitespace abuse, trims.
-- Length enforcement stays in the calling trigger (limits differ per table).
CREATE OR REPLACE FUNCTION public.sanitize_user_text(p_text TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(
    btrim(
      -- 3+ consecutive newlines -> exactly 2 (paragraph break)
      regexp_replace(
        -- runs of 20+ identical characters -> 20 (keyboard-mash flood)
        regexp_replace(
          -- zero-width, joiner, and directional-override characters
          regexp_replace(
            -- C0/C1 control chars except \n and \t
            regexp_replace(coalesce(p_text, ''),
              '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g'),
            U&'[\200B-\200F\202A-\202E\2060-\2064\FEFF]', '', 'g'),
          '(.)\1{19,}', repeat('\1', 20), 'g'),
        E'\n{3,}', E'\n\n', 'g')
    ), '');
$$;

-- ============================================================
-- 4. Shared guard: cooldowns, account age, sliding windows
-- ============================================================
-- Raises a friendly message the client can show verbatim. SECURITY DEFINER
-- so the count queries see all rows regardless of the caller's RLS.
CREATE OR REPLACE FUNCTION public._guard_write(
  p_user UUID,
  p_action TEXT,             -- for the error message
  p_recent_count BIGINT,     -- rows already in the window (caller counts)
  p_max INT,
  p_window TEXT              -- 'minute' | 'hour' | 'day', message only
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_recent_count >= p_max THEN
    RAISE EXCEPTION 'Slow down — too many % in one %. Try again shortly.',
      p_action, p_window
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- Cooldown + returns the account age so triggers can tighten new-account caps.
CREATE OR REPLACE FUNCTION public._writer_state(p_user UUID)
RETURNS TABLE (account_age INTERVAL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cooldown TIMESTAMPTZ;
  v_created  TIMESTAMPTZ;
BEGIN
  SELECT u.posting_cooldown_until, u.created_at
    INTO v_cooldown, v_created
    FROM users u WHERE u.user_id = p_user;
  IF v_cooldown IS NOT NULL AND v_cooldown > NOW() THEN
    RAISE EXCEPTION 'Posting is paused on your account for a little while.'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY SELECT NOW() - COALESCE(v_created, NOW());
END;
$$;

-- ============================================================
-- 5. Posts: rate limit + sanitize + duplicate/link spam
-- ============================================================
CREATE OR REPLACE FUNCTION public._posts_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_age INTERVAL;
  v_min BIGINT; v_hour BIGINT;
BEGIN
  IF NEW.author_id IS NULL THEN RETURN NEW; END IF;
  SELECT account_age INTO v_age FROM _writer_state(NEW.author_id);

  NEW.content := COALESCE(sanitize_user_text(NEW.content), '');
  IF length(NEW.content) > 4000 THEN
    RAISE EXCEPTION 'Vents are capped at 4000 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(NEW.content, '@[A-Za-z0-9_.-]{2,32}', 'g')) > 20 THEN
    RAISE EXCEPTION 'Too many @mentions in one post (max 20).' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_min  FROM posts
   WHERE author_id = NEW.author_id AND created_at > NOW() - INTERVAL '1 minute';
  SELECT count(*) INTO v_hour FROM posts
   WHERE author_id = NEW.author_id AND created_at > NOW() - INTERVAL '1 hour';
  PERFORM _guard_write(NEW.author_id, 'posts', v_min, 6, 'minute');
  PERFORM _guard_write(NEW.author_id, 'posts', v_hour, 30, 'hour');

  -- Whisper uploads are heavier — 10/hour.
  IF NEW.is_whisper THEN
    PERFORM _guard_write(NEW.author_id, 'whispers',
      (SELECT count(*) FROM posts
        WHERE author_id = NEW.author_id AND is_whisper
          AND created_at > NOW() - INTERVAL '1 hour'),
      10, 'hour');
  END IF;

  -- Brand-new accounts: 3 posts in the first hour is plenty.
  IF v_age < INTERVAL '1 hour' THEN
    PERFORM _guard_write(NEW.author_id, 'posts from a new account', v_hour, 3, 'hour');
  END IF;

  -- Duplicate content: same author repeating the same non-trivial text.
  IF length(NEW.content) > 20 AND EXISTS (
    SELECT 1 FROM posts
     WHERE author_id = NEW.author_id
       AND created_at > NOW() - INTERVAL '10 minutes'
       AND md5(content) = md5(NEW.content)
  ) THEN
    RAISE EXCEPTION 'Looks like you already posted this. Give it a minute.'
      USING ERRCODE = 'P0001';
  END IF;

  -- Link spam: no links from accounts younger than 24h; 5 link posts/hour after.
  IF NEW.content ~* 'https?://' THEN
    IF v_age < INTERVAL '24 hours' THEN
      RAISE EXCEPTION 'New accounts can''t post links yet.' USING ERRCODE = 'P0001';
    END IF;
    PERFORM _guard_write(NEW.author_id, 'posts with links',
      (SELECT count(*) FROM posts
        WHERE author_id = NEW.author_id
          AND created_at > NOW() - INTERVAL '1 hour'
          AND content ~* 'https?://'),
      5, 'hour');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_write_guard ON public.posts;
CREATE TRIGGER posts_write_guard
  BEFORE INSERT ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public._posts_write_guard();

-- ============================================================
-- 6. Comments (threads + whispers): rate limit + sanitize + dupes
-- ============================================================
CREATE OR REPLACE FUNCTION public._comments_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_age INTERVAL;
  v_min BIGINT;
BEGIN
  IF NEW.author_id IS NULL THEN RETURN NEW; END IF;
  SELECT account_age INTO v_age FROM _writer_state(NEW.author_id);

  NEW.content := COALESCE(sanitize_user_text(NEW.content), '');
  IF length(NEW.content) > 2000 THEN
    RAISE EXCEPTION 'Replies are capped at 2000 characters.' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(NEW.content, '@[A-Za-z0-9_.-]{2,32}', 'g')) > 20 THEN
    RAISE EXCEPTION 'Too many @mentions in one reply (max 20).' USING ERRCODE = 'P0001';
  END IF;

  IF TG_TABLE_NAME = 'posts_comments' THEN
    SELECT count(*) INTO v_min FROM posts_comments
     WHERE author_id = NEW.author_id AND created_at > NOW() - INTERVAL '1 minute';
  ELSE
    SELECT count(*) INTO v_min FROM whisper_comments
     WHERE author_id = NEW.author_id AND created_at > NOW() - INTERVAL '1 minute';
  END IF;
  PERFORM _guard_write(NEW.author_id, 'replies', v_min, 60, 'minute');

  IF v_age < INTERVAL '1 hour' THEN
    PERFORM _guard_write(NEW.author_id, 'replies from a new account', v_min, 10, 'minute');
  END IF;

  -- Same non-trivial reply repeated within 10 minutes = spam.
  IF length(NEW.content) > 20 THEN
    IF TG_TABLE_NAME = 'posts_comments' AND EXISTS (
      SELECT 1 FROM posts_comments
       WHERE author_id = NEW.author_id
         AND created_at > NOW() - INTERVAL '10 minutes'
         AND md5(content) = md5(NEW.content)
    ) THEN
      RAISE EXCEPTION 'You already said exactly that. Give it a minute.'
        USING ERRCODE = 'P0001';
    END IF;
    IF TG_TABLE_NAME = 'whisper_comments' AND EXISTS (
      SELECT 1 FROM whisper_comments
       WHERE author_id = NEW.author_id
         AND created_at > NOW() - INTERVAL '10 minutes'
         AND md5(content) = md5(NEW.content)
    ) THEN
      RAISE EXCEPTION 'You already said exactly that. Give it a minute.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_comments_write_guard ON public.posts_comments;
CREATE TRIGGER posts_comments_write_guard
  BEFORE INSERT ON public.posts_comments
  FOR EACH ROW EXECUTE FUNCTION public._comments_write_guard();

DROP TRIGGER IF EXISTS whisper_comments_write_guard ON public.whisper_comments;
CREATE TRIGGER whisper_comments_write_guard
  BEFORE INSERT ON public.whisper_comments
  FOR EACH ROW EXECUTE FUNCTION public._comments_write_guard();

-- ============================================================
-- 7. Chat messages (DM + tribe): rate limit
--    (DM payloads are encrypted — no content rewriting there.)
-- ============================================================
CREATE OR REPLACE FUNCTION public._chat_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_min BIGINT;
BEGIN
  IF NEW.sender_id IS NULL THEN RETURN NEW; END IF;
  PERFORM _writer_state(NEW.sender_id);

  IF TG_TABLE_NAME = 'chat_messages' THEN
    SELECT count(*) INTO v_min FROM chat_messages
     WHERE sender_id = NEW.sender_id AND created_at > NOW() - INTERVAL '1 minute';
  ELSE
    SELECT count(*) INTO v_min FROM tribe_messages
     WHERE sender_id = NEW.sender_id AND created_at > NOW() - INTERVAL '1 minute';
    -- Tribe chat is plaintext — sanitize it like other public text.
    NEW.content := sanitize_user_text(NEW.content);
    IF length(COALESCE(NEW.content, '')) > 4000 THEN
      RAISE EXCEPTION 'Messages are capped at 4000 characters.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  PERFORM _guard_write(NEW.sender_id, 'messages', v_min, 120, 'minute');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_messages_write_guard ON public.chat_messages;
CREATE TRIGGER chat_messages_write_guard
  BEFORE INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public._chat_write_guard();

DROP TRIGGER IF EXISTS tribe_messages_write_guard ON public.tribe_messages;
CREATE TRIGGER tribe_messages_write_guard
  BEFORE INSERT ON public.tribe_messages
  FOR EACH ROW EXECUTE FUNCTION public._chat_write_guard();

-- ============================================================
-- 8. Friend requests: 20/hour
-- ============================================================
CREATE OR REPLACE FUNCTION public._friendships_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.requested_by IS NULL THEN RETURN NEW; END IF;
  PERFORM _writer_state(NEW.requested_by);
  PERFORM _guard_write(NEW.requested_by, 'friend requests',
    (SELECT count(*) FROM friendships
      WHERE requested_by = NEW.requested_by
        AND created_at > NOW() - INTERVAL '1 hour'),
    20, 'hour');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS friendships_write_guard ON public.friendships;
CREATE TRIGGER friendships_write_guard
  BEFORE INSERT ON public.friendships
  FOR EACH ROW EXECUTE FUNCTION public._friendships_write_guard();

-- ============================================================
-- 9. Reports: 20/day + sanitize the note
-- ============================================================
CREATE OR REPLACE FUNCTION public._reports_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.reporter_id IS NULL THEN RETURN NEW; END IF;
  NEW.note := sanitize_user_text(NEW.note);
  PERFORM _guard_write(NEW.reporter_id, 'reports',
    (SELECT count(*) FROM reports
      WHERE reporter_id = NEW.reporter_id
        AND created_at > NOW() - INTERVAL '24 hours'),
    20, 'day');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reports_write_guard ON public.reports;
CREATE TRIGGER reports_write_guard
  BEFORE INSERT ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public._reports_write_guard();

-- ============================================================
-- 10. Shadow ban: author still sees everything; everyone else doesn't.
--     feed_hot selects FROM feed_posts, so this covers both feeds, and
--     personal_feed reads feed_posts too.
-- ============================================================
CREATE OR REPLACE VIEW public.feed_posts WITH (security_invoker = true) AS
 SELECT p.post_id,
    p.author_id,
    COALESCE('@'::text || pr.pseudonym::text, '@'::text || u.anonymous_pseudonym::text, '@anonymous'::text) AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb'::character varying) AS author_avatar_seed,
        CASE
            WHEN p.persona_id IS NULL THEN u.profile_photo_url
            ELSE NULL::text
        END AS author_profile_photo_url,
    COALESCE(u.is_verified, false) AS author_is_verified,
    COALESCE(u.karma_points, 0) AS author_karma,
    p.persona_id,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.space_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_whisper,
    p.location_bucket,
    p.likes_count,
    p.comments_count,
    p.view_count,
    p.image_url,
    p.audio_url,
    p.audio_duration_seconds,
    p.crisis_level,
    p.created_at,
    p.edited_at,
    p.deleted_at,
    p.locked_at,
    p.is_keeper_pick,
    p.keeper_pick_at,
    p.media_status
   FROM posts p
     LEFT JOIN users u ON u.user_id = p.author_id
     LEFT JOIN personas pr ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
     LEFT JOIN tribes t ON t.tribe_id = p.tribe_id
  WHERE u.shadow_banned IS NOT TRUE
     OR p.author_id = (SELECT auth.uid());

-- ============================================================
-- 11. Admin controls: shadow ban + cooldown, audited
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_set_shadow_ban(
  p_user UUID, p_banned BOOLEAN, p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_label TEXT;
BEGIN
  IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = p_user;
  IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  UPDATE users SET shadow_banned = p_banned WHERE user_id = p_user;
  PERFORM admin_log(
    CASE WHEN p_banned THEN 'user.shadow_ban' ELSE 'user.shadow_unban' END,
    'user', p_user, v_label,
    NULL, jsonb_build_object('shadow_banned', p_banned),
    p_reason, '{}'::jsonb);
END;
$$;

-- Internal trigger helpers are not public RPC endpoints. Trigger execution is
-- unaffected by revoking direct calls from Data API roles.
REVOKE ALL ON FUNCTION public._guard_write(UUID, TEXT, BIGINT, INT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._writer_state(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._posts_write_guard()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._comments_write_guard()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._chat_write_guard()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._friendships_write_guard()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._reports_write_guard()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.admin_set_shadow_ban(UUID, BOOLEAN, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_shadow_ban(UUID, BOOLEAN, TEXT)
  TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_set_posting_cooldown(
  p_user UUID, p_until TIMESTAMPTZ, p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_label TEXT;
BEGIN
  IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = p_user;
  IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  UPDATE users SET posting_cooldown_until = p_until WHERE user_id = p_user;
  PERFORM admin_log('user.posting_cooldown', 'user', p_user, v_label,
    NULL, jsonb_build_object('posting_cooldown_until', p_until),
    p_reason, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_posting_cooldown(UUID, TIMESTAMPTZ, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_posting_cooldown(UUID, TIMESTAMPTZ, TEXT)
  TO authenticated;
