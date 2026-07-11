-- 0092_data_export_dsar.sql
-- GDPR/CCPA data portability: let a user export ALL their own data on demand.
-- Complements account deletion (which already exists). SECURITY DEFINER so it
-- can read across tables regardless of RLS, but STRICTLY scoped to auth.uid() —
-- a caller only ever gets their own rows.
--
-- DM bodies are end-to-end encrypted (chat_messages.encrypted_payload) and not
-- readable on the server, so only their metadata is exported, with a note.

CREATE OR REPLACE FUNCTION public.export_my_data()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid(); v_out JSONB;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT jsonb_build_object(
        'exported_at', now(),
        'format',      'venttly-dsar-v1',
        'account', (
            SELECT jsonb_build_object(
                'user_id',        u.user_id,
                'pseudonym',      u.anonymous_pseudonym,
                'created_at',     u.created_at,
                'birth_year',     u.birth_year,
                'home_city',      u.home_city,
                'home_country',   u.home_country,
                'last_country',   u.last_country,
                'bio',            u.bio,
                'pronouns',       u.pronouns,
                'karma_points',   u.karma_points,
                'account_status', u.account_status
            ) FROM public.users u WHERE u.user_id = v_me
        ),
        'posts', (
            SELECT coalesce(jsonb_agg(to_jsonb(p) - 'author_id'), '[]'::jsonb)
              FROM public.posts p WHERE p.author_id = v_me
        ),
        'comments', (
            SELECT coalesce(jsonb_agg(to_jsonb(c) - 'author_id'), '[]'::jsonb)
              FROM public.posts_comments c WHERE c.author_id = v_me
        ),
        'whispers', (
            SELECT coalesce(jsonb_agg(to_jsonb(w) - 'author_id'), '[]'::jsonb)
              FROM public.whispers w WHERE w.author_id = v_me
        ),
        'tribe_messages', (
            SELECT coalesce(jsonb_agg(to_jsonb(tm) - 'sender_id'), '[]'::jsonb)
              FROM public.tribe_messages tm WHERE tm.sender_id = v_me
        ),
        'direct_messages', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'message_id', m.message_id,
                'room_id',    m.room_id,
                'created_at', m.created_at,
                'edited_at',  m.edited_at,
                'note', 'Body is end-to-end encrypted and not readable on the server.'
            )), '[]'::jsonb)
              FROM public.chat_messages m WHERE m.sender_id = v_me
        ),
        'reactions', (
            SELECT coalesce(jsonb_agg(to_jsonb(l) - 'user_id'), '[]'::jsonb)
              FROM public.post_likes l WHERE l.user_id = v_me
        ),
        'reports_filed', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'report_id',  r.report_id,
                'reason',     r.reason,
                'created_at', r.created_at
            )), '[]'::jsonb)
              FROM public.reports r WHERE r.reporter_id = v_me
        ),
        'tribe_memberships', (
            SELECT coalesce(jsonb_agg(to_jsonb(tmem) - 'user_id'), '[]'::jsonb)
              FROM public.tribe_members tmem WHERE tmem.user_id = v_me
        )
    ) INTO v_out;

    RETURN v_out;
END $$;

REVOKE ALL ON FUNCTION public.export_my_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.export_my_data() TO authenticated;

NOTIFY pgrst, 'reload schema';
