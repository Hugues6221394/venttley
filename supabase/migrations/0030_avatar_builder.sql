-- 0030_avatar_builder.sql
--
-- Tiny RPC the Avatar Builder calls to commit a new avatar_seed. RLS
-- on public.users already lets a user UPDATE their own row, but routing
-- through a SECURITY DEFINER function lets us validate the seed format
-- in one place and gives us a single audit point if we ever want to
-- log avatar changes.
--
-- Accepts:
--   - v2 seeds: "v2:silhouette=...;palette=...;hair=...;accessory=...;aura=..."
--   - legacy strings (kebab-cased identifiers, max 64 chars) so old
--     persona / dev rows keep working.

CREATE OR REPLACE FUNCTION public.update_user_avatar(p_seed TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_seed IS NULL OR length(p_seed) = 0 OR length(p_seed) > 256 THEN
        RAISE EXCEPTION 'invalid seed length';
    END IF;
    IF p_seed !~ '^(v2:[a-z0-9=;]+|[a-z0-9_-]+)$' THEN
        RAISE EXCEPTION 'invalid seed format';
    END IF;
    UPDATE public.users SET avatar_seed = p_seed, updated_at = now()
     WHERE user_id = v_me;
END $$;

REVOKE ALL ON FUNCTION public.update_user_avatar(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_avatar(TEXT) TO authenticated;
