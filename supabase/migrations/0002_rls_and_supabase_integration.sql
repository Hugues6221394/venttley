-- ============================================================================
-- Vently | Supabase integration + Row Level Security
--
-- This migration is layered on top of 0001_init_schema.sql. It enables RLS on
-- every table in the public schema and wires policies to `auth.uid()` so the
-- app can talk to PostgREST directly from the Flutter client using the
-- anonymous Supabase auth flow.
--
-- Threat model summary:
--   * Anyone (anon role) can SELECT public surfaces: posts, comments,
--     plug profiles, spaces, prompts.
--   * Only authenticated devices can INSERT content.
--   * Authors can mutate / soft-delete their own rows.
--   * Chat is strictly between the two participants.
--   * Notifications are strictly visible to their owner.
-- ============================================================================

-- ------------------------------------------------------------------
-- Helper: get the calling user's Vently user_id from Supabase Auth.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT auth.uid();
$$;

REVOKE ALL ON FUNCTION public.current_user_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_id() TO anon, authenticated;

-- ------------------------------------------------------------------
-- Enable RLS on every public table
-- ------------------------------------------------------------------
ALTER TABLE public.users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plug_profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tribes_follows      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.spaces              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.space_memberships   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_polls          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.poll_options        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.poll_votes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_likes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_saves          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts_comments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comment_likes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_rooms          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_reports  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plug_prompts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_answers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications       ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------
-- USERS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "users readable by everyone" ON public.users;
CREATE POLICY "users readable by everyone"
    ON public.users FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "users insert self" ON public.users;
CREATE POLICY "users insert self"
    ON public.users FOR INSERT
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "users update self" ON public.users;
CREATE POLICY "users update self"
    ON public.users FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "users delete self" ON public.users;
CREATE POLICY "users delete self"
    ON public.users FOR DELETE
    USING (user_id = auth.uid());

-- ------------------------------------------------------------------
-- PLUG PROFILES
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "plug_profiles readable" ON public.plug_profiles;
CREATE POLICY "plug_profiles readable"
    ON public.plug_profiles FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "plug_profiles owner write" ON public.plug_profiles;
CREATE POLICY "plug_profiles owner write"
    ON public.plug_profiles FOR ALL
    USING (plug_id = auth.uid())
    WITH CHECK (plug_id = auth.uid());

-- ------------------------------------------------------------------
-- TRIBES FOLLOWS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "tribes_follows readable" ON public.tribes_follows;
CREATE POLICY "tribes_follows readable"
    ON public.tribes_follows FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "tribes_follows follower write" ON public.tribes_follows;
CREATE POLICY "tribes_follows follower write"
    ON public.tribes_follows FOR ALL
    USING (follower_id = auth.uid())
    WITH CHECK (follower_id = auth.uid());

-- ------------------------------------------------------------------
-- SPACES + memberships
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "spaces readable" ON public.spaces;
CREATE POLICY "spaces readable"
    ON public.spaces FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "spaces insert auth" ON public.spaces;
CREATE POLICY "spaces insert auth"
    ON public.spaces FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "space_memberships self" ON public.space_memberships;
CREATE POLICY "space_memberships self"
    ON public.space_memberships FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "space_memberships readable" ON public.space_memberships;
CREATE POLICY "space_memberships readable"
    ON public.space_memberships FOR SELECT
    USING (true);

-- ------------------------------------------------------------------
-- POSTS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "posts readable" ON public.posts;
CREATE POLICY "posts readable"
    ON public.posts FOR SELECT
    USING (deleted_at IS NULL);

DROP POLICY IF EXISTS "posts insert auth" ON public.posts;
CREATE POLICY "posts insert auth"
    ON public.posts FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL AND author_id = auth.uid());

DROP POLICY IF EXISTS "posts update author" ON public.posts;
CREATE POLICY "posts update author"
    ON public.posts FOR UPDATE
    USING (author_id = auth.uid())
    WITH CHECK (author_id = auth.uid());

DROP POLICY IF EXISTS "posts delete author" ON public.posts;
CREATE POLICY "posts delete author"
    ON public.posts FOR DELETE
    USING (author_id = auth.uid());

-- ------------------------------------------------------------------
-- POLLS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "polls readable" ON public.post_polls;
CREATE POLICY "polls readable"
    ON public.post_polls FOR SELECT USING (true);

DROP POLICY IF EXISTS "polls insert by post author" ON public.post_polls;
CREATE POLICY "polls insert by post author"
    ON public.post_polls FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM public.posts p
        WHERE p.post_id = post_polls.post_id AND p.author_id = auth.uid()
    ));

