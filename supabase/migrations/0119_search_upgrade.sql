-- 0119: Search upgrade — trigram acceleration, suggestions, trending.
--
-- search_global (0090s) does ILIKE '%q%' scans; pg_trgm GIN indexes make
-- those index scans instead of seq scans, which is the difference between
-- 5ms and 500ms once posts hit six digits. Also adds:
--   search_suggestions(p_prefix) — typeahead over people/tribes/categories
--   trending_searches()          — what the app is talking about right now

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Accelerate the existing ILIKE search paths.
CREATE INDEX IF NOT EXISTS idx_users_pseudonym_trgm
  ON public.users USING gin (anonymous_pseudonym gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_tribes_name_trgm
  ON public.tribes USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_posts_content_trgm
  ON public.posts USING gin (content gin_trgm_ops);

-- ============================================================
-- Typeahead: people first (friends would need a join — pseudonym match is
-- enough at this size), then tribes, then categories. Trigram similarity
-- gives typo tolerance: "midnigt" still finds "Midnight Confessions".
-- ============================================================
CREATE OR REPLACE FUNCTION public.search_suggestions(
  p_prefix TEXT,
  p_limit INT DEFAULT 8
) RETURNS TABLE (kind TEXT, value TEXT, display TEXT)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
  v_q TEXT := trim(coalesce(p_prefix, ''));
  v_limit INT := least(greatest(coalesce(p_limit, 8), 1), 20);
BEGIN
  IF length(v_q) < 2 THEN RETURN; END IF;
  RETURN QUERY
  (
    SELECT 'user'::TEXT, u.anonymous_pseudonym::TEXT,
           ('@' || u.anonymous_pseudonym)::TEXT
      FROM public.users u
     WHERE u.deactivated_at IS NULL
       AND u.shadow_banned IS NOT TRUE
       AND (u.anonymous_pseudonym ILIKE v_q || '%'
            OR similarity(u.anonymous_pseudonym, v_q) > 0.3)
     ORDER BY similarity(u.anonymous_pseudonym, v_q) DESC
     LIMIT v_limit
  )
  UNION ALL
  (
    SELECT 'tribe'::TEXT, t.slug::TEXT, t.name::TEXT
      FROM public.tribes t
     WHERE t.name ILIKE v_q || '%' OR similarity(t.name, v_q) > 0.3
     ORDER BY similarity(t.name, v_q) DESC
     LIMIT v_limit
  )
  UNION ALL
  (
    SELECT DISTINCT 'category'::TEXT, p.category_name::TEXT,
           initcap(replace(p.category_name, '_', ' '))::TEXT
      FROM public.posts p
     WHERE p.category_name ILIKE v_q || '%'
     LIMIT 3
  )
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.search_suggestions(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_suggestions(TEXT, INT) TO authenticated;

-- ============================================================
-- Trending: the busiest categories and tribes of the last 24h, for the
-- idle state of the search screen.
-- ============================================================
CREATE OR REPLACE FUNCTION public.trending_searches(p_limit INT DEFAULT 8)
RETURNS TABLE (kind TEXT, value TEXT, display TEXT, activity BIGINT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
  (
    SELECT 'category'::TEXT, p.category_name::TEXT,
           initcap(replace(p.category_name, '_', ' '))::TEXT,
           count(*)::BIGINT AS activity
      FROM public.posts p
     WHERE p.created_at > NOW() - INTERVAL '24 hours'
       AND p.deleted_at IS NULL
     GROUP BY p.category_name
     ORDER BY count(*) DESC
     LIMIT least(greatest(coalesce(p_limit, 8), 1), 20) / 2 + 1
  )
  UNION ALL
  (
    SELECT 'tribe'::TEXT, t.slug::TEXT, t.name::TEXT,
           count(*)::BIGINT AS activity
      FROM public.tribe_messages m
      JOIN public.tribes t ON t.tribe_id = m.tribe_id
     WHERE m.created_at > NOW() - INTERVAL '24 hours'
       AND m.deleted_at IS NULL
     GROUP BY t.slug, t.name
     ORDER BY count(*) DESC
     LIMIT least(greatest(coalesce(p_limit, 8), 1), 20) / 2 + 1
  )
  ORDER BY activity DESC
  LIMIT least(greatest(coalesce(p_limit, 8), 1), 20);
$$;

REVOKE ALL ON FUNCTION public.trending_searches(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trending_searches(INT) TO authenticated;
