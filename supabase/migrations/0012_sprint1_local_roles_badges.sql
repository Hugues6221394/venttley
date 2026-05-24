-- ============================================================================
-- Venttly | Migration 0012 — Sprint 1
--   (a) Local feed: home_city / home_country / home_campus on users,
--                   location_bucket on posts (auto-stamped from author)
--   (b) Co-mod hierarchy: tribe_members.role + tribe_bans + audit log + RPCs
--   (c) Badges + streaks: schema + 8 starter badges + trigger engine
-- ============================================================================

-- =========================================================================
-- (A) LOCAL FEED
-- =========================================================================

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS home_city    TEXT,
    ADD COLUMN IF NOT EXISTS home_country TEXT,
    ADD COLUMN IF NOT EXISTS home_campus  TEXT;

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS location_bucket TEXT;

-- Partial index — only the live, located posts matter for the local feed.
CREATE INDEX IF NOT EXISTS idx_posts_local
    ON public.posts(location_bucket, created_at DESC)
    WHERE deleted_at IS NULL AND location_bucket IS NOT NULL;

-- Auto-stamp location_bucket from the author's home_city at insert time.
-- The post stays anchored to where the author wrote it even if they
-- later move cities.
CREATE OR REPLACE FUNCTION public.trg_stamp_location_bucket()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.location_bucket IS NULL THEN
        SELECT lower(home_city) INTO NEW.location_bucket
          FROM public.users WHERE user_id = NEW.author_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS posts_stamp_location_bucket ON public.posts;
CREATE TRIGGER posts_stamp_location_bucket
    BEFORE INSERT ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.trg_stamp_location_bucket();

-- Refresh feed_posts so the bucket flows to clients in one fetch.
DROP VIEW IF EXISTS public.feed_posts;
CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(u.avatar_seed, 'default-orb')               AS author_avatar_seed,
    COALESCE(u.is_verified, false)                       AS author_is_verified,
    COALESCE(u.karma_points, 0)                          AS author_karma,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_whisper,
    p.location_bucket,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users  u ON u.user_id  = p.author_id
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

-- =========================================================================
-- (B) CO-MOD HIERARCHY
-- =========================================================================

ALTER TABLE public.tribe_members
    ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member';
ALTER TABLE public.tribe_members
    DROP CONSTRAINT IF EXISTS tribe_members_role_check;
ALTER TABLE public.tribe_members
    ADD CONSTRAINT tribe_members_role_check
    CHECK (role IN ('member', 'mod', 'keeper'));

-- Backfill: any tribe_members row that matches its tribe's keeper_id is the keeper.
UPDATE public.tribe_members tm
   SET role = 'keeper'
  FROM public.tribes t
 WHERE t.tribe_id = tm.tribe_id
   AND t.keeper_id = tm.user_id
   AND tm.role <> 'keeper';

CREATE INDEX IF NOT EXISTS idx_tribe_members_role
    ON public.tribe_members(tribe_id, role);

-- Soft bans — kick removes a tribe_members row + drops one here so the
-- user can't rejoin a public tribe.
CREATE TABLE IF NOT EXISTS public.tribe_bans (
    tribe_id    UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES public.users(user_id)  ON DELETE CASCADE,
    banned_by   UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    reason      TEXT,
    banned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tribe_id, user_id)
);

ALTER TABLE public.tribe_bans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "bans read by mods" ON public.tribe_bans;
CREATE POLICY "bans read by mods"
    ON public.tribe_bans FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.tribe_members tm
             WHERE tm.tribe_id = tribe_bans.tribe_id
               AND tm.user_id  = auth.uid()
               AND tm.role IN ('mod', 'keeper')
        )
    );
-- No INSERT / UPDATE policy — all writes go through SECURITY DEFINER RPCs.

-- Audit log
CREATE TABLE IF NOT EXISTS public.tribe_moderation_actions (
    action_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tribe_id         UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    actor_id         UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    action           TEXT NOT NULL
        CHECK (action IN (
            'promote_mod','demote_mod','kick_member','transfer_keeper',
            'resolve_report','delete_post'
        )),
    target_user_id   UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    target_post_id   UUID REFERENCES public.posts(post_id) ON DELETE SET NULL,
    reason           TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mod_actions_tribe
    ON public.tribe_moderation_actions(tribe_id, created_at DESC);

ALTER TABLE public.tribe_moderation_actions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "audit read by mods" ON public.tribe_moderation_actions;
CREATE POLICY "audit read by mods"
    ON public.tribe_moderation_actions FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.tribe_members tm
             WHERE tm.tribe_id = tribe_moderation_actions.tribe_id
               AND tm.user_id  = auth.uid()
               AND tm.role IN ('mod', 'keeper')
        )
    );