DROP POLICY IF EXISTS "poll_options readable" ON public.poll_options;
CREATE POLICY "poll_options readable" ON public.poll_options FOR SELECT USING (true);
DROP POLICY IF EXISTS "poll_options insert by post author" ON public.poll_options;
CREATE POLICY "poll_options insert by post author"
    ON public.poll_options FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM public.post_polls pp
        JOIN public.posts p ON p.post_id = pp.post_id
        WHERE pp.poll_id = poll_options.poll_id AND p.author_id = auth.uid()
    ));

DROP POLICY IF EXISTS "poll_votes readable" ON public.poll_votes;
CREATE POLICY "poll_votes readable"
    ON public.poll_votes FOR SELECT USING (true);
DROP POLICY IF EXISTS "poll_votes self" ON public.poll_votes;
CREATE POLICY "poll_votes self"
    ON public.poll_votes FOR INSERT
    WITH CHECK (user_id = auth.uid());

-- ------------------------------------------------------------------
-- LIKES + SAVES
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "post_likes readable" ON public.post_likes;
CREATE POLICY "post_likes readable"
    ON public.post_likes FOR SELECT USING (true);
DROP POLICY IF EXISTS "post_likes self" ON public.post_likes;
CREATE POLICY "post_likes self"
    ON public.post_likes FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "post_saves self" ON public.post_saves;
CREATE POLICY "post_saves self"
    ON public.post_saves FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "comment_likes readable" ON public.comment_likes;
CREATE POLICY "comment_likes readable" ON public.comment_likes FOR SELECT USING (true);
DROP POLICY IF EXISTS "comment_likes self" ON public.comment_likes;
CREATE POLICY "comment_likes self"
    ON public.comment_likes FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- ------------------------------------------------------------------
-- COMMENTS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "comments readable" ON public.posts_comments;
CREATE POLICY "comments readable"
    ON public.posts_comments FOR SELECT
    USING (deleted_at IS NULL);

DROP POLICY IF EXISTS "comments insert auth" ON public.posts_comments;
CREATE POLICY "comments insert auth"
    ON public.posts_comments FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL AND author_id = auth.uid());

DROP POLICY IF EXISTS "comments update author" ON public.posts_comments;
CREATE POLICY "comments update author"
    ON public.posts_comments FOR UPDATE
    USING (author_id = auth.uid())
    WITH CHECK (author_id = auth.uid());

DROP POLICY IF EXISTS "comments delete author" ON public.posts_comments;
CREATE POLICY "comments delete author"
    ON public.posts_comments FOR DELETE
    USING (author_id = auth.uid());

-- ------------------------------------------------------------------
-- CHAT — strictly the two participants
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "chat_rooms participants read" ON public.chat_rooms;
CREATE POLICY "chat_rooms participants read"
    ON public.chat_rooms FOR SELECT
    USING (auth.uid() IN (initiated_by, received_by));

DROP POLICY IF EXISTS "chat_rooms initiator insert" ON public.chat_rooms;
CREATE POLICY "chat_rooms initiator insert"
    ON public.chat_rooms FOR INSERT
    WITH CHECK (initiated_by = auth.uid());

DROP POLICY IF EXISTS "chat_rooms participants update" ON public.chat_rooms;
CREATE POLICY "chat_rooms participants update"
    ON public.chat_rooms FOR UPDATE
    USING (auth.uid() IN (initiated_by, received_by))
    WITH CHECK (auth.uid() IN (initiated_by, received_by));

DROP POLICY IF EXISTS "chat_messages participants read" ON public.chat_messages;
CREATE POLICY "chat_messages participants read"
    ON public.chat_messages FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM public.chat_rooms r
        WHERE r.room_id = chat_messages.room_id
          AND auth.uid() IN (r.initiated_by, r.received_by)
    ));

DROP POLICY IF EXISTS "chat_messages sender insert" ON public.chat_messages;
CREATE POLICY "chat_messages sender insert"
    ON public.chat_messages FOR INSERT
    WITH CHECK (
        sender_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.chat_rooms r
            WHERE r.room_id = chat_messages.room_id
              AND r.room_status = 'active'
              AND auth.uid() IN (r.initiated_by, r.received_by)
        )
    );

-- ------------------------------------------------------------------
-- BLOCKS, REPORTS, NOTIFICATIONS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "blocks self" ON public.user_blocks;
CREATE POLICY "blocks self"
    ON public.user_blocks FOR ALL
    USING (blocker_id = auth.uid())
    WITH CHECK (blocker_id = auth.uid());

