-- Separate public display names from stable @usernames, close every direct
-- self-engagement write path, and add a rights-gated music catalog for Vents
-- and Stories. All client mutations derive the actor from auth.uid().

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Canonical profile identity
-- ---------------------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS display_name TEXT,
  ADD COLUMN IF NOT EXISTS display_name_normalized TEXT,
  ADD COLUMN IF NOT EXISTS username_normalized TEXT;

-- Convert legacy handles into readable initial display names without changing
-- the stable username used for login, mentions, and deep links.
UPDATE public.users
   SET display_name = COALESCE(
         NULLIF(btrim(display_name), ''),
         btrim(
           regexp_replace(
             replace(anonymous_pseudonym, '_', ' '),
             '([[:lower:][:digit:]])([[:upper:]])',
             '\1 \2',
             'g'
           )
         )
       );

CREATE OR REPLACE FUNCTION private.normalize_display_name(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT regexp_replace(
    normalize(pg_catalog.btrim(COALESCE(p_value, '')), NFC),
    '[[:space:]]+',
    ' ',
    'g'
  );
$$;

CREATE OR REPLACE FUNCTION private.guard_user_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_display TEXT;
  v_username TEXT;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.anonymous_pseudonym IS DISTINCT FROM OLD.anonymous_pseudonym THEN
    RAISE EXCEPTION 'username_changes_disabled';
  END IF;

  v_username := pg_catalog.btrim(COALESCE(NEW.anonymous_pseudonym, ''));
  IF pg_catalog.char_length(v_username) NOT BETWEEN 3 AND 24
     OR v_username !~ '^[A-Za-z0-9_]+$' THEN
    RAISE EXCEPTION 'invalid_username';
  END IF;

  v_display := private.normalize_display_name(
    COALESCE(NULLIF(NEW.display_name, ''), v_username)
  );
  IF pg_catalog.char_length(v_display) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'invalid_display_name_length';
  END IF;
  -- Reject controls, invisible/bidi format characters, and HTML delimiters.
  -- Flutter renders plain text, but the database invariant also protects
  -- future web/admin surfaces from unsafe identity strings.
  IF v_display ~ U&'[\0001-\001F\007F-\009F\200B-\200F\202A-\202E\2060-\206F<>]' THEN
    RAISE EXCEPTION 'invalid_display_name_characters';
  END IF;

  NEW.anonymous_pseudonym := v_username;
  NEW.username_normalized := pg_catalog.lower(v_username);
  NEW.display_name := v_display;
  NEW.display_name_normalized := pg_catalog.lower(v_display);
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.normalize_display_name(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.guard_user_identity() FROM PUBLIC;

DROP TRIGGER IF EXISTS users_identity_guard ON public.users;
CREATE TRIGGER users_identity_guard
  BEFORE INSERT OR UPDATE OF anonymous_pseudonym, display_name
  ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION private.guard_user_identity();

-- Run the canonical normalizer once for existing rows before constraints.
UPDATE public.users
   SET anonymous_pseudonym = anonymous_pseudonym,
       display_name = display_name;

ALTER TABLE public.users
  ALTER COLUMN display_name SET NOT NULL,
  ALTER COLUMN display_name_normalized SET NOT NULL,
  ALTER COLUMN username_normalized SET NOT NULL;

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_display_name_length_check,
  DROP CONSTRAINT IF EXISTS users_display_name_trimmed_check,
  DROP CONSTRAINT IF EXISTS users_username_normalized_check,
  DROP CONSTRAINT IF EXISTS users_display_name_normalized_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_display_name_length_check
    CHECK (char_length(display_name) BETWEEN 1 AND 50),
  ADD CONSTRAINT users_display_name_trimmed_check
    CHECK (display_name = btrim(display_name)),
  ADD CONSTRAINT users_username_normalized_check
    CHECK (username_normalized = lower(anonymous_pseudonym)),
  ADD CONSTRAINT users_display_name_normalized_check
    CHECK (display_name_normalized = lower(display_name));

CREATE UNIQUE INDEX IF NOT EXISTS users_username_normalized_unique
  ON public.users (username_normalized);
CREATE INDEX IF NOT EXISTS users_display_name_normalized_trgm
  ON public.users USING gin (display_name_normalized public.gin_trgm_ops);

-- Supabase's 2026 Data API defaults no longer grant new columns implicitly.
GRANT SELECT (display_name) ON public.users TO anon, authenticated;

-- Replace the profile mutation with one atomic contract. Username changes are
-- intentionally disabled: the username is also the synthetic Supabase Auth
-- login handle, and changing only public.users would strand the account.
-- Both signatures, because this migration has to survive being re-run.
-- Dropping only 0073's eight-argument version left the nine-argument one this
-- file creates (it adds p_display_name) in place, so a run that got this far
-- and stopped later could never be finished: every retry died on the bare
-- CREATE below with 42723 "function already exists with same argument types".
DROP FUNCTION IF EXISTS public.update_my_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN
);
DROP FUNCTION IF EXISTS public.update_my_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, TEXT
);