-- ===== Mod RPCs ==========================================================
-- All four are SECURITY DEFINER + run with search_path locked. They check
-- the caller's role internally because Postgres can't do column-level RLS
-- on tribe_members.role.

CREATE OR REPLACE FUNCTION public.promote_to_mod(
    p_tribe_id UUID, p_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = p_tribe_id AND t.keeper_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'Only the Keeper can promote members';
    END IF;
    UPDATE tribe_members
       SET role = 'mod'
     WHERE tribe_id = p_tribe_id
       AND user_id  = p_user_id
       AND role     = 'member';
    INSERT INTO tribe_moderation_actions(tribe_id, actor_id, action, target_user_id)
    VALUES (p_tribe_id, auth.uid(), 'promote_mod', p_user_id);
END $$;

CREATE OR REPLACE FUNCTION public.demote_to_member(
    p_tribe_id UUID, p_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = p_tribe_id AND t.keeper_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'Only the Keeper can demote mods';
    END IF;
    UPDATE tribe_members
       SET role = 'member'
     WHERE tribe_id = p_tribe_id
       AND user_id  = p_user_id
       AND role     = 'mod';
    INSERT INTO tribe_moderation_actions(tribe_id, actor_id, action, target_user_id)
    VALUES (p_tribe_id, auth.uid(), 'demote_mod', p_user_id);
END $$;

CREATE OR REPLACE FUNCTION public.kick_member(
    p_tribe_id UUID, p_user_id UUID, p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    actor_role TEXT;
    target_role TEXT;
BEGIN
    SELECT role INTO actor_role FROM tribe_members
     WHERE tribe_id = p_tribe_id AND user_id = auth.uid();
    IF actor_role NOT IN ('mod', 'keeper') THEN
        RAISE EXCEPTION 'Only mods and the Keeper can kick members';
    END IF;

    SELECT role INTO target_role FROM tribe_members
     WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    IF target_role = 'keeper' THEN
        RAISE EXCEPTION 'Cannot kick the Keeper';
    END IF;
    IF target_role = 'mod' AND actor_role <> 'keeper' THEN
        RAISE EXCEPTION 'Only the Keeper can kick another mod';
    END IF;

    DELETE FROM tribe_members
     WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
    INSERT INTO tribe_bans(tribe_id, user_id, banned_by, reason)
    VALUES (p_tribe_id, p_user_id, auth.uid(), p_reason)
    ON CONFLICT (tribe_id, user_id) DO NOTHING;
    INSERT INTO tribe_moderation_actions(tribe_id, actor_id, action, target_user_id, reason)
    VALUES (p_tribe_id, auth.uid(), 'kick_member', p_user_id, p_reason);
END $$;

CREATE OR REPLACE FUNCTION public.transfer_keeper(
    p_tribe_id UUID, p_to_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = p_tribe_id AND t.keeper_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'Only the current Keeper can transfer';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe_id AND user_id = p_to_user_id AND role = 'mod'
    ) THEN
        RAISE EXCEPTION 'Recipient must currently be a mod';
    END IF;
    UPDATE tribes SET keeper_id = p_to_user_id WHERE tribe_id = p_tribe_id;
    UPDATE tribe_members SET role = 'member'
     WHERE tribe_id = p_tribe_id AND user_id = auth.uid();
    UPDATE tribe_members SET role = 'keeper'
     WHERE tribe_id = p_tribe_id AND user_id = p_to_user_id;
    INSERT INTO tribe_moderation_actions(tribe_id, actor_id, action, target_user_id)
    VALUES (p_tribe_id, auth.uid(), 'transfer_keeper', p_to_user_id);
END $$;

GRANT EXECUTE ON FUNCTION public.promote_to_mod  TO authenticated;
GRANT EXECUTE ON FUNCTION public.demote_to_member TO authenticated;
GRANT EXECUTE ON FUNCTION public.kick_member     TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_keeper TO authenticated;

-- Broaden "posts delete" RLS to mods + keepers.
DROP POLICY IF EXISTS "posts delete keeper" ON public.posts;
DROP POLICY IF EXISTS "posts delete mod or keeper" ON public.posts;
CREATE POLICY "posts delete mod or keeper"
    ON public.posts FOR DELETE
    USING (
        author_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.tribe_members tm
             WHERE tm.tribe_id = posts.tribe_id
               AND tm.user_id  = auth.uid()
               AND tm.role IN ('mod','keeper')
        )
    );

-- Broaden the "reports update" RLS (added in 0008) to mods + keepers.
DROP POLICY IF EXISTS "reports keeper update" ON public.reports;
DROP POLICY IF EXISTS "reports mod update"    ON public.reports;
CREATE POLICY "reports mod update"
    ON public.reports FOR UPDATE
    USING (
        post_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.posts p
             JOIN public.tribe_members tm
               ON tm.tribe_id = p.tribe_id AND tm.user_id = auth.uid()
             WHERE p.post_id = reports.post_id
               AND tm.role IN ('mod','keeper')
        )
    )
    WITH CHECK (true);

-- Re-issue the read policy so mods see the queue too.
DROP POLICY IF EXISTS "reports keeper read" ON public.reports;
DROP POLICY IF EXISTS "reports mod read"    ON public.reports;
CREATE POLICY "reports mod read"
    ON public.reports FOR SELECT
    USING (
        post_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.posts p
             JOIN public.tribe_members tm
               ON tm.tribe_id = p.tribe_id AND tm.user_id = auth.uid()
             WHERE p.post_id = reports.post_id
               AND tm.role IN ('mod','keeper')
        )
    );