DROP POLICY IF EXISTS "reports insert auth" ON public.moderation_reports;
CREATE POLICY "reports insert auth"
    ON public.moderation_reports FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL AND reporter_id = auth.uid());

DROP POLICY IF EXISTS "reports reporter read" ON public.moderation_reports;
CREATE POLICY "reports reporter read"
    ON public.moderation_reports FOR SELECT
    USING (reporter_id = auth.uid());

DROP POLICY IF EXISTS "notifications owner" ON public.notifications;
CREATE POLICY "notifications owner"
    ON public.notifications FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- ------------------------------------------------------------------
-- PLUG PROMPTS + ANSWERS
-- ------------------------------------------------------------------
DROP POLICY IF EXISTS "prompts readable" ON public.plug_prompts;
CREATE POLICY "prompts readable" ON public.plug_prompts FOR SELECT USING (true);
DROP POLICY IF EXISTS "prompts plug write" ON public.plug_prompts;
CREATE POLICY "prompts plug write"
    ON public.plug_prompts FOR ALL
    USING (plug_id = auth.uid())
    WITH CHECK (plug_id = auth.uid());

DROP POLICY IF EXISTS "answers readable" ON public.prompt_answers;
CREATE POLICY "answers readable" ON public.prompt_answers FOR SELECT USING (true);
DROP POLICY IF EXISTS "answers author insert" ON public.prompt_answers;
CREATE POLICY "answers author insert"
    ON public.prompt_answers FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL AND author_id = auth.uid());

-- ------------------------------------------------------------------
-- API view: feed_posts (denormalised author info so the client never
-- has to do a second round trip to render a post card).
-- security_invoker = true so the underlying RLS still applies.
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS public.feed_posts;
CREATE VIEW public.feed_posts
WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(u.avatar_seed, 'default-orb')               AS author_avatar_seed,
    COALESCE(u.is_verified, false)                       AS author_is_verified,
    s.space_name,
    p.space_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_audio,
    p.audio_url,
    COALESCE(p.audio_duration_ms, 0) AS audio_duration_ms,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users  u ON u.user_id  = p.author_id
LEFT JOIN public.spaces s ON s.space_id = p.space_id;

GRANT SELECT ON public.feed_posts TO anon, authenticated;

-- ------------------------------------------------------------------
-- API view: inbox_rooms (denormalised peer info per viewer)
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS public.inbox_rooms;
CREATE VIEW public.inbox_rooms
WITH (security_invoker = true) AS
SELECT
    r.room_id,
    r.initiated_by,
    r.received_by,
    r.request_preview,
    r.room_status,
    r.created_at,
    r.updated_at,
    CASE WHEN r.initiated_by = auth.uid() THEN r.received_by  ELSE r.initiated_by END AS peer_id,
    CASE WHEN r.initiated_by = auth.uid() THEN peer_recv.anonymous_pseudonym
                                          ELSE peer_init.anonymous_pseudonym END AS peer_pseudonym,
    CASE WHEN r.initiated_by = auth.uid() THEN peer_recv.avatar_seed
                                          ELSE peer_init.avatar_seed END         AS peer_avatar_seed,
    CASE WHEN r.initiated_by = auth.uid() THEN true ELSE false END               AS initiated_by_me
FROM public.chat_rooms r
LEFT JOIN public.users peer_init ON peer_init.user_id = r.initiated_by
LEFT JOIN public.users peer_recv ON peer_recv.user_id = r.received_by;

GRANT SELECT ON public.inbox_rooms TO anon, authenticated;

-- ------------------------------------------------------------------
-- Auto-create a `users` row when a Supabase Auth user appears.
-- Uses metadata the client sets at sign-in time (pseudonym, avatar_seed).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    meta JSONB := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
    pseudonym TEXT := COALESCE(meta->>'pseudonym',     'SilentSoul');
    avatar    TEXT := COALESCE(meta->>'avatar_seed',   'rose-orb-0001');
    safety    TEXT := COALESCE(meta->>'safety_tier',   'standard');
    byear     INT  := NULLIF(meta->>'birth_year', '')::INT;
BEGIN
    INSERT INTO public.users(
        user_id, anonymous_pseudonym, avatar_seed, current_mood,
        user_role, is_verified, account_status, safety_tier, birth_year,
        recovery_key_hash
    )
    VALUES (
        NEW.id, pseudonym, avatar, 'healing',
        'normal', false, 'active', safety::safety_tier_type, byear,
        'auth-managed'
    )
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();
