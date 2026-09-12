-- =========================================================================
-- A fresh deployment of this chain is far more permissive than the database
-- we develop against
--
-- Found by replaying all 239 migrations into a pristine supabase/postgres
-- container — a faithful "new Supabase project" — and diffing the resulting
-- grants against the local development database. They do not match, and the
-- difference is not small: the fresh build carries 243 privileges that the
-- development database does not, and the development database carries none
-- that the fresh build lacks. Development is strictly tighter. Production
-- would have been built from the chain, so production would have been the
-- loose one.
--
-- Nothing we test catches this. Every pgTAP file, every probe in this
-- session, and every manual check ran against the development database,
-- which already has the hardening. The chain never had it.
--
-- WHAT WAS ACTUALLY EXPOSED
--
-- Demonstrated on the replay, acting as `anon` — the role behind the
-- publishable key that ships inside the mobile app and can be read out of the
-- binary:
--
--   admin_metrics_24h          7 of 12 columns readable: total_users,
--                              new_users_24h, new_users_7d, dau_commenters,
--                              total_tribes, comments_24h, active_broadcasts
--   admin_signups_hourly       fully readable: the hourly signup curve
--   admin_region_distribution  fully readable: users per country
--
-- Views do not carry RLS. A policy on the underlying table does not protect a
-- view over it, so the row-level work that protects `users` and `posts` does
-- nothing here. These three leaked outright.
--
-- `audit_log`, `admin_audit_log`, `analytics_events` and `automod_rules` were
-- also granted to anon but returned nothing, because they are tables with
-- policies that hold. That is one layer doing the work of two.
--
-- The 17 admin_* functions that became EXECUTE-able by anon all refused with
-- 'forbidden' — they derive the actor from auth.uid(), which is NULL for an
-- anonymous caller. Not exploitable. Also not a reason to leave it: the point
-- of revoking EXECUTE is that a mistake inside any one of those functions
-- should not be reachable from the public internet, and
-- admin_read_case_sensitive_evidence should never be one bug from anonymous.
--
-- WHY THE CHAIN DRIFTED
--
-- Supabase grants anon, authenticated and service_role full DML on new tables
-- and EXECUTE on new functions in `public`, by default privilege. Three
-- migrations touch those defaults and none of them close this:
--
--   20260728135525  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC
--   20260816020128  GRANT ... ON TABLES TO service_role
--   20260828201411  REVOKE TRUNCATE ON TABLES FROM anon, authenticated
--
-- The first is the near miss. Revoking from PUBLIC does not remove an
-- explicit default grant held by anon, so every function created after it was
-- still anon-executable — which is precisely what that migration set out to
-- prevent. Its own name says so.
--
-- The development database has tighter defaults than any migration produces,
-- so the hardening arrived there by some path outside this chain. That is
-- worth knowing on its own: it means the database we reason about is not the
-- database our migrations describe.
--
-- WHAT THIS MIGRATION DOES
--
-- Brings a fresh build to parity with the development database, in two parts.
-- The defaults are corrected so new objects stop inheriting the permissive
-- grants, and the grants already accumulated are revoked explicitly, since
-- default privileges only apply at creation time and every existing object
-- already has its own ACL.
--
-- The revoke list is generated, not hand-written: it is exactly the set
-- difference between the replay and the development database. Because
-- development holds no grant the fresh build lacks, this can only tighten —
-- it cannot remove anything the client has been relying on, since the client
-- has been running against the tighter side all along.
-- =========================================================================

-- =========================================================================
-- 1) Defaults, so new objects stop arriving permissive
-- =========================================================================

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE SELECT, USAGE ON SEQUENCES FROM anon, authenticated, service_role;

-- =========================================================================
-- 2) The grants already handed out
--
-- Generated from the replay-versus-development diff. 243 privileges over 124
-- (role, object) pairs.
-- =========================================================================

