-- ============================================================================
-- Venttly | Migration 0009 — Admin moderation columns
--
-- Adds the minimum columns the super-admin console needs to act on tribes
-- and broadcast notifications, without touching the regular member flows.
-- ============================================================================

-- Featured tribes surface to the home tribes rail with priority. Toggled by
-- super_admins only — the existing "tribes update keeper" policy does NOT
-- cover this (keepers don't get to mark their own tribe featured). RLS is
-- additive, so super_admins still pass via the service-role key on the
-- admin web app.
ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS is_featured BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_tribes_featured
    ON public.tribes(is_featured, member_count DESC)
    WHERE is_featured = true;

-- Tribe-level suspend flag — soft, reversible. When set, the tribe stops
-- showing in the public directory and posts to it are gated client-side.
-- v1 admin UI is the source of truth; no member-visible "suspended" badge.
ALTER TABLE public.tribes
    ADD COLUMN IF NOT EXISTS is_suspended BOOLEAN NOT NULL DEFAULT FALSE;

-- A simple broadcasts log so the admin Notifications page can list
-- announcements separately from per-user notification rows.
CREATE TABLE IF NOT EXISTS public.admin_broadcasts (
    broadcast_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sent_by       UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    title         TEXT NOT NULL,
    body          TEXT NOT NULL,
    recipient_count INT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_broadcasts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "broadcasts admin read" ON public.admin_broadcasts;
CREATE POLICY "broadcasts admin read"
    ON public.admin_broadcasts FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.users u
             WHERE u.user_id   = auth.uid()
               AND u.user_role = 'super_admin'
        )
    );
-- No INSERT policy — the admin console uses the service role key.

NOTIFY pgrst, 'reload schema';
