BEGIN;

-- Existing projects created before PostgreSQL 17 can retain broad table DML
-- grants that newer clean projects no longer receive. Start from a deny-by-
-- default mutation posture for API roles, then restore only operations used
-- directly by the audited Flutter client. SECURITY DEFINER RPCs and trusted
-- service-role workers are unaffected.
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
      'REVOKE INSERT, UPDATE, DELETE ON TABLE %s FROM anon, authenticated',
      relation_name
    );
  END LOOP;
END
$block$;

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

-- Sign-up recovery sealing and the current location editor still use direct
-- owner-row updates. Limit those calls to their exact columns; the users RLS
-- owner policy and identity guard continue to enforce row and value rules.
GRANT UPDATE (
  recovery_blob,
  recovery_salt,
  home_city,
  home_country,
  home_campus
) ON TABLE public.users TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
