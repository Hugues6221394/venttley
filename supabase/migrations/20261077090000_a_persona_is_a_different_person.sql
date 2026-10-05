-- A persona is a different person, to everybody except the person behind it.
--
-- Two defects, and the first is not a leak so much as the feature running
-- backwards.
--
-- 1. A persona post showed the author's REAL handle to every reader. The view
--    resolves the display name as
--        COALESCE('@' || persona.pseudonym, '@' || users.anonymous_pseudonym)
--    and personas carry one RLS policy — "personas owner read". So the persona
--    row is visible to its owner and to nobody else, the COALESCE falls
--    through for every other reader, and the account's own handle is printed
--    under the post. The persona was visible only to the one person who
--    already knew who they were.
--
-- 2. posts.author_id is readable by any signed-in client, straight off the
--    table and through the view. Two posts by the same account — one as
--    themselves, one behind a persona — carry the same author_id, so the link
--    is not merely discoverable, it is a join.
--
-- The fix is one idea: in everything a reader can see, `author_id` stops
-- meaning *the account* and starts meaning *the voice*. For an ordinary post
-- that is still the account and nothing changes. For a persona post it is the
-- persona's own id — not the account's, stable, and safe to hand out.
--
-- That falls out well everywhere downstream, because "the voice" is what those
-- places actually meant:
--
--   "show me less of this person"  mutes the persona, not the human behind it
--                                  — and post_not_interested stores a row the
--                                  muter can read, so storing the account
--                                  there was a second way to unmask one
--   author diversity               a persona cannot flood the feed either
--   friend and affinity bonuses    you are not friends with a persona, so a
--                                  persona post no longer inherits the warmth
--                                  of the account behind it — which was also
--                                  how you would have spotted it
--
-- Verification and karma are dropped for persona posts on the same grounds: a
-- verified tick on a persona post narrows its author to the handful of
-- verified accounts, and a karma figure is a near-unique number.

-- ── the two keys ──────────────────────────────────────────────────────────
--
-- Generated rather than maintained by trigger: they are a pure function of two
-- columns of the same row, so there is no state to drift and no backfill to
-- forget. They exist because the readable paths must not reference author_id
-- at all once it is revoked below — a security_invoker view runs with the
-- caller's privileges, so a column the caller cannot read is a column the view
-- cannot read either.

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS display_author_id UUID
    GENERATED ALWAYS AS (CASE WHEN persona_id IS NULL THEN author_id END) STORED;

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS feed_author_key UUID
    GENERATED ALWAYS AS (COALESCE(persona_id, author_id)) STORED;

COMMENT ON COLUMN public.posts.display_author_id IS
  'The account, when the post is not behind a persona. NULL when it is — so a '
  'join to users cannot resolve a persona post to its author.';

COMMENT ON COLUMN public.posts.feed_author_key IS
  'The voice that wrote this: the persona if there is one, otherwise the '
  'account. What every reader-facing surface means by "author".';

CREATE INDEX IF NOT EXISTS posts_feed_author_key_idx
  ON public.posts (feed_author_key, created_at DESC);

-- ── the persona card ──────────────────────────────────────────────────────
--
-- personas keeps its owner-only RLS, because personas.user_id is the link and
-- opening the table up would hand it over. A definer function returning only
-- the display fields gives a reader what they need to see a post and nothing
-- that says whose it is.

