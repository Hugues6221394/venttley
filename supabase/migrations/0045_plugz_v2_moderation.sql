-- 0045_plugz_v2_moderation.sql
--
-- Plugz V2 moderation center. Adds two tribe-scoped tables + a friendly
-- rules editor on the existing `tribes.rules` JSONB column.
--
-- * tribe_keyword_filters — keeper-curated keyword block list. When a
--   post or chat message contains any active filter, the moderation
--   pipeline can soft-hide it for keeper review.
-- * tribe_member_warnings — soft warnings issued by the keeper/mod with
--   a note + auto-escalating counter (3 warnings → consider for kick).
--
-- The reports queue itself already exists (migration 0006 + 0008 keeper
-- tools) — this migration just provides the moderation-side primitives.

-- =========================================================================
-- 1) tribe_keyword_filters
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tribe_keyword_filters (
    filter_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tribe_id      UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    keyword       TEXT NOT NULL CHECK (length(keyword) BETWEEN 2 AND 80),
    severity      TEXT NOT NULL DEFAULT 'soft'
                  CHECK (severity IN ('soft', 'hard')),
    created_by    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tribe_id, keyword)
);
CREATE INDEX IF NOT EXISTS tribe_keyword_filters_tribe_idx
    ON public.tribe_keyword_filters (tribe_id);

ALTER TABLE public.tribe_keyword_filters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "kw filter keeper read" ON public.tribe_keyword_filters;
CREATE POLICY "kw filter keeper read"
    ON public.tribe_keyword_filters FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = tribe_keyword_filters.tribe_id
           AND t.keeper_id = auth.uid()
      )
    );
GRANT SELECT ON public.tribe_keyword_filters TO authenticated;

-- =========================================================================
-- 2) tribe_member_warnings
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tribe_member_warnings (
    warning_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tribe_id      UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    member_id     UUID NOT NULL REFERENCES public.users(user_id)   ON DELETE CASCADE,
    issued_by     UUID NOT NULL REFERENCES public.users(user_id)   ON DELETE SET NULL,
    reason        TEXT NOT NULL CHECK (length(reason) BETWEEN 4 AND 500),
    severity      TEXT NOT NULL DEFAULT 'note'
                  CHECK (severity IN ('note', 'warning', 'final')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    acknowledged_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS tribe_member_warnings_tribe_idx
    ON public.tribe_member_warnings (tribe_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tribe_member_warnings_member_idx
    ON public.tribe_member_warnings (member_id);

ALTER TABLE public.tribe_member_warnings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "warning keeper read" ON public.tribe_member_warnings;
CREATE POLICY "warning keeper read"
    ON public.tribe_member_warnings FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM tribes t
         WHERE t.tribe_id = tribe_member_warnings.tribe_id
           AND t.keeper_id = auth.uid()
      ) OR member_id = auth.uid()
    );
GRANT SELECT ON public.tribe_member_warnings TO authenticated;

-- =========================================================================
-- 3) RPCs — add / remove keyword filter, warn member, set rules
-- =========================================================================
CREATE OR REPLACE FUNCTION public.add_keyword_filter(
    p_tribe_id UUID,
    p_keyword  TEXT,
    p_severity TEXT DEFAULT 'soft'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
    v_is_keeper BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT keeper_id = v_me INTO v_is_keeper FROM tribes WHERE tribe_id = p_tribe_id;
    IF NOT COALESCE(v_is_keeper, false) THEN RAISE EXCEPTION 'not a keeper'; END IF;

    INSERT INTO tribe_keyword_filters (tribe_id, keyword, severity, created_by)
    VALUES (p_tribe_id, lower(trim(p_keyword)), p_severity, v_me)
    ON CONFLICT (tribe_id, keyword) DO UPDATE SET severity = EXCLUDED.severity
    RETURNING filter_id INTO v_id;
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.add_keyword_filter(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_keyword_filter(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.remove_keyword_filter(p_filter_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    DELETE FROM tribe_keyword_filters
     WHERE filter_id = p_filter_id
       AND EXISTS (
         SELECT 1 FROM tribes t
          WHERE t.tribe_id = tribe_keyword_filters.tribe_id
            AND t.keeper_id = v_me
       );
END $$;

REVOKE ALL ON FUNCTION public.remove_keyword_filter(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_keyword_filter(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.warn_member(
    p_tribe_id  UUID,
    p_member_id UUID,
    p_reason    TEXT,
    p_severity  TEXT DEFAULT 'warning'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_is_keeper BOOLEAN;
    v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT keeper_id = v_me INTO v_is_keeper FROM tribes WHERE tribe_id = p_tribe_id;
    IF NOT COALESCE(v_is_keeper, false) THEN RAISE EXCEPTION 'not a keeper'; END IF;
    IF p_member_id = v_me THEN RAISE EXCEPTION 'cannot warn yourself'; END IF;

    INSERT INTO tribe_member_warnings (tribe_id, member_id, issued_by, reason, severity)
    VALUES (p_tribe_id, p_member_id, v_me, p_reason, p_severity)
    RETURNING warning_id INTO v_id;
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.warn_member(UUID, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.warn_member(UUID, UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_tribe_rules(
    p_tribe_id UUID,
    p_rules    JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_is_keeper BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT keeper_id = v_me INTO v_is_keeper FROM tribes WHERE tribe_id = p_tribe_id;
    IF NOT COALESCE(v_is_keeper, false) THEN RAISE EXCEPTION 'not a keeper'; END IF;

    UPDATE tribes SET rules = COALESCE(p_rules, '{}'::jsonb)
     WHERE tribe_id = p_tribe_id;
END $$;

REVOKE ALL ON FUNCTION public.set_tribe_rules(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_tribe_rules(UUID, JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';
