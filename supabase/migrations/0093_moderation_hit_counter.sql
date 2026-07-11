-- 0093_moderation_hit_counter.sql
-- Make the moderation cache's effectiveness observable: increment hit_count
-- each time a cached verdict is served (the `moderate` edge function calls this
-- on a cache hit). Cache hit-rate ≈ (sum(hit_count) - count(*)) / sum(hit_count),
-- surfaced on the Ops & cost admin page.
--
-- Service-role only (edge function); not granted to authenticated.

CREATE OR REPLACE FUNCTION public.bump_moderation_hit(p_hash TEXT)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    UPDATE public.moderation_verdicts
       SET hit_count = hit_count + 1, last_seen_at = now()
     WHERE content_hash = p_hash;
$$;

REVOKE ALL ON FUNCTION public.bump_moderation_hit(TEXT) FROM PUBLIC;

-- Ops & cost snapshot — one call, all real counts, for the admin dashboard.
-- is_staff gated (incl. analyst / auditor) so aggregates never leak.
CREATE OR REPLACE FUNCTION public.admin_ops_snapshot()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v JSONB;
BEGIN
    IF NOT is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    SELECT jsonb_build_object(
        'moderation', jsonb_build_object(
            'entries',        (SELECT count(*) FROM moderation_verdicts),
            'total_lookups',  (SELECT coalesce(sum(hit_count), 0) FROM moderation_verdicts),
            'safe',           (SELECT count(*) FROM moderation_verdicts WHERE verdict = 'safe'),
            'warn',           (SELECT count(*) FROM moderation_verdicts WHERE verdict = 'warn'),
            'block',          (SELECT count(*) FROM moderation_verdicts WHERE verdict = 'block'),
            'classified_30d', (SELECT count(*) FROM moderation_verdicts WHERE created_at > now() - interval '30 days')
        ),
        'media', jsonb_build_object(
            'blocked',   (SELECT count(*) FROM posts    WHERE media_status = 'blocked')
                       + (SELECT count(*) FROM whispers WHERE media_status = 'blocked'),
            'sensitive', (SELECT count(*) FROM posts    WHERE media_status = 'sensitive')
                       + (SELECT count(*) FROM whispers WHERE media_status = 'sensitive'),
            'pending',   (SELECT count(*) FROM posts    WHERE media_status = 'pending')
                       + (SELECT count(*) FROM whispers WHERE media_status = 'pending')
        ),
        'abuse', jsonb_build_object(
            'active_suspensions', (
                SELECT count(*) FROM users
                 WHERE account_status = 'suspended'
                   AND (suspended_until IS NULL OR suspended_until > now())
            )
        ),
        'volume_30d', jsonb_build_object(
            'posts',          (SELECT count(*) FROM posts          WHERE created_at > now() - interval '30 days'),
            'comments',       (SELECT count(*) FROM posts_comments WHERE created_at > now() - interval '30 days'),
            'tribe_messages', (SELECT count(*) FROM tribe_messages WHERE created_at > now() - interval '30 days'),
            'dms',            (SELECT count(*) FROM chat_messages  WHERE created_at > now() - interval '30 days'),
            'whispers',       (SELECT count(*) FROM whispers       WHERE created_at > now() - interval '30 days')
        )
    ) INTO v;
    RETURN v;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_ops_snapshot() TO authenticated;

NOTIFY pgrst, 'reload schema';