CREATE OR REPLACE FUNCTION private.persona_card(p_persona_id UUID)
RETURNS TABLE (pseudonym TEXT, avatar_seed VARCHAR, profile_photo_url TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pr.pseudonym::TEXT, pr.avatar_seed, pr.profile_photo_url
    FROM public.personas AS pr
   WHERE pr.persona_id = p_persona_id AND pr.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION private.persona_card(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.persona_card(UUID) TO authenticated, service_role;

-- The new-account gate in personal_feed asks whether an author's account is
-- older than an hour. For a persona post the account is exactly what the
-- caller may not see, so the question gets asked on its behalf.
CREATE OR REPLACE FUNCTION private.persona_owner_established(
  p_persona_id UUID,
  p_before     TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.personas AS pr
      JOIN public.users AS u ON u.user_id = pr.user_id
     WHERE pr.persona_id = p_persona_id
       AND pr.deleted_at IS NULL
       AND u.created_at < p_before
  )
$$;

REVOKE ALL ON FUNCTION private.persona_owner_established(UUID, TIMESTAMPTZ)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.persona_owner_established(UUID, TIMESTAMPTZ)
  TO authenticated, service_role;

-- ── the view every reader goes through ────────────────────────────────────
--
-- WITH (security_invoker = true), and said out loud every time this view is
-- reissued: CREATE OR REPLACE VIEW silently resets reloptions, and the last
-- time that was forgotten row level security came off for the eight things
-- that read it.
CREATE OR REPLACE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
  p.post_id,
  -- The voice, not the account.
  p.feed_author_key AS author_id,
  COALESCE(
    '@' || pc.pseudonym,
    '@' || u.anonymous_pseudonym::TEXT,
    '@anonymous'
  ) AS author_pseudonym,
  COALESCE(pc.avatar_seed, u.avatar_seed, 'default-orb'::VARCHAR)
    AS author_avatar_seed,
  CASE WHEN p.persona_id IS NULL THEN u.profile_photo_url
       ELSE pc.profile_photo_url END AS author_profile_photo_url,
  -- A tick or a karma score on a persona post narrows its author to a small
  -- set, so a persona carries neither.
  CASE WHEN p.persona_id IS NULL THEN COALESCE(u.is_verified, FALSE)
       ELSE FALSE END AS author_is_verified,
  CASE WHEN p.persona_id IS NULL THEN COALESCE(u.karma_points, 0)
       ELSE 0 END AS author_karma,
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
  p.media_status,
  p.card_background_color,
  p.card_text_color,
  p.is_story,
  p.story_audience,
  p.music_track_id,
  p.music_start_ms,
  p.music_duration_ms,
  p.music_volume,
  p.goal_reached_at,
  -- The one reader who is allowed to know. Appended rather than slotted beside
  -- persona_id where it reads better: CREATE OR REPLACE VIEW can only add
  -- columns at the end, and dropping this view to reorder it would take the
  -- eight things that read it with it.
  --
  -- Answered through personas rather than through author_id, which is no
  -- longer readable: the owner-only RLS policy on personas is what makes this
  -- true for exactly one person.
  -- COALESCE, because display_author_id is NULL on a persona post and
  -- `NULL OR false` is NULL, not false — which a client reads as "unknown"
  -- and, in Dart, as a null where a bool was promised.
  COALESCE(
    p.display_author_id = (SELECT auth.uid())
    OR (p.persona_id IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.personas AS mine
           WHERE mine.persona_id = p.persona_id
             AND mine.user_id = (SELECT auth.uid()))),
    FALSE
  ) AS is_mine
FROM public.posts AS p
-- display_author_id, not author_id: for a persona post this is NULL, so the
-- join finds no account and there is nothing to fall through to.
LEFT JOIN public.users AS u ON u.user_id = p.display_author_id
LEFT JOIN LATERAL private.persona_card(p.persona_id) AS pc ON p.persona_id IS NOT NULL
LEFT JOIN public.tribes AS t ON t.tribe_id = p.tribe_id;
-- The can_view_post_author() filter that used to sit here is gone, not
-- dropped: it is the first clause of the "posts readable" RLS policy, which
-- applies to this view because it is security_invoker. Keeping a copy here
-- would mean referencing author_id, which is exactly what must stop.

-- ── close the raw table ───────────────────────────────────────────────────
--
-- Masking the view alone would be theatre: PostgREST exposes the table too, so
-- GET /posts?select=author_id,persona_id would hand over the correlation the
-- view just stopped printing. A column-level REVOKE does nothing while a
-- table-wide grant stands, so the grant is replaced by a column list.
DO $grants$
DECLARE v_cols TEXT;
BEGIN
  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
    INTO v_cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name = 'posts'
     AND column_name <> 'author_id';

  REVOKE SELECT ON public.posts FROM authenticated, anon;
  EXECUTE format('GRANT SELECT (%s) ON public.posts TO authenticated', v_cols);
END $grants$;

-- RLS predicates still read author_id — a policy is evaluated by the system,
-- not by the caller's column privileges — so every rule about who may see,
-- edit and delete a post is untouched by the revoke above.

-- ── "show me less of this" still knows your own post ──────────────────────
--
-- It refuses to mute a post of yours by comparing the author to auth.uid().
-- The author it reads is now the voice, so on a post behind your own persona
-- that comparison is persona vs account and says "not yours" — you could mute
-- yourself. is_mine is the question it was always asking.
--
-- The author it stores is the voice too, which is the point: post_not_interested
-- is a row the muter owns and can read back, so writing the account there was
-- another way to unmask a persona.
CREATE OR REPLACE FUNCTION public.mark_not_interested(
  p_post_id UUID,
  p_reason  TEXT DEFAULT 'post'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_author   UUID;
  v_mine     BOOLEAN;
  v_category VARCHAR(64);
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_reason NOT IN ('post', 'author', 'topic') THEN
    RAISE EXCEPTION 'invalid_reason';
  END IF;

  -- Read through the view as the caller: you can only say this about a post
  -- you were allowed to see in the first place.
  SELECT f.author_id, f.is_mine, f.category_name
    INTO v_author, v_mine, v_category
    FROM public.feed_posts AS f
   WHERE f.post_id = p_post_id;

  IF v_author IS NULL THEN RAISE EXCEPTION 'post_not_found'; END IF;
  IF v_mine THEN RAISE EXCEPTION 'that_is_your_own_post'; END IF;

  INSERT INTO public.post_not_interested
    (user_id, post_id, author_id, category_name, reason)
  VALUES (v_me, p_post_id, v_author, v_category, p_reason)
  ON CONFLICT (user_id, post_id) DO UPDATE
    SET reason = EXCLUDED.reason, created_at = now();

  -- The point of saying it is that the post goes away now, not at the next
  -- refresh, so the cached ranking for this reader is dropped.
  DELETE FROM public.feed_sessions WHERE user_id = v_me;

  RETURN TRUE;
END $$;

SELECT public.record_migration('20261077090000', 'a_persona_is_a_different_person');

NOTIFY pgrst, 'reload schema';
