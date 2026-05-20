-- ============================================================================
-- Venttly | Migration 0005 — Hybrid Tribes schema
--
-- Tribes are the unified primitive for v1: every Tribe is BOTH a community
-- (anyone can create, members can join, posts belong to it) AND a creator
-- ecosystem (the keeper — optionally a verified Plug — moderates it). This
-- migration converts the older `spaces` + `tribes_follows` split into a
-- single `tribes` + `tribe_members` model.
--
-- Production is empty of community data after migration 0003's seed wipe,
-- so renames are safe and no row-level data migration is required.
-- ============================================================================

-- 1) Rename spaces → tribes, and its columns.
ALTER TABLE public.spaces           RENAME TO tribes;
ALTER TABLE public.tribes           RENAME COLUMN space_id   TO tribe_id;
ALTER TABLE public.tribes           RENAME COLUMN space_name TO name;
ALTER TABLE public.tribes           RENAME COLUMN space_type TO category;

-- 2) Extend tribes with the hybrid-model columns.
ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS keeper_id  UUID
        REFERENCES public.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS is_private BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS rules      JSONB   NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS slug       TEXT;

-- The new category set covers the founder's directions plus the legacy ones.
ALTER TABLE public.tribes DROP CONSTRAINT IF EXISTS spaces_space_type_check;
ALTER TABLE public.tribes
    ADD CONSTRAINT tribes_category_check
    CHECK (category IN
        ('campus', 'city', 'interest_group', 'hobby', 'support', 'venting'));

-- Backfill slug from name, enforce non-null + unique.
UPDATE public.tribes
   SET slug = lower(regexp_replace(name, '[^a-zA-Z0-9]+', '-', 'g'))
 WHERE slug IS NULL;
ALTER TABLE public.tribes ALTER COLUMN slug SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS tribes_slug_unique ON public.tribes (slug);

-- 3) Memberships rename: space_memberships → tribe_members.
ALTER TABLE public.space_memberships RENAME TO tribe_members;
ALTER TABLE public.tribe_members     RENAME COLUMN space_id TO tribe_id;

-- 4) Posts: space_id → tribe_id, plus loosen the FK so posts survive a
--    deleted tribe (they fall back to the global feed instead of vanishing).
ALTER TABLE public.posts RENAME COLUMN space_id TO tribe_id;
ALTER TABLE public.posts DROP CONSTRAINT IF EXISTS posts_space_id_fkey;
ALTER TABLE public.posts
    ADD CONSTRAINT posts_tribe_id_fkey
    FOREIGN KEY (tribe_id) REFERENCES public.tribes(tribe_id) ON DELETE SET NULL;

DROP INDEX IF EXISTS idx_posts_space_created;
CREATE INDEX IF NOT EXISTS idx_posts_tribe_created
    ON public.posts(tribe_id, created_at DESC)
    WHERE deleted_at IS NULL;

-- 5) Drop the old tribes_follows table — its concept is now subsumed by
--    tribe_members. Also drop its trigger functions (they referenced
--    plug_profiles.tribe_count, which we now compute per-tribe).
DROP TABLE   IF EXISTS public.tribes_follows CASCADE;
DROP FUNCTION IF EXISTS public.trg_inc_tribe_count() CASCADE;
DROP FUNCTION IF EXISTS public.trg_dec_tribe_count() CASCADE;

-- 6) Atomic tribes.member_count maintenance.
CREATE OR REPLACE FUNCTION public.trg_inc_tribe_member_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.tribes
       SET member_count = member_count + 1
     WHERE tribe_id = NEW.tribe_id;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.trg_dec_tribe_member_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.tribes
       SET member_count = GREATEST(member_count - 1, 0)
     WHERE tribe_id = OLD.tribe_id;
    RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS tribe_members_inc ON public.tribe_members;
DROP TRIGGER IF EXISTS tribe_members_dec ON public.tribe_members;
CREATE TRIGGER tribe_members_inc AFTER INSERT ON public.tribe_members
    FOR EACH ROW EXECUTE FUNCTION public.trg_inc_tribe_member_count();
CREATE TRIGGER tribe_members_dec AFTER DELETE ON public.tribe_members
    FOR EACH ROW EXECUTE FUNCTION public.trg_dec_tribe_member_count();

-- 7) RLS — replace the legacy "spaces *" / "space_memberships *" policies.
DROP POLICY IF EXISTS "spaces readable"               ON public.tribes;
DROP POLICY IF EXISTS "spaces insert auth"            ON public.tribes;
DROP POLICY IF EXISTS "space_memberships self"        ON public.tribe_members;
DROP POLICY IF EXISTS "space_memberships readable"    ON public.tribe_members;

-- Public tribes readable to anyone; private tribes only to members.
CREATE POLICY "tribes readable"
    ON public.tribes FOR SELECT
    USING (
        NOT is_private
        OR EXISTS (
            SELECT 1 FROM public.tribe_members m
             WHERE m.tribe_id = tribes.tribe_id AND m.user_id = auth.uid()
        )
    );

-- Any authenticated user can create a tribe — they become its keeper.
CREATE POLICY "tribes insert auth"
    ON public.tribes FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL AND keeper_id = auth.uid());

CREATE POLICY "tribes update keeper"
    ON public.tribes FOR UPDATE
    USING       (keeper_id = auth.uid())
    WITH CHECK  (keeper_id = auth.uid());

CREATE POLICY "tribes delete keeper"
    ON public.tribes FOR DELETE
    USING (keeper_id = auth.uid());

CREATE POLICY "tribe_members readable"
    ON public.tribe_members FOR SELECT USING (true);
CREATE POLICY "tribe_members self"
    ON public.tribe_members FOR ALL
    USING       (user_id = auth.uid())
    WITH CHECK  (user_id = auth.uid());

-- 8) Keepers can delete any post inside their own tribe (existing
--    author-owns-post policy stays in place; this adds a parallel right).
DROP POLICY IF EXISTS "posts delete keeper" ON public.posts;
CREATE POLICY "posts delete keeper"
    ON public.posts FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = posts.tribe_id AND t.keeper_id = auth.uid()
        )
    );

-- 9) Refreshed read views.
DROP VIEW IF EXISTS public.tribe_directory;
CREATE VIEW public.tribe_directory WITH (security_invoker = true) AS
SELECT
    t.tribe_id, t.name, t.slug, t.description, t.category,
    t.member_count, t.is_private, t.created_at, t.rules,
    t.keeper_id,
    u.anonymous_pseudonym AS keeper_pseudonym,
    u.avatar_seed         AS keeper_avatar_seed,
    u.is_verified         AS keeper_is_verified
FROM public.tribes t
LEFT JOIN public.users u ON u.user_id = t.keeper_id;
GRANT SELECT ON public.tribe_directory TO anon, authenticated;

DROP VIEW IF EXISTS public.feed_posts;
CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(u.avatar_seed, 'default-orb')               AS author_avatar_seed,
    COALESCE(u.is_verified, false)                       AS author_is_verified,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
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
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