-- Bans gate the tribe_members insert path.
CREATE OR REPLACE FUNCTION public.trg_block_banned_joins()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM tribe_bans
         WHERE tribe_id = NEW.tribe_id AND user_id = NEW.user_id
    ) THEN
        RAISE EXCEPTION 'You have been removed from this Tribe.';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tribe_members_no_banned ON public.tribe_members;
CREATE TRIGGER tribe_members_no_banned
    BEFORE INSERT ON public.tribe_members
    FOR EACH ROW EXECUTE FUNCTION public.trg_block_banned_joins();

-- =========================================================================
-- (C) BADGES + STREAKS
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.badge_definitions (
    badge_key   TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT NOT NULL,
    icon        TEXT NOT NULL,
    tier        TEXT NOT NULL CHECK (tier IN ('bronze','silver','gold'))
);

CREATE TABLE IF NOT EXISTS public.user_badges (
    user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    badge_key   TEXT NOT NULL REFERENCES public.badge_definitions(badge_key) ON DELETE CASCADE,
    awarded_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, badge_key)
);

CREATE INDEX IF NOT EXISTS idx_user_badges_user
    ON public.user_badges(user_id, awarded_at DESC);

CREATE TABLE IF NOT EXISTS public.user_streaks (
    user_id        UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    streak_kind    TEXT NOT NULL CHECK (streak_kind IN ('posting','commenting','reactions')),
    current_count  INT NOT NULL DEFAULT 0,
    longest_count  INT NOT NULL DEFAULT 0,
    last_event_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, streak_kind)
);

ALTER TABLE public.badge_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_badges       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_streaks      ENABLE ROW LEVEL SECURITY;

-- Catalogue + badges are public-read; streaks are owner-read.
DROP POLICY IF EXISTS "defs readable"   ON public.badge_definitions;
CREATE POLICY "defs readable"   ON public.badge_definitions FOR SELECT USING (true);
DROP POLICY IF EXISTS "badges readable" ON public.user_badges;
CREATE POLICY "badges readable" ON public.user_badges FOR SELECT USING (true);
DROP POLICY IF EXISTS "streak owner" ON public.user_streaks;
CREATE POLICY "streak owner"
    ON public.user_streaks FOR SELECT USING (user_id = auth.uid());
-- All writes happen via triggers, no INSERT/UPDATE policies needed.

-- Seed catalogue
INSERT INTO public.badge_definitions(badge_key, label, description, icon, tier) VALUES
    ('first_vent',       'First Vent',        'You shared your first confession.',           '⭐', 'bronze'),
    ('seven_day_venter', '7-Day Venter',      'Seven consecutive days of posting.',          '🌙', 'silver'),
    ('night_owl',        'Night Owl',         'Five posts between 11pm and 4am.',            '🦉', 'bronze'),
    ('hundred_hearts',   'Hundred Hearts',    'Received 100 likes across your posts.',       '💗', 'silver'),
    ('supportive_voice', 'Supportive Voice',  'Authored 100 comments on others’ posts.',     '🤲', 'silver'),
    ('trusted_voice',    'Trusted Voice',     'Earned 1,000 karma.',                         '⚜',  'gold'),
    ('keeper',           'Keeper',            'Started your own Tribe.',                     '🌿', 'silver'),
    ('whisper_keeper',   'Whisper Keeper',    'Posted ten Whispers.',                        '🌒', 'bronze')
ON CONFLICT (badge_key) DO NOTHING;

-- Streak engine — increments when consecutive day, resets otherwise.
CREATE OR REPLACE FUNCTION public.bump_streak(p_user UUID, p_kind TEXT, p_now TIMESTAMPTZ)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    prev TIMESTAMPTZ;
    cur  INT;
    longest INT;
    new_count INT;
