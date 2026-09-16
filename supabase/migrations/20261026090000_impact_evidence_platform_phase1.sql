-- Venttly Impact & Evidence Platform — privacy-safe phase 1.
--
-- This is deliberately an aggregate reporting system, not a second product
-- analytics feed. Raw product activity stays in the canonical product tables
-- and app_events. Research identity and consent live in `private`, which is
-- not exposed by the Data API. The admin console receives only cohort-safe
-- DTOs through staff-gated functions.

CREATE SCHEMA IF NOT EXISTS private;

-- -------------------------------------------------------------------------
-- 1. Separate product-analytics identity from Auth and public persona ids.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.analytics_subjects (
  user_id UUID PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
  subject_id UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE private.analytics_subjects FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.my_analytics_subject()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user UUID := (SELECT auth.uid());
  v_subject UUID;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO private.analytics_subjects (user_id)
  VALUES (v_user)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT subject_id INTO v_subject
    FROM private.analytics_subjects
   WHERE user_id = v_user;
  RETURN v_subject;
END;
$$;

REVOKE ALL ON FUNCTION public.my_analytics_subject() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_analytics_subject() TO authenticated;

-- -------------------------------------------------------------------------
-- 2. Governed event taxonomy. This registry is the reviewable contract;
--    app_events remains the one canonical event ledger.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.impact_event_taxonomy (
  event_name TEXT PRIMARY KEY CHECK (event_name ~ '^[A-Za-z0-9$][A-Za-z0-9._$-]{0,79}$'),
  domain TEXT NOT NULL CHECK (domain IN (
    'lifecycle','auth','profile','content','engagement','music','social',
    'messaging','discovery','notification','billing','screen','reliability'
  )),
  purpose TEXT NOT NULL CHECK (length(purpose) BETWEEN 3 AND 240),
  allowed_properties TEXT[] NOT NULL DEFAULT '{}',
  impact_eligible BOOLEAN NOT NULL DEFAULT false,
  retention_days INTEGER NOT NULL DEFAULT 400 CHECK (retention_days BETWEEN 1 AND 1095),
  privacy_classification TEXT NOT NULL DEFAULT 'INTERNAL' CHECK (
    privacy_classification IN ('PUBLIC','INTERNAL','CONFIDENTIAL','HIGHLY_RESTRICTED','SECURITY_CRITICAL')
  ),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','deprecated','blocked')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE private.impact_event_taxonomy FROM PUBLIC, anon, authenticated;

INSERT INTO private.impact_event_taxonomy
  (event_name, domain, purpose, allowed_properties, impact_eligible)
VALUES
  ('app.opened','lifecycle','Measure an authenticated application open.',ARRAY['platform','app_version'],true),
  ('app.backgrounded','lifecycle','Measure an application entering the background.',ARRAY['duration_seconds'],false),
  ('onboarding.started','auth','Measure entry into onboarding.',ARRAY['provider'],true),
  ('onboarding.completed','auth','Measure successful onboarding completion.',ARRAY['provider'],true),
  ('auth.signup_anonymous','auth','Measure anonymous account creation.',ARRAY[]::TEXT[],true),
  ('auth.signup_email','auth','Measure email account creation without collecting the address.',ARRAY[]::TEXT[],true),
  ('auth.signin_anonymous','auth','Measure anonymous sign-in.',ARRAY[]::TEXT[],false),
  ('auth.signin_email','auth','Measure email sign-in without collecting the address.',ARRAY[]::TEXT[],false),
  ('auth.recovery_used','auth','Measure recovery completion.',ARRAY['provider'],false),
  ('auth.logout','auth','Measure sign-out.',ARRAY[]::TEXT[],false),
  ('profile.display_name_updated','profile','Measure identity-setting completion without names.',ARRAY[]::TEXT[],false),
  ('post.created','content','Measure a published Vent without its text.',ARRAY['category','content_chars','has_image','has_music','has_poll','is_story','mood','story_audience'],true),
  ('post.shared','content','Measure use of a share control.',ARRAY['destination'],false),
  ('post.saved','content','Measure saving a Vent.',ARRAY[]::TEXT[],false),
  ('post.unsaved','content','Measure removing a saved Vent.',ARRAY[]::TEXT[],false),
  ('post.reported','content','Measure submission of a report without reason or content.',ARRAY['target_type'],true),
  ('post.reacted','engagement','Measure a non-self reaction.',ARRAY['target_type'],true),
  ('comment.created','engagement','Measure a comment without its text.',ARRAY['is_reply'],true),
  ('engagement.self_interaction_rejected','engagement','Measure server or client rejection of invalid self engagement.',ARRAY['target_type'],false),
  ('music.picker_opened','music','Measure music picker use.',ARRAY[]::TEXT[],false),
  ('music.preview_played','music','Measure licensed preview playback.',ARRAY['music_provider','duration_seconds'],false),
  ('music.attached','music','Measure licensed music attachment.',ARRAY['music_provider','is_story'],false),
  ('music.removed','music','Measure removal of an attachment.',ARRAY['is_story'],false),
  ('whisper.published','content','Measure published Whispers without title or transcript.',ARRAY['category','duration_seconds','has_music','voice_filter'],true),
  ('whisper.played','engagement','Measure Whisper playback.',ARRAY['duration_seconds'],true),
  ('whisper.liked','engagement','Measure Whisper engagement.',ARRAY[]::TEXT[],true),
  ('story.published','content','Measure Story publication.',ARRAY['has_image','has_music','story_audience'],true),
  ('story.viewed','engagement','Measure Story consumption.',ARRAY[]::TEXT[],true),
  ('story.reacted','engagement','Measure Story reaction.',ARRAY[]::TEXT[],true),
  ('friend.request_sent','social','Measure a connection request.',ARRAY[]::TEXT[],true),
  ('friend.request_accepted','social','Measure an accepted connection.',ARRAY[]::TEXT[],true),
  ('friend.request_declined','social','Measure a declined connection.',ARRAY[]::TEXT[],false),
  ('friend.blocked','social','Measure a block without either identity.',ARRAY[]::TEXT[],false),
  ('friend.unfriended','social','Measure a removed connection.',ARRAY[]::TEXT[],false),
  ('chat.message_sent','messaging','Measure a direct message without content or room id.',ARRAY['has_audio','has_image','is_reply'],true),
  ('chat.message_replied','messaging','Measure a direct reply without content.',ARRAY[]::TEXT[],true),
  ('chat.message_edited','messaging','Measure a message edit.',ARRAY[]::TEXT[],false),
  ('chat.message_deleted','messaging','Measure a message deletion.',ARRAY[]::TEXT[],false),
  ('chat.room_accepted','messaging','Measure acceptance of a chat request.',ARRAY[]::TEXT[],true),
  ('tribe.joined','social','Measure joining a community without its identifier.',ARRAY['category'],true),
  ('tribe.left','social','Measure leaving a community without its identifier.',ARRAY['category'],false),
  ('tribe.created','social','Measure creation of a community.',ARRAY['category'],true),
  ('tribe.chat_message','messaging','Measure a community message without content or community id.',ARRAY['has_audio','has_image','is_reply'],true),
  ('discover.search_performed','discovery','Measure search use without the query.',ARRAY['query_chars','target_type'],false),
  ('discover.voice_followed','discovery','Measure following a public persona.',ARRAY[]::TEXT[],false),
  ('discover.category_filtered','discovery','Measure category filter use.',ARRAY['category'],false),
  ('notification.tapped','notification','Measure notification delivery outcomes by kind.',ARRAY['category','destination'],false),
  ('billing.checkout_opened','billing','Measure checkout entry without payment data.',ARRAY['provider'],false),
  ('billing.subscription_started','billing','Measure a subscription state change.',ARRAY['provider'],false),
  ('billing.subscription_canceled','billing','Measure a subscription state change.',ARRAY['provider'],false),
  ('screen.feed','screen','Measure feed reach.',ARRAY[]::TEXT[],true),
  ('screen.discover','screen','Measure discovery reach.',ARRAY[]::TEXT[],false),
  ('screen.whispers','screen','Measure Whisper surface reach.',ARRAY[]::TEXT[],true),
  ('screen.inbox','screen','Measure messaging surface reach.',ARRAY[]::TEXT[],false),
  ('screen.friends','screen','Measure connection surface reach.',ARRAY[]::TEXT[],false),
  ('screen.profile','screen','Measure profile surface reach.',ARRAY[]::TEXT[],false),
  ('screen.compose','screen','Measure compose entry.',ARRAY[]::TEXT[],false),
  ('screen.tribe_detail','screen','Measure community surface reach.',ARRAY[]::TEXT[],true),
  ('screen.chat','screen','Measure chat surface reach.',ARRAY[]::TEXT[],false),
  ('screen.story_viewer','screen','Measure Story surface reach.',ARRAY[]::TEXT[],true)
ON CONFLICT (event_name) DO UPDATE SET
  domain = EXCLUDED.domain,
  purpose = EXCLUDED.purpose,
  allowed_properties = EXCLUDED.allowed_properties,
  impact_eligible = EXCLUDED.impact_eligible,
  updated_at = now();

-- UUID resource ids are useful in operational logs, but not in product
-- analytics. Remove the historical tribe_id exception at the server boundary.
CREATE OR REPLACE FUNCTION private.sanitize_event_props(p_props JSONB)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    pg_catalog.jsonb_object_agg(property.key, property.value),
    '{}'::JSONB
  )
    FROM pg_catalog.jsonb_each(
      CASE WHEN pg_catalog.jsonb_typeof(COALESCE(p_props, '{}'::JSONB)) = 'object'
           THEN COALESCE(p_props, '{}'::JSONB)
           ELSE '{}'::JSONB
      END
    ) AS property(key, value)
   WHERE property.key = ANY (ARRAY[
     'app_version', 'category', 'content_chars', 'destination',
     'duration_seconds', 'has_attached_post', 'has_audio', 'has_background',
     'has_image', 'has_music', 'has_note', 'has_persona', 'has_poll',
     'has_title', 'has_tribe', 'is_reply', 'is_story', 'mood',
     'music_provider', 'platform', 'provider', 'query_chars', 'state',
     'story_audience', 'target_type', 'voice_filter'
   ])
     AND pg_catalog.jsonb_typeof(property.value) IN ('boolean','number','null','string')
     AND (
       pg_catalog.jsonb_typeof(property.value) <> 'string'
       OR pg_catalog.length(property.value #>> '{}') <= 120
     );
$$;

REVOKE ALL ON FUNCTION private.sanitize_event_props(JSONB) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 3. Metric dictionary, daily aggregate fact table, and data quality ledger.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.impact_metric_definitions (
  metric_key TEXT PRIMARY KEY CHECK (metric_key ~ '^[a-z][a-z0-9_.]{2,79}$'),
  title TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 100),
  pillar TEXT NOT NULL CHECK (pillar IN (
    'reach','engagement','community','experience','wellbeing','safety','retention','impact'
  )),
  evidence_level TEXT NOT NULL CHECK (evidence_level IN (
    'platform_measurement','self_report','longitudinal','comparative','controlled','independent'
  )),
  description TEXT NOT NULL,
  formula TEXT NOT NULL,
  source TEXT NOT NULL,
  owner TEXT NOT NULL,
  cadence TEXT NOT NULL CHECK (cadence IN ('daily','weekly','monthly','on_demand')),
  aggregation_kind TEXT NOT NULL CHECK (aggregation_kind IN ('sum','ratio','latest','weighted_average')),
  privacy_classification TEXT NOT NULL CHECK (privacy_classification IN (
    'PUBLIC','INTERNAL','CONFIDENTIAL','HIGHLY_RESTRICTED','SECURITY_CRITICAL'
  )),
  retention_days INTEGER NOT NULL CHECK (retention_days BETWEEN 30 AND 3650),
  minimum_cohort INTEGER NOT NULL DEFAULT 20 CHECK (minimum_cohort BETWEEN 20 AND 1000),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','governance_gated','retired')),
  methodology_version TEXT NOT NULL DEFAULT 'impact-v1',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS private.impact_daily_metrics (
  metric_date DATE NOT NULL,
  metric_key TEXT NOT NULL REFERENCES private.impact_metric_definitions(metric_key),
  dimension_type TEXT NOT NULL DEFAULT 'overall' CHECK (dimension_type IN ('overall','country','age_band')),
  dimension_value TEXT NOT NULL DEFAULT 'all' CHECK (length(dimension_value) BETWEEN 1 AND 80),
  country_source TEXT NOT NULL DEFAULT 'none' CHECK (country_source IN ('none','declared_residence','technical_signal')),
  numerator NUMERIC,
  denominator NUMERIC,
  metric_value NUMERIC,
  sample_size INTEGER NOT NULL DEFAULT 0 CHECK (sample_size >= 0),
  suppressed BOOLEAN NOT NULL DEFAULT false,
  quality_status TEXT NOT NULL DEFAULT 'healthy' CHECK (quality_status IN ('healthy','warning','degraded','unavailable')),
  source_window_start TIMESTAMPTZ NOT NULL,
  source_window_end TIMESTAMPTZ NOT NULL,
  methodology_version TEXT NOT NULL DEFAULT 'impact-v1',
  computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (metric_date, metric_key, dimension_type, dimension_value, country_source),
  CHECK (source_window_end > source_window_start),
  CHECK (dimension_type = 'country' OR country_source = 'none'),
  CHECK (dimension_type <> 'country' OR country_source <> 'none')
);

CREATE INDEX IF NOT EXISTS impact_daily_metric_lookup_idx
  ON private.impact_daily_metrics (metric_key, dimension_type, country_source, metric_date DESC);
CREATE INDEX IF NOT EXISTS impact_daily_dimension_lookup_idx
  ON private.impact_daily_metrics (dimension_type, country_source, dimension_value, metric_date DESC);

CREATE TABLE IF NOT EXISTS private.impact_data_quality_runs (
  quality_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  as_of_date DATE NOT NULL,
  check_key TEXT NOT NULL CHECK (check_key ~ '^[a-z][a-z0-9_.]{2,79}$'),
  status TEXT NOT NULL CHECK (status IN ('healthy','warning','degraded','unavailable')),
  observed_value NUMERIC,
  threshold NUMERIC,
  detail TEXT NOT NULL CHECK (length(detail) BETWEEN 3 AND 500),
  checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (as_of_date, check_key)
);

CREATE INDEX IF NOT EXISTS impact_quality_latest_idx
  ON private.impact_data_quality_runs (as_of_date DESC, status, check_key);

REVOKE ALL ON TABLE private.impact_metric_definitions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.impact_daily_metrics FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.impact_data_quality_runs FROM PUBLIC, anon, authenticated;

INSERT INTO private.impact_metric_definitions
  (metric_key,title,pillar,evidence_level,description,formula,source,owner,cadence,aggregation_kind,privacy_classification,retention_days,minimum_cohort,status)
VALUES
  ('reach.registered_users','New accounts','reach','platform_measurement','Accounts created in the measurement window. This is reach, not evidence of benefit.','count(users created in window)','users.created_at','Growth & Data','daily','sum','INTERNAL',1095,20,'active'),
  ('reach.active_users','Active person-days','reach','platform_measurement','Sum of daily distinct people who performed a meaningful platform action. A person active on multiple days is counted once per active day; this is not a cross-window unique-person count.','sum(daily count(distinct actor across canonical activity tables))','posts, comments, reactions, messages, whispers','Product Analytics','daily','sum','INTERNAL',1095,20,'active'),
  ('engagement.vents_created','Vents created','engagement','platform_measurement','Published non-Story Vents, excluding deleted content.','count(posts where is_story is not true and deleted_at is null)','posts','Product Analytics','daily','sum','INTERNAL',1095,20,'active'),
  ('engagement.comments_created','Comments created','engagement','platform_measurement','Comments published, excluding deleted comments.','count(posts_comments where deleted_at is null)','posts_comments','Product Analytics','daily','sum','INTERNAL',1095,20,'active'),
  ('engagement.reactions_created','Reactions created','engagement','platform_measurement','Valid reaction rows created.','count(post_likes)','post_likes','Product Analytics','daily','sum','INTERNAL',1095,20,'active'),
  ('community.support_response_rate','Support response rate','community','platform_measurement','Share of Vents receiving a non-author comment within 24 hours. A response is not assumed to be positive support.','100 × vents with a non-author comment within 24h / eligible vents','posts + posts_comments','Community Health','daily','ratio','CONFIDENTIAL',1095,20,'active'),
  ('community.time_to_first_support','Time to first response','community','platform_measurement','Median minutes to the first non-author comment within seven days. Response quality is not inferred.','daily median(first qualifying comment time - vent creation time)','posts + posts_comments','Community Health','daily','latest','CONFIDENTIAL',1095,20,'active'),
  ('community.unanswered_expression_rate','Unanswered expression rate','community','platform_measurement','Share of eligible Vents without a non-author comment after 24 hours.','100 × eligible vents without response / eligible vents','posts + posts_comments','Community Health','daily','ratio','CONFIDENTIAL',1095,20,'active'),
  ('community.support_participants','Support participant-days','community','platform_measurement','Sum of daily distinct people who commented on another person’s Vent. A person active on multiple days is counted once per day. This is participation, not proof of support quality.','sum(daily count(distinct non-author commenters))','posts + posts_comments','Community Health','daily','sum','INTERNAL',1095,20,'active'),
  ('safety.reports_received','Reports received','safety','platform_measurement','User reports submitted in the window.','count(reports)','reports','Trust & Safety','daily','sum','CONFIDENTIAL',1095,20,'active'),
  ('safety.crisis_content_flagged','Crisis signals','safety','platform_measurement','Content items classified with an elevated or high crisis signal. This is not a diagnosis.','count(flagged posts and whispers)','posts + whispers','Trust & Safety','daily','sum','HIGHLY_RESTRICTED',1095,20,'active'),
  ('safety.case_resolution_rate','Case resolution rate','safety','platform_measurement','Share of moderation cases opened that day that have a decision.','100 × decided cases / cases opened','moderation_cases','Trust & Safety','daily','ratio','CONFIDENTIAL',1095,20,'active'),
  ('retention.day_7','Day-7 retained','retention','platform_measurement','Share of a signup cohort active during days 7–13 after signup.','100 × cohort active on days 7–13 / signup cohort','users + canonical activity tables','Product Analytics','daily','ratio','CONFIDENTIAL',1095,20,'active'),
  ('experience.feeling_heard','Feeling heard','experience','self_report','Opt-in participant-reported feeling-heard measure. Collection is disabled until protocol and consent review complete.','approved survey scoring protocol','Impact Program aggregate','Research & Impact','on_demand','weighted_average','HIGHLY_RESTRICTED',730,30,'governance_gated'),
  ('wellbeing.connection_score','Connection score','wellbeing','self_report','Opt-in participant-reported connection measure. Not a clinical diagnosis.','approved survey scoring protocol','Impact Program aggregate','Research & Impact','on_demand','weighted_average','HIGHLY_RESTRICTED',730,30,'governance_gated'),
  ('wellbeing.who5','WHO-5 well-being score','wellbeing','self_report','Potential future validated well-being measure. Disabled pending licensing, ethics, legal, cultural, and safety review.','not active','Impact Program aggregate','Research & Impact','on_demand','weighted_average','HIGHLY_RESTRICTED',730,50,'governance_gated'),
  ('impact.observed_positive_outcome','Observed positive outcome','impact','longitudinal','Opt-in longitudinal outcome measure. No causal claim is permitted from observational data.','approved longitudinal protocol','Impact Program aggregate','Research & Impact','monthly','ratio','HIGHLY_RESTRICTED',730,50,'governance_gated')
ON CONFLICT (metric_key) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  formula = EXCLUDED.formula,
  source = EXCLUDED.source,
  owner = EXCLUDED.owner,
  minimum_cohort = EXCLUDED.minimum_cohort,
  status = EXCLUDED.status,
  updated_at = now();

-- -------------------------------------------------------------------------
-- 4. Optional Impact Program governance. No assessment/health-response table
--    is created in phase 1: collection remains technically impossible until
--    a reviewed protocol adds the narrowly necessary schema and user flow.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.impact_programs (
  program_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 3 AND 120),
  protocol_version TEXT NOT NULL CHECK (length(protocol_version) BETWEEN 1 AND 40),
  consent_version TEXT NOT NULL CHECK (length(consent_version) BETWEEN 1 AND 40),
  purpose TEXT NOT NULL CHECK (length(purpose) BETWEEN 20 AND 2000),
  countries TEXT[] NOT NULL DEFAULT '{}',
  minimum_age SMALLINT NOT NULL DEFAULT 18 CHECK (minimum_age BETWEEN 13 AND 100),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','legal_review','ethics_review','pilot','active','paused','closed')),
  dpia_reference TEXT,
  ethics_reference TEXT,
  approved_at TIMESTAMPTZ,
  approved_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  created_by UUID NOT NULL REFERENCES public.users(user_id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status NOT IN ('pilot','active') OR (dpia_reference IS NOT NULL AND ethics_reference IS NOT NULL AND approved_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS private.impact_participants (
  participant_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id UUID NOT NULL REFERENCES private.impact_programs(program_id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'enrolled' CHECK (status IN ('enrolled','withdrawn','erasure_pending','erased')),
  enrolled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  withdrawn_at TIMESTAMPTZ,
  erasure_due_at TIMESTAMPTZ,
  UNIQUE (program_id, user_id),
  CHECK ((status = 'enrolled' AND withdrawn_at IS NULL) OR status <> 'enrolled')
);

CREATE TABLE IF NOT EXISTS private.impact_consent_receipts (
  receipt_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id UUID NOT NULL REFERENCES private.impact_participants(participant_id) ON DELETE CASCADE,
  consent_kind TEXT NOT NULL CHECK (consent_kind IN ('research_participation','follow_up','academic_sharing','human_story')),
  consent_version TEXT NOT NULL CHECK (length(consent_version) BETWEEN 1 AND 40),
  granted BOOLEAN NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('app','web','assisted','withdrawal')),
  receipt_hash TEXT NOT NULL CHECK (length(receipt_hash) BETWEEN 32 AND 128),
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS impact_consent_participant_idx
  ON private.impact_consent_receipts (participant_id, consent_kind, recorded_at DESC);

REVOKE ALL ON TABLE private.impact_programs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.impact_participants FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.impact_consent_receipts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.block_append_only_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'append_only_record';
END;
$$;

DROP TRIGGER IF EXISTS impact_consent_append_only ON private.impact_consent_receipts;
CREATE TRIGGER impact_consent_append_only
BEFORE UPDATE OR DELETE ON private.impact_consent_receipts
FOR EACH ROW EXECUTE FUNCTION private.block_append_only_change();

-- -------------------------------------------------------------------------
-- 5. Immutable report snapshots.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.impact_report_snapshots (
  report_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_kind TEXT NOT NULL CHECK (report_kind IN ('monthly_impact','community_health','safety_transparency','country_summary','research_readiness')),
  title TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 160),
  audience TEXT NOT NULL CHECK (audience IN ('internal','external')),
  window_start DATE NOT NULL,
  window_end DATE NOT NULL,
  country_source TEXT NOT NULL DEFAULT 'none' CHECK (country_source IN ('none','declared_residence','technical_signal')),
  country_filter TEXT,
  status TEXT NOT NULL DEFAULT 'generated' CHECK (status IN ('generated','published','withdrawn')),
  methodology_version TEXT NOT NULL DEFAULT 'impact-v1',
  minimum_cohort INTEGER NOT NULL DEFAULT 20 CHECK (minimum_cohort BETWEEN 20 AND 1000),
  generated_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at TIMESTAMPTZ,
  withdrawn_at TIMESTAMPTZ,
  checksum TEXT,
  notes TEXT CHECK (notes IS NULL OR length(notes) <= 1000),
  CHECK (window_end >= window_start),
  CHECK (window_end - window_start <= 366),
  CHECK ((country_source = 'none' AND country_filter IS NULL) OR country_source <> 'none')
);

CREATE TABLE IF NOT EXISTS private.impact_report_values (
  report_id UUID NOT NULL REFERENCES private.impact_report_snapshots(report_id) ON DELETE RESTRICT,
  ordinal INTEGER NOT NULL CHECK (ordinal > 0),
  metric_key TEXT NOT NULL,
  title TEXT NOT NULL,
  pillar TEXT NOT NULL,
  metric_value NUMERIC,
  previous_value NUMERIC,
  percent_change NUMERIC,
  numerator NUMERIC,
  denominator NUMERIC,
  sample_size BIGINT NOT NULL DEFAULT 0,
  suppressed BOOLEAN NOT NULL DEFAULT false,
  quality_status TEXT NOT NULL,
  definition TEXT NOT NULL,
  formula TEXT NOT NULL,
  source TEXT NOT NULL,
  methodology_version TEXT NOT NULL,
  PRIMARY KEY (report_id, ordinal),
  UNIQUE (report_id, metric_key)
);

CREATE INDEX IF NOT EXISTS impact_reports_generated_idx
  ON private.impact_report_snapshots (generated_at DESC, report_kind, status);

REVOKE ALL ON TABLE private.impact_report_snapshots FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.impact_report_values FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS impact_report_values_append_only ON private.impact_report_values;
CREATE TRIGGER impact_report_values_append_only
BEFORE UPDATE OR DELETE ON private.impact_report_values
FOR EACH ROW EXECUTE FUNCTION private.block_append_only_change();

CREATE OR REPLACE FUNCTION private.protect_impact_report_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_report_snapshot'; END IF;
  IF NEW.report_kind IS DISTINCT FROM OLD.report_kind
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.audience IS DISTINCT FROM OLD.audience
     OR NEW.window_start IS DISTINCT FROM OLD.window_start
     OR NEW.window_end IS DISTINCT FROM OLD.window_end
     OR NEW.country_source IS DISTINCT FROM OLD.country_source
     OR NEW.country_filter IS DISTINCT FROM OLD.country_filter
     OR NEW.methodology_version IS DISTINCT FROM OLD.methodology_version
     OR NEW.minimum_cohort IS DISTINCT FROM OLD.minimum_cohort
     OR NEW.generated_by IS DISTINCT FROM OLD.generated_by
     OR NEW.generated_at IS DISTINCT FROM OLD.generated_at
     OR (OLD.checksum IS NOT NULL AND NEW.checksum IS DISTINCT FROM OLD.checksum) THEN
    RAISE EXCEPTION 'immutable_report_snapshot';
  END IF;
  IF OLD.status = 'withdrawn' OR (OLD.status = 'published' AND NEW.status = 'generated') THEN
    RAISE EXCEPTION 'invalid_report_status_transition';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS impact_report_snapshot_immutable ON private.impact_report_snapshots;
CREATE TRIGGER impact_report_snapshot_immutable
BEFORE UPDATE OR DELETE ON private.impact_report_snapshots
FOR EACH ROW EXECUTE FUNCTION private.protect_impact_report_snapshot();

-- -------------------------------------------------------------------------
-- 6. Idempotent daily aggregation. Content bodies, message text, titles,
--    device ids, and exact locations are never selected into this layer.
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.refresh_impact_daily(p_date DATE DEFAULT current_date - 1)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_start TIMESTAMPTZ := p_date::TIMESTAMPTZ;
  v_end TIMESTAMPTZ := (p_date + 1)::TIMESTAMPTZ;
  v_min INTEGER := 20;
BEGIN
  IF p_date IS NULL OR p_date > current_date OR p_date < current_date - 730 THEN
    RAISE EXCEPTION 'invalid_impact_date' USING ERRCODE = '22023';
  END IF;

  DELETE FROM private.impact_daily_metrics WHERE metric_date = p_date;

  WITH activity AS (
    SELECT author_id AS user_id, created_at FROM public.posts
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT author_id, created_at FROM public.posts_comments
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT user_id, created_at FROM public.post_likes
     WHERE user_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT sender_id, created_at FROM public.tribe_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT sender_id, created_at FROM public.chat_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT author_id, created_at FROM public.whispers
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
  ),
  day_activity AS (
    SELECT DISTINCT user_id FROM activity WHERE created_at >= v_start AND created_at < v_end
  ),
  daily AS (
    SELECT 'reach.registered_users'::TEXT metric_key,
           count(*)::NUMERIC value, NULL::NUMERIC numerator, NULL::NUMERIC denominator,
           count(*)::INTEGER sample_size, 'healthy'::TEXT quality_status
      FROM public.users WHERE created_at >= v_start AND created_at < v_end
    UNION ALL
    SELECT 'reach.active_users', count(*)::NUMERIC, NULL, NULL, count(*)::INTEGER, 'healthy'
      FROM day_activity
    UNION ALL
    SELECT 'engagement.vents_created', count(*)::NUMERIC, NULL, NULL, count(*)::INTEGER, 'healthy'
      FROM public.posts WHERE created_at >= v_start AND created_at < v_end AND deleted_at IS NULL AND COALESCE(is_story,false)=false
    UNION ALL
    SELECT 'engagement.comments_created', count(*)::NUMERIC, NULL, NULL, count(*)::INTEGER, 'healthy'
      FROM public.posts_comments WHERE created_at >= v_start AND created_at < v_end AND deleted_at IS NULL
    UNION ALL
    SELECT 'engagement.reactions_created', count(*)::NUMERIC, NULL, NULL, count(*)::INTEGER, 'healthy'
      FROM public.post_likes WHERE created_at >= v_start AND created_at < v_end
    UNION ALL
    SELECT 'community.support_participants', count(DISTINCT c.author_id)::NUMERIC, NULL, NULL,
           count(DISTINCT c.author_id)::INTEGER, 'healthy'
      FROM public.posts_comments c JOIN public.posts p ON p.post_id=c.post_id
     WHERE c.created_at >= v_start AND c.created_at < v_end AND c.deleted_at IS NULL AND c.author_id <> p.author_id
    UNION ALL
    SELECT 'safety.reports_received', count(*)::NUMERIC, NULL, NULL, count(*)::INTEGER, 'healthy'
      FROM public.reports WHERE created_at >= v_start AND created_at < v_end
    UNION ALL
    SELECT 'safety.crisis_content_flagged', count(*)::NUMERIC, NULL, NULL, count(*)::INTEGER, 'healthy'
      FROM (
        SELECT post_id FROM public.posts WHERE created_at >= v_start AND created_at < v_end AND crisis_level IS NOT NULL
        UNION ALL
        SELECT whisper_id FROM public.whispers WHERE created_at >= v_start AND created_at < v_end AND crisis_level IS NOT NULL
      ) flagged
  )
  INSERT INTO private.impact_daily_metrics
    (metric_date,metric_key,numerator,denominator,metric_value,sample_size,suppressed,quality_status,source_window_start,source_window_end)
  SELECT p_date, metric_key, numerator, denominator, value, sample_size,
         sample_size BETWEEN 1 AND v_min - 1, quality_status, v_start, v_end
    FROM daily;

  WITH eligible AS (
    SELECT p.post_id, p.author_id, p.created_at,
           min(c.created_at) FILTER (WHERE c.author_id <> p.author_id AND c.deleted_at IS NULL) AS first_response
      FROM public.posts p
      LEFT JOIN public.posts_comments c
        ON c.post_id=p.post_id AND c.created_at >= p.created_at AND c.created_at < p.created_at + interval '7 days'
     WHERE p.created_at >= v_start AND p.created_at < v_end
       AND p.deleted_at IS NULL AND COALESCE(p.is_story,false)=false
     GROUP BY p.post_id,p.author_id,p.created_at
  ), stats AS (
    SELECT count(*)::NUMERIC AS denominator,
           count(*) FILTER (WHERE first_response < created_at + interval '24 hours')::NUMERIC AS responded,
           count(*) FILTER (WHERE first_response IS NULL OR first_response >= created_at + interval '24 hours')::NUMERIC AS unanswered,
           percentile_disc(0.5) WITHIN GROUP (
             ORDER BY extract(epoch FROM (first_response-created_at))/60
           ) FILTER (WHERE first_response IS NOT NULL) AS median_minutes
      FROM eligible
  )
  INSERT INTO private.impact_daily_metrics
    (metric_date,metric_key,numerator,denominator,metric_value,sample_size,suppressed,quality_status,source_window_start,source_window_end)
  SELECT p_date, metric.metric_key, metric.numerator, metric.denominator, metric.metric_value,
         stats.denominator::INTEGER, stats.denominator BETWEEN 1 AND v_min - 1,
         CASE WHEN p_date >= current_date THEN 'warning' ELSE 'healthy' END,
         v_start, v_end
    FROM stats
    CROSS JOIN LATERAL (
      VALUES
        ('community.support_response_rate'::TEXT, responded, denominator,
          CASE WHEN denominator > 0 THEN round(100*responded/denominator,2) END),
        ('community.unanswered_expression_rate'::TEXT, unanswered, denominator,
          CASE WHEN denominator > 0 THEN round(100*unanswered/denominator,2) END),
        ('community.time_to_first_support'::TEXT, NULL::NUMERIC, NULL::NUMERIC, median_minutes)
    ) metric(metric_key,numerator,denominator,metric_value);

  WITH cases AS (
    SELECT count(*)::NUMERIC denominator,
           count(*) FILTER (WHERE decided_at IS NOT NULL)::NUMERIC numerator
      FROM public.moderation_cases WHERE opened_at >= v_start AND opened_at < v_end
  )
  INSERT INTO private.impact_daily_metrics
    (metric_date,metric_key,numerator,denominator,metric_value,sample_size,suppressed,quality_status,source_window_start,source_window_end)
  SELECT p_date,'safety.case_resolution_rate',numerator,denominator,
         CASE WHEN denominator > 0 THEN round(100*numerator/denominator,2) END,
         denominator::INTEGER, denominator BETWEEN 1 AND v_min - 1,
         CASE WHEN p_date >= current_date THEN 'warning' ELSE 'healthy' END,
         v_start,v_end FROM cases;

  WITH activity AS (
    SELECT author_id AS user_id, created_at FROM public.posts
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start + interval '7 days' AND created_at < v_start + interval '14 days'
    UNION ALL SELECT author_id, created_at FROM public.posts_comments
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start + interval '7 days' AND created_at < v_start + interval '14 days'
    UNION ALL SELECT user_id, created_at FROM public.post_likes
     WHERE user_id IS NOT NULL AND created_at >= v_start + interval '7 days' AND created_at < v_start + interval '14 days'
    UNION ALL SELECT sender_id, created_at FROM public.tribe_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start + interval '7 days' AND created_at < v_start + interval '14 days'
    UNION ALL SELECT sender_id, created_at FROM public.chat_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start + interval '7 days' AND created_at < v_start + interval '14 days'
    UNION ALL SELECT author_id, created_at FROM public.whispers
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start + interval '7 days' AND created_at < v_start + interval '14 days'
  ), cohort AS (
    SELECT user_id FROM public.users WHERE created_at >= v_start AND created_at < v_end
  ), retention AS (
    SELECT count(*)::NUMERIC denominator,
           count(*) FILTER (WHERE EXISTS (
             SELECT 1 FROM activity a WHERE a.user_id=cohort.user_id
              AND a.created_at >= v_start + interval '7 days'
              AND a.created_at < v_start + interval '14 days'
           ))::NUMERIC numerator
      FROM cohort
  )
  INSERT INTO private.impact_daily_metrics
    (metric_date,metric_key,numerator,denominator,metric_value,sample_size,suppressed,quality_status,source_window_start,source_window_end)
  SELECT p_date,'retention.day_7',numerator,denominator,
         CASE WHEN denominator > 0 THEN round(100*numerator/denominator,2) END,
         denominator::INTEGER, denominator BETWEEN 1 AND v_min - 1,
         CASE WHEN p_date > current_date-14 THEN 'warning' ELSE 'healthy' END,
         v_start,v_end FROM retention;

  -- Geography remains source-specific. Never fall back from technical country
  -- to declared residence or present either as citizenship/current residence.
  WITH activity AS (
    SELECT author_id AS user_id, created_at FROM public.posts
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT author_id, created_at FROM public.posts_comments
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT user_id, created_at FROM public.post_likes
     WHERE user_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT sender_id, created_at FROM public.tribe_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT sender_id, created_at FROM public.chat_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT author_id, created_at FROM public.whispers
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
  ), active AS (
    SELECT DISTINCT user_id FROM activity WHERE created_at >= v_start AND created_at < v_end
  ), countries AS (
    SELECT 'declared_residence'::TEXT source, upper(u.home_country) value, count(*)::INTEGER n
      FROM active a JOIN public.users u ON u.user_id=a.user_id
     WHERE u.home_country IS NOT NULL AND btrim(u.home_country) <> ''
     GROUP BY upper(u.home_country)
    UNION ALL
    SELECT 'technical_signal', upper(u.last_country), count(*)::INTEGER
      FROM active a JOIN public.users u ON u.user_id=a.user_id
     WHERE u.last_country IS NOT NULL AND btrim(u.last_country) <> ''
     GROUP BY upper(u.last_country)
  )
  INSERT INTO private.impact_daily_metrics
    (metric_date,metric_key,dimension_type,dimension_value,country_source,metric_value,sample_size,suppressed,quality_status,source_window_start,source_window_end)
  SELECT p_date,'reach.active_users','country',left(value,80),source,n,n,
         n BETWEEN 1 AND v_min-1,'healthy',v_start,v_end
    FROM countries;

  WITH activity AS (
    SELECT author_id AS user_id, created_at FROM public.posts
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT author_id, created_at FROM public.posts_comments
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT user_id, created_at FROM public.post_likes
     WHERE user_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT sender_id, created_at FROM public.tribe_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT sender_id, created_at FROM public.chat_messages
     WHERE sender_id IS NOT NULL AND created_at >= v_start AND created_at < v_end
    UNION ALL SELECT author_id, created_at FROM public.whispers
     WHERE author_id IS NOT NULL AND deleted_at IS NULL AND created_at >= v_start AND created_at < v_end
  ), active AS (
    SELECT DISTINCT user_id FROM activity WHERE created_at >= v_start AND created_at < v_end
  ), bands AS (
    SELECT CASE
      WHEN extract(year FROM age(make_date(u.birth_year,COALESCE(u.birth_month,7),1))) < 18 THEN 'under_18'
      WHEN extract(year FROM age(make_date(u.birth_year,COALESCE(u.birth_month,7),1))) < 25 THEN '18_24'
      WHEN extract(year FROM age(make_date(u.birth_year,COALESCE(u.birth_month,7),1))) < 35 THEN '25_34'
      WHEN extract(year FROM age(make_date(u.birth_year,COALESCE(u.birth_month,7),1))) < 45 THEN '35_44'
      ELSE '45_plus' END AS value,
      count(*)::INTEGER n
      FROM active a JOIN public.users u ON u.user_id=a.user_id
     WHERE u.birth_year IS NOT NULL
     GROUP BY 1
  )
  INSERT INTO private.impact_daily_metrics
    (metric_date,metric_key,dimension_type,dimension_value,country_source,metric_value,sample_size,suppressed,quality_status,source_window_start,source_window_end)
  SELECT p_date,'reach.active_users','age_band',value,'none',n,n,
         n BETWEEN 1 AND v_min-1,'healthy',v_start,v_end
    FROM bands;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_impact_daily(DATE) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.refresh_impact_daily(DATE) TO service_role;

CREATE OR REPLACE FUNCTION private.run_impact_data_quality(p_date DATE DEFAULT current_date)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_unknown NUMERIC;
  v_stale NUMERIC;
  v_future NUMERIC;
  v_country_missing NUMERIC;
  v_counter_errors NUMERIC;
BEGIN
  SELECT count(*) INTO v_unknown
    FROM public.app_events e
   WHERE e.created_at >= now()-interval '24 hours'
     AND NOT EXISTS (SELECT 1 FROM private.impact_event_taxonomy t WHERE t.event_name=e.name AND t.status='active');
  SELECT extract(epoch FROM (now()-max(computed_at)))/3600 INTO v_stale FROM private.impact_daily_metrics;
  SELECT count(*) INTO v_future FROM (
    SELECT created_at FROM public.users WHERE created_at > now()+interval '5 minutes'
    UNION ALL SELECT created_at FROM public.posts WHERE created_at > now()+interval '5 minutes'
    UNION ALL SELECT created_at FROM public.posts_comments WHERE created_at > now()+interval '5 minutes'
  ) impossible;
  SELECT count(*) INTO v_country_missing FROM public.users
   WHERE (home_country IS NULL OR btrim(home_country)='') AND (last_country IS NULL OR btrim(last_country)='');
  SELECT count(*) INTO v_counter_errors
    FROM public.posts p
   WHERE p.created_at >= now()-interval '30 days'
     AND (p.likes_count <> (SELECT count(*) FROM public.post_likes l WHERE l.post_id=p.post_id)
       OR p.comments_count <> (SELECT count(*) FROM public.posts_comments c WHERE c.post_id=p.post_id AND c.deleted_at IS NULL));

  INSERT INTO private.impact_data_quality_runs(as_of_date,check_key,status,observed_value,threshold,detail)
  VALUES
    (p_date,'events.unknown_taxonomy',CASE WHEN v_unknown=0 THEN 'healthy' WHEN v_unknown<10 THEN 'warning' ELSE 'degraded' END,v_unknown,0,'Unregistered event names received in the last 24 hours.'),
    (p_date,'aggregates.freshness',CASE WHEN v_stale IS NULL THEN 'unavailable' WHEN v_stale<=36 THEN 'healthy' WHEN v_stale<=60 THEN 'warning' ELSE 'degraded' END,v_stale,36,'Hours since the latest aggregate computation.'),
    (p_date,'timestamps.future_rows',CASE WHEN v_future=0 THEN 'healthy' ELSE 'degraded' END,v_future,0,'Canonical rows more than five minutes in the future.'),
    (p_date,'geography.missing_source',CASE WHEN v_country_missing=0 THEN 'healthy' ELSE 'warning' END,v_country_missing,0,'Accounts with neither declared residence nor coarse technical country. Missing is not silently imputed.'),
    (p_date,'counters.post_mismatch',CASE WHEN v_counter_errors=0 THEN 'healthy' WHEN v_counter_errors<5 THEN 'warning' ELSE 'degraded' END,v_counter_errors,0,'Recent Vent counters that disagree with canonical rows.')
  ON CONFLICT (as_of_date,check_key) DO UPDATE SET
    status=EXCLUDED.status, observed_value=EXCLUDED.observed_value,
    threshold=EXCLUDED.threshold, detail=EXCLUDED.detail, checked_at=now();
END;
$$;

REVOKE ALL ON FUNCTION private.run_impact_data_quality(DATE) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.run_impact_data_quality(DATE) TO service_role;

-- -------------------------------------------------------------------------
-- 7. Aggregate-only admin APIs. These functions never return user ids, raw
--    content, event properties, assessment answers, or low-volume geography.
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_impact_metrics(
  p_start DATE DEFAULT current_date-29,
  p_end DATE DEFAULT current_date,
  p_dimension_type TEXT DEFAULT 'overall',
  p_dimension_value TEXT DEFAULT 'all',
  p_country_source TEXT DEFAULT 'none'
) RETURNS TABLE (
  metric_key TEXT, title TEXT, pillar TEXT, evidence_level TEXT,
  description TEXT, formula TEXT, source TEXT, owner TEXT,
  metric_value NUMERIC, previous_value NUMERIC, percent_change NUMERIC,
  numerator NUMERIC, denominator NUMERIC, sample_size BIGINT,
  suppressed BOOLEAN, quality_status TEXT, status TEXT,
  minimum_cohort INTEGER, methodology_version TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end < p_start OR p_end-p_start > 366 THEN
    RAISE EXCEPTION 'invalid_date_range' USING ERRCODE='22023';
  END IF;
  IF p_dimension_type NOT IN ('overall','country','age_band')
     OR p_country_source NOT IN ('none','declared_residence','technical_signal') THEN
    RAISE EXCEPTION 'invalid_dimension' USING ERRCODE='22023';
  END IF;

  RETURN QUERY
  WITH bounds AS (
    SELECT (p_end-p_start+1) AS days,
           (p_start-(p_end-p_start+1))::DATE AS previous_start,
           (p_start-1)::DATE AS previous_end
  ), current_rows AS (
    SELECT m.*, d.aggregation_kind, d.minimum_cohort
      FROM private.impact_daily_metrics m
      JOIN private.impact_metric_definitions d USING(metric_key)
     WHERE m.metric_date BETWEEN p_start AND p_end
       AND m.dimension_type=p_dimension_type
       AND m.dimension_value=p_dimension_value
       AND m.country_source=p_country_source
  ), previous_rows AS (
    SELECT m.*, d.aggregation_kind
      FROM private.impact_daily_metrics m
      JOIN private.impact_metric_definitions d USING(metric_key), bounds b
     WHERE m.metric_date BETWEEN b.previous_start AND b.previous_end
       AND m.dimension_type=p_dimension_type
       AND m.dimension_value=p_dimension_value
       AND m.country_source=p_country_source
  ), current_agg AS (
    SELECT cr.metric_key,
      CASE cr.aggregation_kind
        WHEN 'sum' THEN sum(cr.metric_value)
        WHEN 'ratio' THEN CASE WHEN sum(cr.denominator)>0 THEN round(100*sum(cr.numerator)/sum(cr.denominator),2) END
        WHEN 'weighted_average' THEN CASE WHEN sum(cr.sample_size)>0 THEN round(sum(cr.metric_value*cr.sample_size)/sum(cr.sample_size),2) END
        ELSE (array_agg(cr.metric_value ORDER BY cr.metric_date DESC))[1]
      END value,
      sum(cr.numerator) numerator, sum(cr.denominator) denominator, sum(cr.sample_size)::BIGINT sample_size,
      bool_or(cr.suppressed) has_suppressed,
      CASE WHEN bool_or(cr.quality_status='degraded') THEN 'degraded'
           WHEN bool_or(cr.quality_status='warning') THEN 'warning'
           WHEN bool_or(cr.quality_status='unavailable') THEN 'unavailable'
           ELSE 'healthy' END quality_status
    FROM current_rows cr GROUP BY cr.metric_key,cr.aggregation_kind
  ), previous_agg AS (
    SELECT pr.metric_key,
      CASE pr.aggregation_kind
        WHEN 'sum' THEN sum(pr.metric_value)
        WHEN 'ratio' THEN CASE WHEN sum(pr.denominator)>0 THEN round(100*sum(pr.numerator)/sum(pr.denominator),2) END
        WHEN 'weighted_average' THEN CASE WHEN sum(pr.sample_size)>0 THEN round(sum(pr.metric_value*pr.sample_size)/sum(pr.sample_size),2) END
        ELSE (array_agg(pr.metric_value ORDER BY pr.metric_date DESC))[1]
      END value,
      bool_or(pr.suppressed) has_suppressed
    FROM previous_rows pr GROUP BY pr.metric_key,pr.aggregation_kind
  )
  SELECT d.metric_key,d.title,d.pillar,d.evidence_level,d.description,d.formula,d.source,d.owner,
         CASE WHEN NOT COALESCE(c.has_suppressed,false) AND (COALESCE(c.sample_size,0) >= d.minimum_cohort OR COALESCE(c.sample_size,0)=0) THEN c.value END,
         CASE WHEN NOT COALESCE(c.has_suppressed,false) AND NOT COALESCE(p.has_suppressed,false)
                    AND p.value IS NOT NULL AND (COALESCE(c.sample_size,0)>=d.minimum_cohort OR COALESCE(c.sample_size,0)=0) THEN p.value END,
         CASE WHEN NOT COALESCE(c.has_suppressed,false) AND NOT COALESCE(p.has_suppressed,false)
                    AND p.value IS NOT NULL AND p.value<>0 AND (COALESCE(c.sample_size,0)>=d.minimum_cohort OR COALESCE(c.sample_size,0)=0)
              THEN round(100*(c.value-p.value)/abs(p.value),2) END,
         CASE WHEN NOT COALESCE(c.has_suppressed,false) AND (COALESCE(c.sample_size,0)>=d.minimum_cohort OR COALESCE(c.sample_size,0)=0) THEN c.numerator END,
         CASE WHEN NOT COALESCE(c.has_suppressed,false) AND (COALESCE(c.sample_size,0)>=d.minimum_cohort OR COALESCE(c.sample_size,0)=0) THEN c.denominator END,
         COALESCE(c.sample_size,0),
         (COALESCE(c.has_suppressed,false) OR COALESCE(c.sample_size,0) BETWEEN 1 AND d.minimum_cohort-1),
         COALESCE(c.quality_status,'unavailable'),d.status,d.minimum_cohort,d.methodology_version
    FROM private.impact_metric_definitions d
    LEFT JOIN current_agg c ON c.metric_key=d.metric_key
    LEFT JOIN previous_agg p ON p.metric_key=d.metric_key
   ORDER BY array_position(ARRAY['reach','engagement','community','experience','wellbeing','safety','retention','impact'],d.pillar),d.metric_key;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_impact_dimensions(
  p_start DATE DEFAULT current_date-29,
  p_end DATE DEFAULT current_date,
  p_dimension_type TEXT DEFAULT 'country',
  p_country_source TEXT DEFAULT 'declared_residence'
) RETURNS TABLE (dimension_value TEXT, metric_value NUMERIC, sample_size BIGINT, quality_status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  IF p_end<p_start OR p_end-p_start>366 OR p_dimension_type NOT IN ('country','age_band') THEN
    RAISE EXCEPTION 'invalid_dimension_range' USING ERRCODE='22023';
  END IF;
  RETURN QUERY
  SELECT m.dimension_value,sum(m.metric_value),sum(m.sample_size)::BIGINT,
         CASE WHEN bool_or(m.quality_status='degraded') THEN 'degraded'
              WHEN bool_or(m.quality_status='warning') THEN 'warning' ELSE 'healthy' END
    FROM private.impact_daily_metrics m
   WHERE m.metric_key='reach.active_users'
     AND m.metric_date BETWEEN p_start AND p_end
     AND m.dimension_type=p_dimension_type
     AND m.country_source=CASE WHEN p_dimension_type='age_band' THEN 'none' ELSE p_country_source END
     AND NOT m.suppressed
   GROUP BY m.dimension_value
  HAVING sum(m.sample_size) >= 20
   ORDER BY sum(m.metric_value) DESC,m.dimension_value;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_impact_methodology()
RETURNS TABLE (
  metric_key TEXT,title TEXT,pillar TEXT,evidence_level TEXT,description TEXT,
  formula TEXT,source TEXT,owner TEXT,cadence TEXT,privacy_classification TEXT,
  retention_days INTEGER,minimum_cohort INTEGER,status TEXT,methodology_version TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  RETURN QUERY SELECT d.metric_key,d.title,d.pillar,d.evidence_level,d.description,d.formula,d.source,d.owner,d.cadence,
    d.privacy_classification,d.retention_days,d.minimum_cohort,d.status,d.methodology_version
    FROM private.impact_metric_definitions d ORDER BY d.pillar,d.metric_key;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_impact_data_quality()
RETURNS TABLE (as_of_date DATE,check_key TEXT,status TEXT,observed_value NUMERIC,threshold NUMERIC,detail TEXT,checked_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  RETURN QUERY SELECT q.as_of_date,q.check_key,q.status,q.observed_value,q.threshold,q.detail,q.checked_at
    FROM private.impact_data_quality_runs q
   WHERE q.as_of_date=(SELECT max(q2.as_of_date) FROM private.impact_data_quality_runs q2)
   ORDER BY q.status DESC,q.check_key;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_impact_reports(p_limit INTEGER DEFAULT 50)
RETURNS TABLE (
  report_id UUID,report_kind TEXT,title TEXT,audience TEXT,window_start DATE,window_end DATE,
  country_source TEXT,country_filter TEXT,status TEXT,methodology_version TEXT,
  minimum_cohort INTEGER,generated_at TIMESTAMPTZ,published_at TIMESTAMPTZ,checksum TEXT,metric_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  RETURN QUERY SELECT r.report_id,r.report_kind,r.title,r.audience,r.window_start,r.window_end,r.country_source,r.country_filter,
    r.status,r.methodology_version,r.minimum_cohort,r.generated_at,r.published_at,r.checksum,
    (SELECT count(*)::INTEGER FROM private.impact_report_values v WHERE v.report_id=r.report_id)
    FROM private.impact_report_snapshots r ORDER BY r.generated_at DESC LIMIT greatest(1,least(p_limit,100));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_impact_report_values(p_report UUID)
RETURNS TABLE (
  ordinal INTEGER,metric_key TEXT,title TEXT,pillar TEXT,metric_value NUMERIC,previous_value NUMERIC,
  percent_change NUMERIC,numerator NUMERIC,denominator NUMERIC,sample_size BIGINT,suppressed BOOLEAN,
  quality_status TEXT,definition TEXT,formula TEXT,source TEXT,methodology_version TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  RETURN QUERY SELECT v.ordinal,v.metric_key,v.title,v.pillar,v.metric_value,v.previous_value,v.percent_change,
    v.numerator,v.denominator,v.sample_size,v.suppressed,v.quality_status,v.definition,v.formula,v.source,v.methodology_version
    FROM private.impact_report_values v WHERE v.report_id=p_report ORDER BY v.ordinal;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_generate_impact_report(
  p_report_kind TEXT,
  p_title TEXT,
  p_audience TEXT,
  p_window_start DATE,
  p_window_end DATE,
  p_country_source TEXT DEFAULT 'none',
  p_country_filter TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
  v_report UUID;
  v_checksum TEXT;
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  PERFORM private.require_aal2();
  IF p_report_kind NOT IN ('monthly_impact','community_health','safety_transparency','country_summary','research_readiness')
     OR p_audience NOT IN ('internal','external')
     OR p_country_source NOT IN ('none','declared_residence','technical_signal') THEN
    RAISE EXCEPTION 'invalid_report_parameters' USING ERRCODE='22023';
  END IF;
  IF p_window_start IS NULL OR p_window_end IS NULL OR p_window_end<p_window_start OR p_window_end-p_window_start>366 THEN
    RAISE EXCEPTION 'invalid_report_window' USING ERRCODE='22023';
  END IF;
  IF length(btrim(COALESCE(p_title,''))) NOT BETWEEN 3 AND 160 OR length(COALESCE(p_notes,''))>1000 THEN
    RAISE EXCEPTION 'invalid_report_text' USING ERRCODE='22023';
  END IF;
  IF (p_country_source='none') IS DISTINCT FROM (p_country_filter IS NULL) THEN
    RAISE EXCEPTION 'country_source_filter_mismatch' USING ERRCODE='22023';
  END IF;

  INSERT INTO private.impact_report_snapshots
    (report_kind,title,audience,window_start,window_end,country_source,country_filter,generated_by,notes)
  VALUES (p_report_kind,btrim(p_title),p_audience,p_window_start,p_window_end,p_country_source,
          CASE WHEN p_country_filter IS NULL THEN NULL ELSE upper(btrim(p_country_filter)) END,v_actor,NULLIF(btrim(COALESCE(p_notes,'')),''))
  RETURNING report_id INTO v_report;

  INSERT INTO private.impact_report_values
    (report_id,ordinal,metric_key,title,pillar,metric_value,previous_value,percent_change,numerator,denominator,
     sample_size,suppressed,quality_status,definition,formula,source,methodology_version)
  SELECT v_report,row_number() OVER (ORDER BY m.pillar,m.metric_key),m.metric_key,m.title,m.pillar,m.metric_value,
         m.previous_value,m.percent_change,m.numerator,m.denominator,m.sample_size,m.suppressed,m.quality_status,
         m.description,m.formula,m.source,m.methodology_version
    FROM public.admin_impact_metrics(
      p_window_start,p_window_end,
      CASE WHEN p_country_source='none' THEN 'overall' ELSE 'country' END,
      COALESCE(upper(btrim(p_country_filter)),'all'),p_country_source
    ) m;

  SELECT encode(extensions.digest(
    string_agg(v.metric_key||':'||COALESCE(v.metric_value::TEXT,'suppressed')||':'||v.methodology_version,'|' ORDER BY v.ordinal),
    'sha256'),'hex') INTO v_checksum
    FROM private.impact_report_values v WHERE v.report_id=v_report;
  UPDATE private.impact_report_snapshots SET checksum=v_checksum WHERE report_id=v_report;

  INSERT INTO public.audit_log(actor_id,actor_pseudonym,actor_role,action,target_type,target_id,target_label,after_state,reason,metadata)
  SELECT v_actor,u.anonymous_pseudonym,u.user_role::TEXT,'impact_report_generated','impact_report',v_report,btrim(p_title),
         jsonb_build_object('kind',p_report_kind,'audience',p_audience,'window_start',p_window_start,'window_end',p_window_end,'checksum',v_checksum),
         'Generated an immutable aggregate impact report snapshot.',jsonb_build_object('country_source',p_country_source,'country_filter',p_country_filter)
    FROM public.users u WHERE u.user_id=v_actor;
  RETURN v_report;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_log_impact_report_export(
  p_report UUID,
  p_format TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
  v_report private.impact_report_snapshots%ROWTYPE;
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  PERFORM private.require_aal2();
  IF p_format NOT IN ('csv','xlsx','pdf','json') THEN
    RAISE EXCEPTION 'invalid_export_format' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_report FROM private.impact_report_snapshots WHERE report_id=p_report;
  IF NOT FOUND THEN RAISE EXCEPTION 'report_not_found' USING ERRCODE='P0002'; END IF;

  INSERT INTO public.audit_log(actor_id,actor_pseudonym,actor_role,action,target_type,target_id,target_label,reason,metadata)
  SELECT v_actor,u.anonymous_pseudonym,u.user_role::TEXT,'impact_report_exported','impact_report',p_report,v_report.title,
         'Exported an immutable aggregate impact report.',jsonb_build_object('format',p_format,'checksum',v_report.checksum)
    FROM public.users u WHERE u.user_id=v_actor;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_impact_metrics(DATE,DATE,TEXT,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_impact_dimensions(DATE,DATE,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_impact_methodology() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_impact_data_quality() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_impact_reports(INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_impact_report_values(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_generate_impact_report(TEXT,TEXT,TEXT,DATE,DATE,TEXT,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_log_impact_report_export(UUID,TEXT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_impact_metrics(DATE,DATE,TEXT,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_impact_dimensions(DATE,DATE,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_impact_methodology() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_impact_data_quality() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_impact_reports(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_impact_report_values(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_generate_impact_report(TEXT,TEXT,TEXT,DATE,DATE,TEXT,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_log_impact_report_export(UUID,TEXT) TO authenticated;

-- One idempotent daily refresh, then a quality pass. Cron runs as a trusted
-- database role; clients and staff cannot invoke these private functions.
SELECT cron.schedule(
  'venttly-impact-daily-v1',
  '20 2 * * *',
  $job$SELECT private.refresh_impact_daily(current_date-1); SELECT private.run_impact_data_quality(current_date);$job$
);

NOTIFY pgrst, 'reload schema';