-- anon: 88 objects
REVOKE SELECT ON public.admin_audit_log FROM anon;
REVOKE SELECT ON public.admin_broadcasts FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.admin_metrics_24h FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.admin_posts_hourly FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.admin_region_distribution FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.admin_reports_daily FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.admin_signups_hourly FROM anon;
REVOKE SELECT ON public.analytics_events FROM anon;
REVOKE SELECT ON public.app_events FROM anon;
REVOKE SELECT ON public.audit_log FROM anon;
REVOKE SELECT ON public.automod_rules FROM anon;
REVOKE SELECT ON public.badge_definitions FROM anon;
REVOKE SELECT ON public.chat_message_hides FROM anon;
REVOKE SELECT ON public.chat_message_reactions FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.chat_message_reactions_summary FROM anon;
REVOKE SELECT ON public.chat_messages FROM anon;
REVOKE SELECT ON public.chat_rooms FROM anon;
REVOKE SELECT ON public.comment_likes FROM anon;
REVOKE SELECT ON public.dm_room_prefs FROM anon;
REVOKE SELECT ON public.email_outbox FROM anon;
REVOKE SELECT ON public.feature_flag_overrides FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.feed_hot FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.feed_posts FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.friend_requests_inbox FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.friend_requests_outbox FROM anon;
REVOKE SELECT ON public.friendship_favorites FROM anon;
REVOKE SELECT ON public.friendships FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.latest_space_summary FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.my_blocks FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.my_friends FROM anon;
REVOKE SELECT ON public.notifications FROM anon;
REVOKE SELECT ON public.personas FROM anon;
REVOKE SELECT ON public.plug_profiles FROM anon;
REVOKE SELECT ON public.plug_prompts FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.policy_acceptances FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.policy_documents FROM anon;
REVOKE SELECT ON public.poll_options FROM anon;
REVOKE SELECT ON public.poll_votes FROM anon;
REVOKE SELECT ON public.post_likes FROM anon;
REVOKE SELECT ON public.post_polls FROM anon;
REVOKE SELECT ON public.post_saves FROM anon;
REVOKE SELECT ON public.posts FROM anon;
REVOKE SELECT ON public.posts_comments FROM anon;
REVOKE SELECT ON public.prompt_answers FROM anon;
REVOKE SELECT ON public.push_tokens FROM anon;
REVOKE SELECT ON public.question_likes FROM anon;
REVOKE SELECT ON public.question_reports FROM anon;
REVOKE SELECT ON public.rate_limits FROM anon;
REVOKE SELECT ON public.reports FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.space_directory FROM anon;
REVOKE SELECT ON public.space_summaries FROM anon;
REVOKE SELECT ON public.spaces FROM anon;
REVOKE SELECT ON public.story_views FROM anon;
REVOKE SELECT ON public.subscriptions FROM anon;
REVOKE SELECT ON public.tribe_audit_log FROM anon;
REVOKE SELECT ON public.tribe_bans FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.tribe_chat_media FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.tribe_directory FROM anon;
REVOKE SELECT ON public.tribe_invites FROM anon;
REVOKE SELECT ON public.tribe_join_requests FROM anon;
REVOKE SELECT ON public.tribe_keyword_filters FROM anon;
REVOKE SELECT ON public.tribe_member_warnings FROM anon;
REVOKE SELECT ON public.tribe_members FROM anon;
REVOKE SELECT ON public.tribe_message_hides FROM anon;
REVOKE SELECT ON public.tribe_message_hugs FROM anon;
REVOKE SELECT ON public.tribe_message_poll_votes FROM anon;
REVOKE SELECT ON public.tribe_message_reactions FROM anon;
REVOKE SELECT ON public.tribe_messages FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.tribe_messages_feed FROM anon;
REVOKE SELECT ON public.tribe_moderation_actions FROM anon;
REVOKE SELECT ON public.tribe_ownership_transfers FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.tribe_studio_stats FROM anon;
REVOKE SELECT ON public.tribes FROM anon;
REVOKE SELECT ON public.user_active_days FROM anon;
REVOKE SELECT ON public.user_badges FROM anon;
REVOKE SELECT ON public.user_blocks FROM anon;
REVOKE SELECT ON public.user_streaks FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.verification_evidence FROM anon;
REVOKE SELECT ON public.verification_requests FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.verification_review_events FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.weak_password_bases FROM anon;
REVOKE SELECT ON public.whisper_comment_likes FROM anon;
REVOKE SELECT ON public.whisper_comments FROM anon;
REVOKE SELECT ON public.whisper_listens FROM anon;
REVOKE SELECT ON public.whisper_reactions FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.whisper_reactions_summary FROM anon;
REVOKE SELECT ON public.whisper_saves FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.whispers_feed FROM anon;