BEGIN
    SELECT last_event_at, current_count, longest_count
      INTO prev, cur, longest
      FROM user_streaks
     WHERE user_id = p_user AND streak_kind = p_kind;

    IF NOT FOUND THEN
        INSERT INTO user_streaks(user_id, streak_kind, current_count, longest_count, last_event_at)
        VALUES (p_user, p_kind, 1, 1, p_now);
        RETURN 1;
    END IF;

    IF DATE(prev) = DATE(p_now) THEN
        new_count := cur; -- already counted today
    ELSIF DATE(prev) = DATE(p_now) - INTERVAL '1 day' THEN
        new_count := cur + 1;
    ELSE
        new_count := 1;
    END IF;

    UPDATE user_streaks
       SET current_count = new_count,
           longest_count = GREATEST(longest, new_count),
           last_event_at = p_now
     WHERE user_id = p_user AND streak_kind = p_kind;
    RETURN new_count;
END $$;

CREATE OR REPLACE FUNCTION public.award(p_user UUID, p_badge TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO user_badges(user_id, badge_key)
    VALUES (p_user, p_badge)
    ON CONFLICT (user_id, badge_key) DO NOTHING;
END $$;

-- Trigger: on new post
CREATE OR REPLACE FUNCTION public.trg_post_events()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    streak_now INT;
    night_count INT;
    karma INT;
    whisper_count INT;
BEGIN
    PERFORM award(NEW.author_id, 'first_vent');

    streak_now := bump_streak(NEW.author_id, 'posting', NEW.created_at);
    IF streak_now >= 7 THEN
        PERFORM award(NEW.author_id, 'seven_day_venter');
    END IF;

    -- Night owl
    IF EXTRACT(HOUR FROM NEW.created_at AT TIME ZONE 'UTC') IN (23, 0, 1, 2, 3) THEN
        SELECT COUNT(*) INTO night_count
          FROM posts
         WHERE author_id = NEW.author_id
           AND EXTRACT(HOUR FROM created_at AT TIME ZONE 'UTC') IN (23, 0, 1, 2, 3);
        IF night_count >= 5 THEN PERFORM award(NEW.author_id, 'night_owl'); END IF;
    END IF;

    -- Whisper Keeper
    IF NEW.is_whisper THEN
        SELECT COUNT(*) INTO whisper_count
          FROM posts WHERE author_id = NEW.author_id AND is_whisper = true;
        IF whisper_count >= 10 THEN
            PERFORM award(NEW.author_id, 'whisper_keeper');
        END IF;
    END IF;

    -- Trusted Voice (recheck karma on every post too — cheap)
    SELECT karma_points INTO karma FROM users WHERE user_id = NEW.author_id;
    IF karma >= 1000 THEN PERFORM award(NEW.author_id, 'trusted_voice'); END IF;

    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS posts_badge_events ON public.posts;
CREATE TRIGGER posts_badge_events
    AFTER INSERT ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.trg_post_events();

-- Trigger: on new like — recipient's karma already bumped by the existing
-- karma trigger; here we just check the "100 hearts" badge.
CREATE OR REPLACE FUNCTION public.trg_like_events()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    author UUID;
    hearts INT;
BEGIN
    SELECT author_id INTO author FROM posts WHERE post_id = NEW.post_id;
    IF author IS NULL OR author = NEW.user_id THEN RETURN NEW; END IF;
    SELECT SUM(likes_count) INTO hearts
      FROM posts WHERE author_id = author;
    IF hearts >= 100 THEN PERFORM award(author, 'hundred_hearts'); END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS post_likes_badge_events ON public.post_likes;
CREATE TRIGGER post_likes_badge_events
    AFTER INSERT ON public.post_likes
    FOR EACH ROW EXECUTE FUNCTION public.trg_like_events();

-- Trigger: on new comment
CREATE OR REPLACE FUNCTION public.trg_comment_events()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    total INT;
BEGIN
    PERFORM bump_streak(NEW.author_id, 'commenting', NEW.created_at);
    SELECT COUNT(*) INTO total
      FROM posts_comments WHERE author_id = NEW.author_id;
    IF total >= 100 THEN PERFORM award(NEW.author_id, 'supportive_voice'); END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS comments_badge_events ON public.posts_comments;
CREATE TRIGGER comments_badge_events
    AFTER INSERT ON public.posts_comments
    FOR EACH ROW EXECUTE FUNCTION public.trg_comment_events();

-- Trigger: on tribe creation, give the creator the Keeper badge.
CREATE OR REPLACE FUNCTION public.trg_tribe_keeper_badge()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.keeper_id IS NOT NULL THEN
        PERFORM award(NEW.keeper_id, 'keeper');
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tribes_keeper_badge ON public.tribes;
CREATE TRIGGER tribes_keeper_badge
    AFTER INSERT ON public.tribes
    FOR EACH ROW EXECUTE FUNCTION public.trg_tribe_keeper_badge();

NOTIFY pgrst, 'reload schema';
