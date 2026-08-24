BEGIN;

-- PostgreSQL 17 Supabase projects no longer auto-expose newly-created tables.
-- Keep the API contract explicit and limited to relations the Flutter client
-- accesses directly. RLS remains the row-authorization boundary, while core
-- mutations continue to use their authenticated RPCs.
GRANT SELECT ON TABLE
  public.automod_rules,
  public.badge_definitions,
  public.chat_message_hides,
  public.chat_messages,
  public.chat_rooms,
  public.comment_likes,
  public.crisis_resources,
  public.dm_room_prefs,
  public.friendship_favorites,
  public.notifications,
  public.personas,
  public.plug_profiles,
  public.plug_prompts,
  public.poll_options,
  public.poll_votes,
  public.post_likes,
  public.post_polls,
  public.post_saves,
  public.posts,
  public.posts_comments,
  public.prompt_answers,
  public.question_likes,
  public.question_reports,
  public.reports,
  public.subscriptions,
  public.tribe_audit_log,
  public.tribe_bans,
  public.tribe_invites,
  public.tribe_join_requests,
  public.tribe_keyword_filters,
  public.tribe_member_warnings,
  public.tribe_members,
  public.tribe_message_hides,
  public.tribe_pinned_posts,
  public.tribes,
  public.user_badges,
  public.user_streaks,
  public.whisper_comment_likes,
  public.whisper_saves
TO authenticated;

GRANT INSERT ON TABLE
  public.plug_prompts,
  public.poll_options,
  public.post_likes,
  public.post_polls,
  public.post_saves,
  public.prompt_answers,
  public.question_likes,
  public.question_reports,
  public.reports,
  public.tribe_invites,
  public.tribe_members,
  public.whisper_saves
TO authenticated;

GRANT UPDATE ON TABLE
  public.notifications,
  public.post_likes,
  public.plug_prompts,
  public.prompt_answers,
  public.reports,
  public.tribe_invites,
  public.tribes
TO authenticated;

GRANT DELETE ON TABLE
  public.notifications,
  public.plug_prompts,
  public.post_likes,
  public.post_saves,
  public.prompt_answers,
  public.question_likes,
  public.whisper_saves
TO authenticated;

-- Trusted Edge Functions use the service role for canonical worker reads and
-- writes. PostgreSQL 17 projects no longer inherit those relation privileges,
-- even though the role still bypasses RLS.
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA public
  TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;

-- TRUNCATE bypasses RLS and is never a client operation. Older Supabase
-- defaults granted it broadly, so remove it from every current base table.
DO $block$
DECLARE
  relation_name TEXT;
BEGIN
  FOR relation_name IN
    SELECT format('%I.%I', namespace.nspname, class.relname)
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relkind IN ('r', 'p')
  LOOP
    EXECUTE format(
      'REVOKE TRUNCATE ON TABLE %s FROM anon, authenticated',
      relation_name
    );
  END LOOP;
END
$block$;

NOTIFY pgrst, 'reload schema';

COMMIT;