CREATE FUNCTION public.update_my_profile(
  p_pseudonym          TEXT DEFAULT NULL,
  p_bio                TEXT DEFAULT NULL,
  p_pronouns           TEXT DEFAULT NULL,
  p_profile_photo_url  TEXT DEFAULT NULL,
  p_home_city          TEXT DEFAULT NULL,
  p_clear_photo        BOOLEAN DEFAULT FALSE,
  p_clear_bio          BOOLEAN DEFAULT FALSE,
  p_clear_pronouns     BOOLEAN DEFAULT FALSE,
  p_display_name       TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_current_username TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('profile_update', 60, 20) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  SELECT u.anonymous_pseudonym
    INTO v_current_username
    FROM public.users AS u
   WHERE u.user_id = v_me
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'profile not found'; END IF;

  IF NULLIF(pg_catalog.btrim(p_pseudonym), '') IS NOT NULL
     AND pg_catalog.lower(pg_catalog.btrim(p_pseudonym))
         <> pg_catalog.lower(v_current_username) THEN
    RAISE EXCEPTION 'username_changes_disabled';
  END IF;

  UPDATE public.users AS u
     SET display_name = COALESCE(p_display_name, u.display_name),
         bio = CASE WHEN p_clear_bio THEN NULL
                    ELSE COALESCE(NULLIF(pg_catalog.btrim(p_bio), ''), u.bio) END,
         pronouns = CASE WHEN p_clear_pronouns THEN NULL
                         ELSE COALESCE(NULLIF(pg_catalog.btrim(p_pronouns), ''), u.pronouns) END,
         profile_photo_url = CASE WHEN p_clear_photo THEN NULL
                                  ELSE COALESCE(NULLIF(pg_catalog.btrim(p_profile_photo_url), ''), u.profile_photo_url) END,
         home_city = COALESCE(NULLIF(pg_catalog.btrim(p_home_city), ''), u.home_city),
         updated_at = now()
   WHERE u.user_id = v_me;
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_my_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, TEXT
) TO authenticated;

-- Mentions remain username-based, while autocomplete presents the readable
-- display name alongside the stable handle.
CREATE OR REPLACE FUNCTION public.resolve_tag(p_handle TEXT)
RETURNS TABLE (kind TEXT, id UUID, slug TEXT, display TEXT)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_handle TEXT := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_handle, ''), '@'));
BEGIN
  IF v_handle = '' THEN RETURN; END IF;

  RETURN QUERY
  SELECT 'user'::TEXT, u.user_id, NULL::TEXT, u.display_name::TEXT
    FROM public.users AS u
   WHERE u.username_normalized = v_handle
     AND u.deactivated_at IS NULL
     AND u.shadow_banned IS NOT TRUE
   LIMIT 1;
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY
  SELECT 'tribe'::TEXT, t.tribe_id, t.slug::TEXT, t.name::TEXT
    FROM public.tribes AS t
   WHERE pg_catalog.lower(t.slug) = v_handle
      OR pg_catalog.lower(pg_catalog.replace(t.name, ' ', '')) = v_handle
   LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_tag(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_tag(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.search_tag_candidates(
  p_prefix TEXT,
  p_limit INT DEFAULT 8
) RETURNS TABLE (
  kind TEXT,
  id UUID,
  handle TEXT,
  display TEXT,
  avatar_seed TEXT,
  is_friend BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_prefix TEXT := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_prefix, ''), '@'));
  v_limit INT := least(greatest(COALESCE(p_limit, 8), 1), 15);
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF pg_catalog.char_length(v_prefix) < 1 THEN RETURN; END IF;

  RETURN QUERY
  (
    SELECT 'user'::TEXT,
           u.user_id,
           u.anonymous_pseudonym::TEXT,
           u.display_name::TEXT,
           u.avatar_seed::TEXT,
           EXISTS (
             SELECT 1
               FROM public.friendships AS f
              WHERE f.status = 'accepted'
                AND ((f.user_a = v_me AND f.user_b = u.user_id)
                  OR (f.user_b = v_me AND f.user_a = u.user_id))
           ) AS is_friend
      FROM public.users AS u
     WHERE u.username_normalized LIKE v_prefix || '%'
       AND u.deactivated_at IS NULL
       AND u.shadow_banned IS NOT TRUE
       AND u.user_id <> v_me
     ORDER BY is_friend DESC, pg_catalog.char_length(u.anonymous_pseudonym)
     LIMIT v_limit
  )
  UNION ALL
  (
    SELECT 'tribe'::TEXT, t.tribe_id, t.slug::TEXT, t.name::TEXT,
           NULL::TEXT, FALSE
      FROM public.tribes AS t
     WHERE pg_catalog.lower(t.slug) LIKE v_prefix || '%'
        OR pg_catalog.lower(t.name) LIKE v_prefix || '%'
     ORDER BY pg_catalog.char_length(t.slug)
     LIMIT 4
  );
END;
$$;