-- authenticated: 36 objects
REVOKE SELECT ON public.admin_broadcasts FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.admin_metrics_24h FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.admin_posts_hourly FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.admin_region_distribution FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.admin_reports_daily FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.admin_signups_hourly FROM authenticated;
REVOKE SELECT ON public.app_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.chat_message_reactions_summary FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.feed_hot FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.feed_posts FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.friend_requests_inbox FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.friend_requests_outbox FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.inbox_rooms FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.latest_space_summary FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.my_blocks FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.my_friends FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.policy_acceptances FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.policy_documents FROM authenticated;
REVOKE SELECT ON public.rate_limits FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.space_directory FROM authenticated;
REVOKE SELECT ON public.space_summaries FROM authenticated;
REVOKE SELECT ON public.spaces FROM authenticated;
REVOKE SELECT ON public.story_views FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.tribe_chat_media FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.tribe_directory FROM authenticated;
REVOKE SELECT ON public.tribe_message_poll_votes FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.tribe_messages_feed FROM authenticated;
REVOKE SELECT ON public.tribe_moderation_actions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.tribe_studio_stats FROM authenticated;
REVOKE SELECT ON public.user_active_days FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.verification_evidence FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.verification_review_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.weak_password_bases FROM authenticated;
REVOKE SELECT ON public.whisper_listens FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.whisper_reactions_summary FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.whispers_feed FROM authenticated;


-- =========================================================================
-- 3) EXECUTE on functions
--
-- Default privileges only bind at creation, so correcting them above does
-- nothing for the functions that already exist. These 23 grants are the
-- set difference between the replay and the development database: 17 admin_*
-- functions reachable by anon, plus six more.
--
-- All 17 refuse an anonymous caller today — they resolve the actor from
-- auth.uid(), which is NULL — so this closes an outer gate rather than an
-- open door. That gate is the reason a mistake inside any one of them is not
-- a public-internet problem, and admin_read_case_sensitive_evidence should
-- never be one bug away from anonymous.
-- =========================================================================

REVOKE EXECUTE ON FUNCTION public.admin_appeal_queue(p_status text, p_limit integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_assign_case(p_case uuid, p_assignee uuid, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_case_queue(p_status text, p_assignee uuid, p_limit integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_clear_crisis_flag(p_target_type text, p_target_id uuid, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_create_automod_rule(p_pattern text, p_match_type text, p_category text, p_action text, p_note text, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_deactivate_broadcast(p_broadcast uuid, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_decide_appeal(p_appeal uuid, p_outcome text, p_note text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_decide_case(p_case uuid, p_decision text, p_policy_code text, p_note text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_delete_automod_rule(p_rule uuid, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_global_search(p_query text, p_limit integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_lift_suspension(p_target uuid, p_reason text, p_notify boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_read_case_sensitive_evidence(p_case uuid, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_case_legal_hold(p_case uuid, p_hold boolean, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_case_status(p_case uuid, p_status text, p_note text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_flag(p_key text, p_enabled boolean, p_rollout_pct integer, p_reason text, p_description text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_user_status(p_target uuid, p_status text, p_reason text, p_notify boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_toggle_automod_rule(p_rule uuid, p_active boolean, p_reason text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.can_initiate_dm(p_target uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.friend_stories_for_me(p_limit integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_restricted_minor(p_user uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_my_birth_year(p_birth_year integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.submit_appeal(p_case uuid, p_statement text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_appeal(p_appeal uuid) FROM anon;

SELECT public.record_migration(
  '20261019090000', 'fresh_deploy_grant_parity'
);

NOTIFY pgrst, 'reload schema';