REVOKE ALL ON FUNCTION public.search_tag_candidates(TEXT, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_tag_candidates(TEXT, INT)
  TO authenticated;

-- User-inclusive global search. Exact username wins; strong display-name
-- matches follow; existing tribe/post/topic results retain their contract.
DROP FUNCTION IF EXISTS private.search_user_hits(TEXT, TEXT, UUID, INT);

-- Safe-output bridge for global search. It lives in public so the invoker
-- function never needs USAGE on the private schema, and it derives the viewer
-- from auth.uid() so a modified client cannot forge a viewer to bypass blocks.
CREATE OR REPLACE FUNCTION public.search_user_hits(
  p_username TEXT,
  p_display TEXT,
  p_limit INT
) RETURNS TABLE (
  hit_kind TEXT, hit_id TEXT, title TEXT, subtitle TEXT,
  avatar_seed TEXT, profile_photo_url TEXT, member_count INT, post_count INT,
  likes_count INT, comments_count INT, created_at TIMESTAMPTZ, rank_score REAL
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_viewer UUID := (SELECT auth.uid());
BEGIN
  IF v_viewer IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('global_search', 60, 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  RETURN QUERY
  SELECT
    'user'::TEXT,
    u.user_id::TEXT,
    u.display_name::TEXT,
    ('@' || u.anonymous_pseudonym)::TEXT,
    u.avatar_seed::TEXT,
    u.profile_photo_url::TEXT,
    NULL::INT, NULL::INT, NULL::INT, NULL::INT,
    u.created_at,
    (
      CASE WHEN u.username_normalized = p_username THEN 12.0
           WHEN u.username_normalized LIKE p_username || '%' THEN 8.0
           ELSE 0.0 END
      + CASE WHEN u.display_name_normalized = p_display THEN 10.0
             WHEN u.display_name_normalized LIKE p_display || '%' THEN 7.0
             ELSE public.similarity(u.display_name_normalized, p_display) * 4.0 END
    )::REAL
  FROM public.users AS u
  WHERE u.deactivated_at IS NULL
    AND u.shadow_banned IS NOT TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks AS b
       WHERE (b.blocker_id = v_viewer AND b.blocked_id = u.user_id)
          OR (b.blocked_id = v_viewer AND b.blocker_id = u.user_id)
    )
    AND (
      u.username_normalized = p_username
      OR u.username_normalized LIKE p_username || '%'
      OR u.display_name_normalized LIKE '%' || p_display || '%'
      OR public.similarity(u.display_name_normalized, p_display) > 0.30
    )
  ORDER BY 12 DESC, u.created_at DESC
  LIMIT least(greatest(COALESCE(p_limit, 24), 1), 60);
END;
$$;

REVOKE ALL ON FUNCTION public.search_user_hits(TEXT, TEXT, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_user_hits(TEXT, TEXT, INT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.search_global(
  p_query TEXT,
  p_limit INT DEFAULT 24
) RETURNS TABLE (
  hit_kind TEXT,
  hit_id TEXT,
  title TEXT,
  subtitle TEXT,
  avatar_seed TEXT,
  profile_photo_url TEXT,
  member_count INT,
  post_count INT,
  likes_count INT,
  comments_count INT,
  created_at TIMESTAMPTZ,
  rank_score REAL
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_query TEXT := regexp_replace(
    normalize(pg_catalog.btrim(COALESCE(p_query, '')), NFC),
    '[[:space:]]+', ' ', 'g'
  );
  v_normalized TEXT := pg_catalog.lower(regexp_replace(
    normalize(pg_catalog.btrim(COALESCE(p_query, '')), NFC),
    '[[:space:]]+', ' ', 'g'
  ));
  v_username TEXT := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_query, ''), '@'));
  v_pat TEXT;
BEGIN
  IF pg_catalog.char_length(v_query) < 2 THEN RETURN; END IF;
  v_pat := '%' || v_query || '%';

  RETURN QUERY
  WITH blocks AS (
    SELECT b.blocked_id AS user_id
      FROM public.user_blocks AS b
     WHERE b.blocker_id = v_uid
    UNION
    SELECT b.blocker_id
      FROM public.user_blocks AS b
     WHERE b.blocked_id = v_uid
  ),
  user_hits AS (
    SELECT *
      FROM public.search_user_hits(v_username, v_normalized, p_limit)
  ),
  tribe_hits AS (
    SELECT 'tribe'::TEXT, t.slug::TEXT, t.name::TEXT,
           COALESCE(t.description, '')::TEXT,
           NULL::TEXT, NULL::TEXT, COALESCE(t.member_count, 0)::INT,
           NULL::INT, NULL::INT, NULL::INT, t.created_at,
           (CASE WHEN t.name ILIKE v_pat THEN 3.0 ELSE 0 END
            + CASE WHEN t.description ILIKE v_pat THEN 1.0 ELSE 0 END
            + pg_catalog.ln(greatest(COALESCE(t.member_count, 0), 1)) * 0.15)::REAL
      FROM public.tribes AS t
     WHERE t.name ILIKE v_pat OR t.description ILIKE v_pat
  ),
  post_hits AS (
    SELECT 'post'::TEXT, p.post_id::TEXT,
           pg_catalog.left(p.content, 240)::TEXT,
           CASE WHEN p.persona_id IS NULL
                THEN COALESCE(u.display_name, p.author_pseudonym, 'Anonymous')
                ELSE COALESCE(p.author_pseudonym, 'Anonymous') END::TEXT,
           COALESCE(p.author_avatar_seed, 'default-orb')::TEXT,
           p.author_profile_photo_url::TEXT,
           NULL::INT, NULL::INT, p.likes_count, p.comments_count, p.created_at,
           (2.0
            + pg_catalog.ln(greatest(p.likes_count + p.comments_count, 1)) * 0.4
            - (extract(EPOCH FROM now() - p.created_at) / 86400.0) * 0.05)::REAL
      FROM public.feed_posts AS p
      LEFT JOIN public.users AS u ON u.user_id = p.author_id
     WHERE p.is_whisper = FALSE
       AND p.content ILIKE v_pat
       AND (v_uid IS NULL OR p.author_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM blocks AS b WHERE b.user_id = p.author_id
       ))
  ),
  topic_hits AS (
    SELECT 'topic'::TEXT, c.cat::TEXT, c.cat::TEXT,
           ((SELECT count(*) FROM public.posts AS pp
              WHERE pp.category_name = c.cat AND pp.deleted_at IS NULL
                AND pp.created_at > now() - INTERVAL '7 days')::TEXT
             || ' posts in last 7d')::TEXT,
           NULL::TEXT, NULL::TEXT, NULL::INT,
           (SELECT count(*)::INT FROM public.posts AS pp
             WHERE pp.category_name = c.cat AND pp.deleted_at IS NULL
               AND pp.created_at > now() - INTERVAL '7 days'),
           NULL::INT, NULL::INT, NULL::TIMESTAMPTZ, 2.5::REAL
      FROM (VALUES
        ('confessions'),('testimonies'),('relationships'),('family_issues'),
        ('mental_health'),('campus_life'),('adulting'),('regrets'),('trauma'),
        ('friendship'),('faith_spirituality'),('questions'),('secrets'),
        ('vent_zone'),('dark_thoughts'),('funny_confessions'),('dreams_goals'),
        ('hot_takes'),('late_night'),('healing_corner')
      ) AS c(cat)
     WHERE c.cat ILIKE v_pat
  )
  SELECT *
    FROM (
      SELECT * FROM user_hits
      UNION ALL SELECT * FROM tribe_hits
      UNION ALL SELECT * FROM post_hits
      UNION ALL SELECT * FROM topic_hits
    ) AS merged
   ORDER BY rank_score DESC NULLS LAST, created_at DESC NULLS LAST
   LIMIT greatest(1, least(COALESCE(p_limit, 24), 60));
END;
$$;

REVOKE ALL ON FUNCTION public.search_global(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_global(TEXT, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Self-interaction enforcement and idempotent desired-state RPCs
-- ---------------------------------------------------------------------------

-- Remove historical invalid engagement before installing the invariant, then
-- reconcile every denormalized counter from source rows.
DELETE FROM public.post_likes AS reaction
USING public.posts AS post
WHERE post.post_id = reaction.post_id
  AND post.author_id = reaction.user_id;

DELETE FROM public.comment_likes AS reaction
USING public.posts_comments AS comment
WHERE comment.comment_id = reaction.comment_id
  AND comment.author_id = reaction.user_id;

DELETE FROM public.whisper_reactions AS reaction
USING public.whispers AS whisper
WHERE whisper.whisper_id = reaction.whisper_id
  AND whisper.author_id = reaction.user_id;

DELETE FROM public.whisper_comment_likes AS reaction
USING public.whisper_comments AS comment
WHERE comment.comment_id = reaction.comment_id
  AND comment.author_id = reaction.user_id;

DELETE FROM public.poll_votes AS vote
USING public.post_polls AS poll, public.posts AS post
WHERE poll.poll_id = vote.poll_id
  AND post.post_id = poll.post_id
  AND post.author_id = vote.user_id;

UPDATE public.posts AS post
   SET likes_count = (
     SELECT count(*)::INT FROM public.post_likes AS reaction
      WHERE reaction.post_id = post.post_id
   );
UPDATE public.posts_comments AS comment
   SET likes_count = (
     SELECT count(*)::INT FROM public.comment_likes AS reaction
      WHERE reaction.comment_id = comment.comment_id
   );
UPDATE public.whispers AS whisper
   SET likes_count = (
     SELECT count(*)::INT FROM public.whisper_reactions AS reaction
      WHERE reaction.whisper_id = whisper.whisper_id
   );
UPDATE public.whisper_comments AS comment
   SET likes_count = (
     SELECT count(*)::INT FROM public.whisper_comment_likes AS reaction
      WHERE reaction.comment_id = comment.comment_id
   );

CREATE OR REPLACE FUNCTION private.guard_no_self_interaction()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_new JSONB := to_jsonb(NEW);
BEGIN
  IF TG_TABLE_NAME = 'post_likes' AND EXISTS (
    SELECT 1 FROM public.posts AS p
     WHERE p.post_id = (v_new->>'post_id')::UUID
       AND p.author_id = (v_new->>'user_id')::UUID
  ) THEN
    RAISE EXCEPTION 'self_interaction_not_allowed';
  ELSIF TG_TABLE_NAME = 'comment_likes' AND EXISTS (
    SELECT 1 FROM public.posts_comments AS c
     WHERE c.comment_id = (v_new->>'comment_id')::UUID
       AND c.author_id = (v_new->>'user_id')::UUID
  ) THEN
    RAISE EXCEPTION 'self_interaction_not_allowed';
  ELSIF TG_TABLE_NAME = 'whisper_reactions' AND EXISTS (
    SELECT 1 FROM public.whispers AS w
     WHERE w.whisper_id = (v_new->>'whisper_id')::UUID
       AND w.author_id = (v_new->>'user_id')::UUID
  ) THEN
    RAISE EXCEPTION 'self_interaction_not_allowed';
  ELSIF TG_TABLE_NAME = 'whisper_comment_likes' AND EXISTS (
    SELECT 1 FROM public.whisper_comments AS c
     WHERE c.comment_id = (v_new->>'comment_id')::UUID
       AND c.author_id = (v_new->>'user_id')::UUID
  ) THEN
    RAISE EXCEPTION 'self_interaction_not_allowed';
  ELSIF TG_TABLE_NAME = 'poll_votes' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.poll_options AS option
       WHERE option.option_id = (v_new->>'option_id')::UUID
         AND option.poll_id = (v_new->>'poll_id')::UUID
    ) THEN
      RAISE EXCEPTION 'poll_option_mismatch';
    END IF;
    IF EXISTS (
      SELECT 1
        FROM public.post_polls AS poll
        JOIN public.posts AS post ON post.post_id = poll.post_id
       WHERE poll.poll_id = (v_new->>'poll_id')::UUID
         AND post.author_id = (v_new->>'user_id')::UUID
    ) THEN
      RAISE EXCEPTION 'self_interaction_not_allowed';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.guard_no_self_interaction() FROM PUBLIC;

DROP TRIGGER IF EXISTS no_self_post_reaction ON public.post_likes;
CREATE TRIGGER no_self_post_reaction
  BEFORE INSERT OR UPDATE ON public.post_likes
  FOR EACH ROW EXECUTE FUNCTION private.guard_no_self_interaction();
DROP TRIGGER IF EXISTS no_self_comment_like ON public.comment_likes;
CREATE TRIGGER no_self_comment_like
  BEFORE INSERT OR UPDATE ON public.comment_likes
  FOR EACH ROW EXECUTE FUNCTION private.guard_no_self_interaction();
DROP TRIGGER IF EXISTS no_self_whisper_reaction ON public.whisper_reactions;
CREATE TRIGGER no_self_whisper_reaction
  BEFORE INSERT OR UPDATE ON public.whisper_reactions
  FOR EACH ROW EXECUTE FUNCTION private.guard_no_self_interaction();
DROP TRIGGER IF EXISTS no_self_whisper_comment_like ON public.whisper_comment_likes;
CREATE TRIGGER no_self_whisper_comment_like
  BEFORE INSERT OR UPDATE ON public.whisper_comment_likes
  FOR EACH ROW EXECUTE FUNCTION private.guard_no_self_interaction();
DROP TRIGGER IF EXISTS no_self_poll_vote ON public.poll_votes;
CREATE TRIGGER no_self_poll_vote
  BEFORE INSERT OR UPDATE ON public.poll_votes
  FOR EACH ROW EXECUTE FUNCTION private.guard_no_self_interaction();

-- Direct comment-like writes now update the same authoritative counter as RPCs.
CREATE OR REPLACE FUNCTION private.sync_comment_like_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_comment UUID := COALESCE(NEW.comment_id, OLD.comment_id);
BEGIN
  UPDATE public.posts_comments AS comment
     SET likes_count = (
       SELECT count(*)::INT
         FROM public.comment_likes AS reaction
        WHERE reaction.comment_id = v_comment
     )
   WHERE comment.comment_id = v_comment;
  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION private.sync_comment_like_count() FROM PUBLIC;
DROP TRIGGER IF EXISTS comment_likes_count_sync ON public.comment_likes;
CREATE TRIGGER comment_likes_count_sync
  AFTER INSERT OR DELETE ON public.comment_likes
  FOR EACH ROW EXECUTE FUNCTION private.sync_comment_like_count();

CREATE OR REPLACE FUNCTION public.set_post_reaction(
  p_post_id UUID,
  p_reaction TEXT
) RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('post_reaction', 60, 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT p.author_id INTO v_author
    FROM public.posts AS p
   WHERE p.post_id = p_post_id AND p.deleted_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'post not found'; END IF;
  IF v_author = v_me THEN RAISE EXCEPTION 'self_interaction_not_allowed'; END IF;
  IF p_reaction IS NOT NULL AND p_reaction NOT IN
     ('hug','love','strong','hope','pray','felt','proud') THEN
    RAISE EXCEPTION 'invalid reaction';
  END IF;

  IF p_reaction IS NULL THEN
    DELETE FROM public.post_likes
     WHERE post_id = p_post_id AND user_id = v_me;
    RETURN NULL;
  END IF;
  INSERT INTO public.post_likes (post_id, user_id, reaction_type)
  VALUES (p_post_id, v_me, p_reaction::public.reaction_type)
  ON CONFLICT (post_id, user_id) DO UPDATE
    SET reaction_type = EXCLUDED.reaction_type;
  RETURN p_reaction;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_comment_like(
  p_comment_id UUID,
  p_liked BOOLEAN
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('comment_reaction', 60, 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT c.author_id INTO v_author
    FROM public.posts_comments AS c
   WHERE c.comment_id = p_comment_id AND c.deleted_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'comment not found'; END IF;
  IF v_author = v_me THEN RAISE EXCEPTION 'self_interaction_not_allowed'; END IF;
  IF COALESCE(p_liked, FALSE) THEN
    INSERT INTO public.comment_likes (comment_id, user_id)
    VALUES (p_comment_id, v_me)
    ON CONFLICT (comment_id, user_id) DO NOTHING;
    RETURN TRUE;
  END IF;
  DELETE FROM public.comment_likes
   WHERE comment_id = p_comment_id AND user_id = v_me;
  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_whisper_reaction_v2(
  p_whisper_id UUID,
  p_reaction TEXT
) RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('whisper_reaction', 60, 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT w.author_id INTO v_author
    FROM public.whispers AS w
   WHERE w.whisper_id = p_whisper_id AND w.deleted_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'whisper not found'; END IF;
  IF v_author = v_me THEN RAISE EXCEPTION 'self_interaction_not_allowed'; END IF;
  IF p_reaction IS NOT NULL AND p_reaction NOT IN
     ('hug','love','strong','hope','pray','felt','proud') THEN
    RAISE EXCEPTION 'invalid reaction';
  END IF;
  IF p_reaction IS NULL THEN
    DELETE FROM public.whisper_reactions
     WHERE whisper_id = p_whisper_id AND user_id = v_me;
    RETURN NULL;
  END IF;
  INSERT INTO public.whisper_reactions (whisper_id, user_id, reaction_type)
  VALUES (p_whisper_id, v_me, p_reaction)
  ON CONFLICT (whisper_id, user_id) DO UPDATE
    SET reaction_type = EXCLUDED.reaction_type;
  RETURN p_reaction;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_whisper_comment_like(
  p_comment_id UUID,
  p_liked BOOLEAN
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('whisper_comment_reaction', 60, 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT c.author_id INTO v_author
    FROM public.whisper_comments AS c
   WHERE c.comment_id = p_comment_id AND c.deleted_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'comment not found'; END IF;
  IF v_author = v_me THEN RAISE EXCEPTION 'self_interaction_not_allowed'; END IF;
  IF COALESCE(p_liked, FALSE) THEN
    INSERT INTO public.whisper_comment_likes (comment_id, user_id)
    VALUES (p_comment_id, v_me)
    ON CONFLICT (comment_id, user_id) DO NOTHING;
    RETURN TRUE;
  END IF;
  DELETE FROM public.whisper_comment_likes
   WHERE comment_id = p_comment_id AND user_id = v_me;
  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.cast_poll_vote(
  p_poll_id UUID,
  p_option_id UUID
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_vote UUID;
  v_author UUID;
  v_closes_at TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT public.claim_rate_limit('poll_vote', 60, 60) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT post.author_id, poll.closes_at
    INTO v_author, v_closes_at
    FROM public.post_polls AS poll
    JOIN public.posts AS post ON post.post_id = poll.post_id
   WHERE poll.poll_id = p_poll_id AND post.deleted_at IS NULL
   FOR SHARE OF poll, post;
  IF NOT FOUND THEN RAISE EXCEPTION 'poll not found'; END IF;
  IF v_author = v_me THEN RAISE EXCEPTION 'self_interaction_not_allowed'; END IF;
  IF v_closes_at <= now() THEN RAISE EXCEPTION 'poll closed'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.poll_options AS option
     WHERE option.option_id = p_option_id AND option.poll_id = p_poll_id
  ) THEN
    RAISE EXCEPTION 'poll_option_mismatch';
  END IF;

  INSERT INTO public.poll_votes (poll_id, option_id, user_id)
  VALUES (p_poll_id, p_option_id, v_me)
  ON CONFLICT (poll_id, user_id) DO UPDATE
    SET option_id = public.poll_votes.option_id
  RETURNING vote_id INTO v_vote;
  RETURN v_vote;
END;
$$;

REVOKE ALL ON FUNCTION public.set_post_reaction(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_comment_like(UUID, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_whisper_reaction_v2(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_whisper_comment_like(UUID, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cast_poll_vote(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_post_reaction(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_comment_like(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_whisper_reaction_v2(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_whisper_comment_like(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cast_poll_vote(UUID, UUID) TO authenticated;

-- Legacy toggle RPCs remain callable during rolling upgrades, but the table
-- triggers above still reject self-engagement from old or modified clients.
CREATE OR REPLACE FUNCTION public.toggle_comment_like(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_liked BOOLEAN;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT NOT EXISTS (
    SELECT 1 FROM public.comment_likes AS reaction
     WHERE reaction.comment_id = p_comment_id AND reaction.user_id = v_me
  ) INTO v_liked;
  RETURN public.set_comment_like(p_comment_id, v_liked);
END;
$$;
REVOKE ALL ON FUNCTION public.toggle_comment_like(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.toggle_comment_like(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Rights-gated music catalog and post/story attachments
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.music_tracks (
  track_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL,
  provider_track_id TEXT NOT NULL,
  title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 160),
  artist TEXT NOT NULL CHECK (char_length(artist) BETWEEN 1 AND 160),
  album TEXT,
  artwork_url TEXT,
  preview_url TEXT NOT NULL,
  duration_ms INT NOT NULL CHECK (duration_ms BETWEEN 3000 AND 60000),
  genre TEXT,
  mood_tags TEXT[] NOT NULL DEFAULT '{}',
  license_code TEXT NOT NULL,
  license_url TEXT NOT NULL,
  rights_holder TEXT NOT NULL,
  rights_expires_at TIMESTAMPTZ,
  allowed_regions TEXT[] NOT NULL DEFAULT '{}',
  attribution_text TEXT,
  is_active BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_track_id),
  CHECK (provider IN ('venttly_original','licensed_catalog','royalty_free','external_streaming')),
  CHECK (license_code IN ('VENTTLY_ORIGINAL','CC0','CC_BY','COMMERCIAL')),
  CHECK (NOT is_active OR (
    char_length(btrim(preview_url)) > 0
    AND char_length(btrim(license_url)) > 0
    AND char_length(btrim(rights_holder)) > 0
  )),
  CHECK (license_code <> 'CC_BY' OR NULLIF(btrim(attribution_text), '') IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS music_tracks_active_recent_idx
  ON public.music_tracks (created_at DESC, track_id)
  WHERE is_active;
CREATE INDEX IF NOT EXISTS music_tracks_title_trgm_idx
  ON public.music_tracks USING gin (title public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS music_tracks_artist_trgm_idx
  ON public.music_tracks USING gin (artist public.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS music_tracks_moods_idx
  ON public.music_tracks USING gin (mood_tags);

ALTER TABLE public.music_tracks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.music_tracks FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.music_tracks TO authenticated;

INSERT INTO public.feature_flags (flag_key, enabled, rollout_pct, description, metadata)
VALUES (
  'vent_music', FALSE, 0,
  'Rights-gated music previews on Vents and Stories',
  '{"kill_switch":true,"provider":"venttly_original"}'::JSONB
)
ON CONFLICT (flag_key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.feature_enabled_for(
  p_flag TEXT,
  p_user UUID
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT flag.enabled AND (
      flag.rollout_pct >= 100
      OR (
        (pg_catalog.hashtextextended(COALESCE(p_user::TEXT, '') || flag.flag_key, 0)
          & 9223372036854775807) % 100
      ) < flag.rollout_pct
    )
      FROM public.feature_flags AS flag
     WHERE flag.flag_key = p_flag
  ), FALSE);
$$;

REVOKE ALL ON FUNCTION private.feature_enabled_for(TEXT, UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.music_enabled_for_me()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT (SELECT auth.uid()) IS NOT NULL
     AND private.feature_enabled_for('vent_music', (SELECT auth.uid()));
$$;
REVOKE ALL ON FUNCTION public.music_enabled_for_me() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.music_enabled_for_me() TO authenticated;

DROP POLICY IF EXISTS music_tracks_enabled_read ON public.music_tracks;
CREATE POLICY music_tracks_enabled_read
  ON public.music_tracks
  FOR SELECT
  TO authenticated
  USING (
    is_active
    AND (rights_expires_at IS NULL OR rights_expires_at > now())
    AND (SELECT public.music_enabled_for_me())
  );

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS music_track_id UUID
    REFERENCES public.music_tracks(track_id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS music_start_ms INT,
  ADD COLUMN IF NOT EXISTS music_duration_ms INT,
  ADD COLUMN IF NOT EXISTS music_volume REAL;

ALTER TABLE public.posts
  DROP CONSTRAINT IF EXISTS posts_music_window_check;
ALTER TABLE public.posts
  ADD CONSTRAINT posts_music_window_check CHECK (
    (music_track_id IS NULL
      AND music_start_ms IS NULL
      AND music_duration_ms IS NULL
      AND music_volume IS NULL)
    OR
    (music_track_id IS NOT NULL
      AND music_start_ms BETWEEN 0 AND 60000
      AND music_duration_ms BETWEEN 3000 AND 30000
      AND music_volume BETWEEN 0.0 AND 1.0)
  );

CREATE INDEX IF NOT EXISTS posts_music_track_idx
  ON public.posts (music_track_id)
  WHERE music_track_id IS NOT NULL AND deleted_at IS NULL;

-- New columns need explicit Data API privileges on current Supabase projects.
GRANT SELECT (
  music_track_id, music_start_ms, music_duration_ms, music_volume
) ON public.posts TO anon, authenticated;

CREATE OR REPLACE FUNCTION private.claim_music_quota(
  p_user UUID,
  p_action TEXT,
  p_max INT
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_started TIMESTAMPTZ;
  v_count INT;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('music:' || p_action || ':' || p_user::TEXT, 0)
  );
  SELECT rate.window_started_at, rate.counter
    INTO v_started, v_count
    FROM public.rate_limits AS rate
   WHERE rate.user_id = p_user AND rate.action_key = p_action
   FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.rate_limits (user_id, action_key, window_started_at, counter)
    VALUES (p_user, p_action, now(), 1);
    RETURN TRUE;
  ELSIF v_started <= now() - INTERVAL '1 minute' THEN
    UPDATE public.rate_limits SET window_started_at = now(), counter = 1
     WHERE user_id = p_user AND action_key = p_action;
    RETURN TRUE;
  ELSIF v_count >= p_max THEN
    RETURN FALSE;
  END IF;
  UPDATE public.rate_limits SET counter = counter + 1
   WHERE user_id = p_user AND action_key = p_action;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION private.claim_music_quota(UUID, TEXT, INT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.search_music(
  p_query TEXT DEFAULT '',
  p_mood TEXT DEFAULT NULL,
  p_limit INT DEFAULT 24,
  p_offset INT DEFAULT 0
) RETURNS SETOF public.music_tracks
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_query TEXT := pg_catalog.btrim(COALESCE(p_query, ''));
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.feature_enabled_for('vent_music', v_me) THEN RETURN; END IF;
  IF NOT private.claim_music_quota(v_me, 'music_search', 120) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  RETURN QUERY
  SELECT track.*
    FROM public.music_tracks AS track
   WHERE track.is_active
     AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now())
     AND (p_mood IS NULL OR p_mood = ANY(track.mood_tags))
     AND (
       v_query = ''
       OR track.title ILIKE '%' || v_query || '%'
       OR track.artist ILIKE '%' || v_query || '%'
       OR track.genre ILIKE '%' || v_query || '%'
       OR public.similarity(track.title, v_query) > 0.30
       OR public.similarity(track.artist, v_query) > 0.30
     )
   ORDER BY
     CASE WHEN pg_catalog.lower(track.title) = pg_catalog.lower(v_query) THEN 0 ELSE 1 END,
     public.similarity(track.title, v_query) DESC,
     track.created_at DESC,
     track.track_id
   OFFSET greatest(COALESCE(p_offset, 0), 0)
   LIMIT least(greatest(COALESCE(p_limit, 24), 1), 50);
END;
$$;

CREATE OR REPLACE FUNCTION public.music_tracks_by_ids(p_track_ids UUID[])
RETURNS SETOF public.music_tracks
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT track.*
    FROM public.music_tracks AS track
   WHERE (SELECT auth.uid()) IS NOT NULL
     AND private.feature_enabled_for('vent_music', (SELECT auth.uid()))
     AND track.is_active
     AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now())
     AND track.track_id = ANY(COALESCE(p_track_ids, '{}'::UUID[]))
   LIMIT 100;
$$;

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
  v_track_duration INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.claim_music_quota(v_me, 'music_attachment', 30) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  SELECT post.author_id INTO v_author
    FROM public.posts AS post
   WHERE post.post_id = p_post_id AND post.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'post not found'; END IF;
  IF v_author <> v_me THEN RAISE EXCEPTION 'not your post'; END IF;

  IF p_music_track_id IS NULL THEN
    UPDATE public.posts
       SET music_track_id = NULL,
           music_start_ms = NULL,
           music_duration_ms = NULL,
           music_volume = NULL
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
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_post_idempotent_v4(
  p_mutation_id UUID,
  p_content TEXT,
  p_category_name TEXT,
  p_post_mood TEXT,
  p_tribe_id UUID DEFAULT NULL,
  p_space_id UUID DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL,
  p_is_whisper BOOLEAN DEFAULT FALSE,
  p_is_story BOOLEAN DEFAULT FALSE,
  p_story_audience TEXT DEFAULT 'everyone',
  p_image_path TEXT DEFAULT NULL,
  p_image_url TEXT DEFAULT NULL,
  p_audio_path TEXT DEFAULT NULL,
  p_audio_url TEXT DEFAULT NULL,
  p_audio_duration_seconds INTEGER DEFAULT NULL,
  p_poll_question TEXT DEFAULT NULL,
  p_poll_options TEXT[] DEFAULT NULL,
  p_card_background_color TEXT DEFAULT NULL,
  p_card_text_color TEXT DEFAULT NULL,
  p_music_track_id UUID DEFAULT NULL,
  p_music_start_ms INT DEFAULT 0,
  p_music_duration_ms INT DEFAULT 15000,
  p_music_volume REAL DEFAULT 0.75
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_post_id UUID;
BEGIN
  v_post_id := public.create_post_idempotent_v3(
    p_mutation_id => p_mutation_id,
    p_content => p_content,
    p_category_name => p_category_name,
    p_post_mood => p_post_mood,
    p_tribe_id => p_tribe_id,
    p_space_id => p_space_id,
    p_persona_id => p_persona_id,
    p_is_whisper => p_is_whisper,
    p_is_story => p_is_story,
    p_story_audience => p_story_audience,
    p_image_path => p_image_path,
    p_image_url => p_image_url,
    p_audio_path => p_audio_path,
    p_audio_url => p_audio_url,
    p_audio_duration_seconds => p_audio_duration_seconds,
    p_poll_question => p_poll_question,
    p_poll_options => p_poll_options,
    p_card_background_color => p_card_background_color,
    p_card_text_color => p_card_text_color
  );
  IF p_music_track_id IS NOT NULL THEN
    PERFORM public.set_post_music(
      v_post_id,
      p_music_track_id,
      p_music_start_ms,
      p_music_duration_ms,
      p_music_volume
    );
  END IF;
  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.search_music(TEXT, TEXT, INT, INT)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.music_tracks_by_ids(UUID[])
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_post_music(UUID, UUID, INT, INT, REAL)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_post_idempotent_v4(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN, BOOLEAN, TEXT,
  TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT, TEXT,
  UUID, INT, INT, REAL
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_music(TEXT, TEXT, INT, INT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.music_tracks_by_ids(UUID[])
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_post_music(UUID, UUID, INT, INT, REAL)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_post_idempotent_v4(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN, BOOLEAN, TEXT,
  TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT, TEXT,
  UUID, INT, INT, REAL
) TO authenticated;

-- Algorithmically composed repository preview. It is bundled with the app;
-- the row stores metadata/reference only. The server flag remains disabled by
-- default until the release owner records rollout approval.
INSERT INTO public.music_tracks (
  track_id, provider, provider_track_id, title, artist, album,
  preview_url, duration_ms, genre, mood_tags,
  license_code, license_url, rights_holder, attribution_text, is_active
) VALUES (
  'a7100000-0000-4000-8000-000000000001',
  'venttly_original', 'afterglow-v1', 'Afterglow', 'Venttly Originals',
  'Quiet Rooms', 'asset:///assets/audio/afterglow.wav', 30000, 'ambient',
  ARRAY['healing','late_night','peaceful','heartbreak'],
  'VENTTLY_ORIGINAL', 'https://venttly.app/legal/music/venttly-originals-v1',
  'Venttly', 'Afterglow — Venttly Originals', TRUE
)
ON CONFLICT (provider, provider_track_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
