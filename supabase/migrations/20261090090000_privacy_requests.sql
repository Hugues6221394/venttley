-- Privacy requests, tracked to completion.
--
-- A request is a member exercising a data right: a copy of their data
-- (access), erasure, correction, objection, or something else they asked for.
-- Requests open themselves when a member asks to delete their account or
-- writes to support under "My data and privacy"; staff can open one for a
-- request that arrived another way. Each has a 30-day due date, an owner, an
-- append-only history and an outcome. Deletion requests complete themselves
-- when the account is erased, and are withdrawn if the member cancels.
--
-- The export is a JSON copy of what Venttly holds about the member, built
-- here so it reads the same tables the app writes. The console stores it in a
-- private bucket and emails the member a link that expires after 7 days.
BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('privacy-exports', 'privacy-exports', false, 52428800, ARRAY['application/json'])
ON CONFLICT (id) DO NOTHING;

CREATE TABLE private.privacy_requests (
  request_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id         UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  member_pseudonym  TEXT NOT NULL,
  kind              TEXT NOT NULL CHECK (kind IN ('access','deletion','correction','objection','other')),
  source            TEXT NOT NULL CHECK (source IN ('deletion_request','support','staff')),
  support_case_id   UUID,
  state             TEXT NOT NULL DEFAULT 'received'
                      CHECK (state IN ('received','in_progress','completed','refused','withdrawn')),
  identity_note     TEXT CHECK (identity_note IS NULL OR length(identity_note) BETWEEN 3 AND 500),
  assigned_to       UUID,
  due_at            TIMESTAMPTZ NOT NULL,
  export_path       TEXT,
  export_sent_at    TIMESTAMPTZ,
  export_expires_at TIMESTAMPTZ,
  outcome_note      TEXT,
  closed_at         TIMESTAMPTZ,
  closed_by         UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  version           BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
  CHECK ((state IN ('completed','refused','withdrawn')) = (closed_at IS NOT NULL))
);
CREATE UNIQUE INDEX privacy_requests_one_open ON private.privacy_requests (member_id, kind)
  WHERE state IN ('received','in_progress');
CREATE INDEX privacy_requests_queue ON private.privacy_requests (state, due_at);
CREATE INDEX privacy_requests_member ON private.privacy_requests (member_id, created_at DESC);

CREATE TABLE private.privacy_request_events (
  event_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_id UUID NOT NULL REFERENCES private.privacy_requests(request_id),
  actor_id   UUID,
  kind       TEXT NOT NULL CHECK (kind IN
               ('opened','started','completed','refused','withdrawn','erased','export_sent','export_cleared')),
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX privacy_request_events_request ON private.privacy_request_events (request_id, event_id);
CREATE TRIGGER privacy_request_events_immutable BEFORE UPDATE OR DELETE ON private.privacy_request_events
  FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

ALTER TABLE private.privacy_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.privacy_request_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.privacy_requests, private.privacy_request_events FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE private.privacy_request_events_event_id_seq FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Intake
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.open_privacy_request(p_member UUID, p_kind TEXT, p_source TEXT, p_due TIMESTAMPTZ,
  p_support_case UUID DEFAULT NULL, p_actor UUID DEFAULT NULL, p_identity TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result UUID;
BEGIN
  INSERT INTO private.privacy_requests (member_id, member_pseudonym, kind, source, support_case_id, due_at, identity_note)
  SELECT u.user_id, u.anonymous_pseudonym, p_kind, p_source, p_support_case, p_due, p_identity
    FROM public.users u WHERE u.user_id = p_member
  ON CONFLICT (member_id, kind) WHERE state IN ('received','in_progress') DO NOTHING
  RETURNING request_id INTO result;
  IF result IS NOT NULL THEN
    INSERT INTO private.privacy_request_events (request_id, actor_id, kind, note)
    VALUES (result, p_actor, 'opened', p_source);
  END IF;
  RETURN result;
END $$;

CREATE FUNCTION private.privacy_on_deletion_request() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r RECORD;
BEGIN
  IF NEW.deletion_requested_at IS NOT NULL AND OLD.deletion_requested_at IS NULL THEN
    PERFORM private.open_privacy_request(NEW.user_id, 'deletion', 'deletion_request',
      NEW.deletion_requested_at + interval '30 days', NULL, NEW.user_id,
      'Requested from a signed-in app session.');
  ELSIF NEW.deletion_requested_at IS NULL AND OLD.deletion_requested_at IS NOT NULL THEN
    FOR r IN UPDATE private.privacy_requests
                SET state = 'withdrawn', closed_at = clock_timestamp(), closed_by = NEW.user_id,
                    outcome_note = 'The member cancelled the deletion.', updated_at = clock_timestamp(), version = version + 1
              WHERE member_id = NEW.user_id AND kind = 'deletion' AND state IN ('received','in_progress')
              RETURNING request_id
    LOOP
      INSERT INTO private.privacy_request_events (request_id, actor_id, kind) VALUES (r.request_id, NEW.user_id, 'withdrawn');
    END LOOP;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER privacy_on_deletion_request AFTER UPDATE OF deletion_requested_at ON public.users
  FOR EACH ROW EXECUTE FUNCTION private.privacy_on_deletion_request();

-- Before the row goes: the foreign key clears member_id afterwards.
CREATE FUNCTION private.privacy_on_account_erased() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN UPDATE private.privacy_requests
              SET state = CASE WHEN kind = 'deletion' THEN 'completed' ELSE 'withdrawn' END,
                  closed_at = clock_timestamp(),
                  outcome_note = CASE WHEN kind = 'deletion' THEN 'The account and its data were erased.'
                                      ELSE 'Closed because the account was erased.' END,
                  updated_at = clock_timestamp(), version = version + 1
            WHERE member_id = OLD.user_id AND state IN ('received','in_progress')
            RETURNING request_id
  LOOP
    INSERT INTO private.privacy_request_events (request_id, kind) VALUES (r.request_id, 'erased');
  END LOOP;
  RETURN OLD;
END $$;
CREATE TRIGGER privacy_on_account_erased BEFORE DELETE ON public.users
  FOR EACH ROW EXECUTE FUNCTION private.privacy_on_account_erased();

CREATE FUNCTION private.privacy_on_support_case() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.category = 'privacy_request' AND NEW.member_id IS NOT NULL THEN
    PERFORM private.open_privacy_request(NEW.member_id, 'other', 'support', now() + interval '30 days',
      NEW.support_case_id, NEW.member_id, 'Sent from a signed-in app session.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER privacy_on_support_case AFTER INSERT ON private.support_cases
  FOR EACH ROW EXECUTE FUNCTION private.privacy_on_support_case();

REVOKE ALL ON FUNCTION private.open_privacy_request(UUID,TEXT,TEXT,TIMESTAMPTZ,UUID,UUID,TEXT),
  private.privacy_on_deletion_request(), private.privacy_on_account_erased(), private.privacy_on_support_case()
  FROM PUBLIC, anon, authenticated, service_role;

-- Pending deletions from before this migration.
SELECT private.open_privacy_request(user_id, 'deletion', 'deletion_request', deletion_requested_at + interval '30 days',
  NULL, user_id, 'Requested from a signed-in app session.')
FROM public.users WHERE deletion_requested_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
-- Credentials and their derivatives never leave, even to their owner.
CREATE FUNCTION private.privacy_scrub(p_row JSONB) RETURNS JSONB
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT COALESCE(jsonb_object_agg(k, v), '{}'::JSONB)
    FROM jsonb_each(p_row) e(k, v)
   WHERE k !~ '(hash|token|secret|salt|blob|signature|public_key|_normalized$)'
$$;

CREATE FUNCTION private.privacy_rows(p_table TEXT, p_column TEXT, p_member UUID, p_order TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result JSONB;
BEGIN
  IF to_regclass(p_table) IS NULL THEN RETURN NULL; END IF;
  EXECUTE format('SELECT COALESCE(jsonb_agg(private.privacy_scrub(to_jsonb(t))), ''[]''::JSONB) '
                 'FROM (SELECT * FROM %s WHERE %I = $1 %s LIMIT 5000) t',
                 p_table, p_column, CASE WHEN p_order IS NULL THEN '' ELSE 'ORDER BY ' || quote_ident(p_order) || ' DESC' END)
    INTO result USING p_member;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION private.privacy_scrub(JSONB), private.privacy_rows(TEXT,TEXT,UUID,TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION private.require_privacy_operator(p_mutation BOOLEAN DEFAULT false) RETURNS VOID
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  IF p_mutation THEN PERFORM private.require_aal2(); END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_privacy_operator(BOOLEAN) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.admin_privacy_export(p_request UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r private.privacy_requests%ROWTYPE; m UUID; sections JSONB := '{}'::JSONB; s RECORD; rows JSONB;
BEGIN
  PERFORM private.require_privacy_operator(false);
  PERFORM private.require_aal2();
  IF NOT public.claim_rate_limit('privacy_export', 3600, 20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO r FROM private.privacy_requests WHERE request_id = p_request;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  IF r.member_id IS NULL THEN RAISE EXCEPTION 'member_erased'; END IF;
  IF r.state NOT IN ('received','in_progress') OR r.kind NOT IN ('access','other') THEN RAISE EXCEPTION 'privacy_conflict'; END IF;
  m := r.member_id;

  FOR s IN SELECT * FROM (VALUES
      ('personas','public.personas','user_id','created_at'),
      ('vents','public.posts','author_id','created_at'),
      ('comments','public.posts_comments','author_id','created_at'),
      ('whispers','public.whispers','author_id','created_at'),
      ('whisper_comments','public.whisper_comments','author_id','created_at'),
      ('prompt_answers','public.prompt_answers','author_id','created_at'),
      ('direct_messages_sent','public.chat_messages','sender_id','created_at'),
      ('tribe_messages_sent','public.tribe_messages','sender_id','created_at'),
      ('tribe_memberships','public.tribe_members','user_id','joined_at'),
      ('tribe_join_requests','public.tribe_join_requests','user_id',NULL),
      ('likes','public.post_likes','user_id',NULL),
      ('saves','public.post_saves','user_id',NULL),
      ('poll_votes','public.poll_votes','user_id',NULL),
      ('reports_filed','public.reports','reporter_id',NULL),
      ('feedback','public.feedback_reports','reporter_id',NULL),
      ('policy_acceptances','public.policy_acceptances','user_id',NULL),
      ('devices','public.user_devices','user_id',NULL),
      ('sessions','public.device_sessions','user_id',NULL),
      ('security_events','public.security_events','user_id','created_at'),
      ('subscriptions','public.subscriptions','user_id',NULL),
      ('verification_requests','public.verification_requests','user_id',NULL),
      ('badges','public.user_badges','user_id',NULL),
      ('notifications','public.notifications','user_id','created_at')
    ) v(label, tbl, col, ord)
  LOOP
    rows := private.privacy_rows(s.tbl, s.col, m, s.ord);
    IF rows IS NOT NULL THEN sections := sections || jsonb_build_object(s.label, rows); END IF;
  END LOOP;

  sections := sections || jsonb_build_object(
    'support_conversations', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('subject', c.subject, 'category', c.category, 'opened_at', c.created_at,
        'messages', (SELECT COALESCE(jsonb_agg(jsonb_build_object('from', CASE WHEN sm.author_kind = 'member' THEN 'me' ELSE 'venttly' END,
                        'body', sm.body, 'at', sm.created_at) ORDER BY sm.created_at), '[]'::JSONB)
                       FROM private.support_messages sm WHERE sm.support_case_id = c.support_case_id))), '[]'::JSONB)
        FROM private.support_cases c WHERE c.member_id = m),
    'messages_from_venttly', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('channel', mc.channel, 'subject', mc.subject, 'body', mc.body,
        'at', mc.created_at) ORDER BY mc.created_at), '[]'::JSONB)
        FROM private.member_communications mc WHERE mc.member_id = m AND mc.rescinded_at IS NULL));

  PERFORM private.record_operational_audit(auth.uid(), 'privacy.export_built', 'privacy_request', p_request,
    r.member_pseudonym, 'Built a data export for a privacy request.', '{}'::JSONB);

  RETURN jsonb_build_object(
    'format', 'venttly-data-export/1',
    'generated_at', now(),
    'about', 'Everything Venttly holds about your account, up to 5,000 items per section. Passwords, recovery secrets and security keys are never included.',
    'account', (SELECT private.privacy_scrub(to_jsonb(u) - ARRAY['shadow_banned','safety_tier','verification_override','recovery_email_pending'])
                  FROM public.users u WHERE u.user_id = m),
    'data', sections);
END $$;

-- ---------------------------------------------------------------------------
-- Staff workflow
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_open_privacy_request(p_operation UUID, p_member UUID, p_kind TEXT, p_identity_note TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor UUID := auth.uid(); result UUID;
  request JSONB := jsonb_build_object('member', p_member, 'kind', p_kind, 'identity', p_identity_note);
BEGIN
  PERFORM private.require_privacy_operator(false);
  PERFORM private.require_aal2();
  IF p_operation IS NULL OR p_member IS NULL OR p_kind IS NULL OR p_kind NOT IN ('access','deletion','correction','objection','other')
     OR p_identity_note IS NULL OR length(btrim(p_identity_note)) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'invalid_input';
  END IF;
  result := private.admin_operation_existing(actor, p_operation, 'privacy.open', request);
  IF result IS NOT NULL THEN RETURN result; END IF;
  IF NOT public.claim_rate_limit('privacy_open', 3600, 30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_member) THEN RAISE EXCEPTION 'not_found'; END IF;
  result := private.open_privacy_request(p_member, p_kind, 'staff', now() + interval '30 days', NULL, actor, btrim(p_identity_note));
  IF result IS NULL THEN RAISE EXCEPTION 'privacy_request_open'; END IF;
  PERFORM private.record_admin_operation(actor, p_operation, 'privacy.open', request, result);
  PERFORM private.record_operational_audit(actor, 'privacy.open', 'privacy_request', result, p_kind,
    'Opened a privacy request.', jsonb_build_object('member', p_member, 'kind', p_kind));
  RETURN result;
END $$;

-- start · complete · refuse · record_export · clear_export
CREATE FUNCTION public.admin_privacy_request_command(p_operation UUID, p_request UUID, p_version BIGINT, p_command TEXT,
  p_note TEXT DEFAULT NULL, p_export_path TEXT DEFAULT NULL, p_link TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor UUID := auth.uid(); r private.privacy_requests%ROWTYPE; address TEXT; next_state TEXT; event TEXT;
  request JSONB := jsonb_build_object('request', p_request, 'version', p_version, 'command', p_command,
                                      'note', p_note, 'path', p_export_path);
BEGIN
  PERFORM private.require_privacy_operator(false);
  PERFORM private.require_aal2();
  IF p_operation IS NULL OR p_request IS NULL OR p_version IS NULL OR p_command IS NULL
     OR p_command NOT IN ('start','complete','refuse','record_export','clear_export') THEN
    RAISE EXCEPTION 'invalid_input';
  END IF;
  IF private.admin_operation_existing(actor, p_operation, 'privacy.command', request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('privacy_command', 60, 30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO r FROM private.privacy_requests WHERE request_id = p_request FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  IF r.version <> p_version THEN RAISE EXCEPTION 'privacy_conflict'; END IF;

  IF p_command = 'clear_export' THEN
    IF r.export_path IS NULL THEN RAISE EXCEPTION 'privacy_conflict'; END IF;
    UPDATE private.privacy_requests SET export_path = NULL, updated_at = clock_timestamp(), version = version + 1
     WHERE request_id = p_request;
    event := 'export_cleared';
  ELSE
    IF r.state NOT IN ('received','in_progress') THEN RAISE EXCEPTION 'privacy_conflict'; END IF;
    IF p_command = 'start' THEN
      IF r.state <> 'received' THEN RAISE EXCEPTION 'privacy_conflict'; END IF;
      UPDATE private.privacy_requests SET state = 'in_progress', assigned_to = COALESCE(assigned_to, actor),
             updated_at = clock_timestamp(), version = version + 1 WHERE request_id = p_request;
      event := 'started';
    ELSIF p_command IN ('complete','refuse') THEN
      -- Erasure is done by the scheduled purge, which closes the request itself.
      IF r.kind = 'deletion' THEN RAISE EXCEPTION 'deletion_completes_itself'; END IF;
      IF p_note IS NULL OR length(btrim(p_note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_input'; END IF;
      next_state := CASE p_command WHEN 'complete' THEN 'completed' ELSE 'refused' END;
      UPDATE private.privacy_requests SET state = next_state, outcome_note = btrim(p_note), closed_at = clock_timestamp(),
             closed_by = actor, updated_at = clock_timestamp(), version = version + 1 WHERE request_id = p_request;
      event := next_state;
    ELSE
      IF r.kind NOT IN ('access','other') OR r.member_id IS NULL THEN RAISE EXCEPTION 'privacy_conflict'; END IF;
      IF p_export_path IS NULL OR p_export_path !~ ('^' || p_request::TEXT || '/[0-9a-f-]{36}\.json$')
         OR p_link IS NULL OR p_link !~ '^https://' OR length(p_link) > 2000 THEN
        RAISE EXCEPTION 'invalid_input';
      END IF;
      address := private.member_email_address(r.member_id);
      IF address IS NULL THEN RAISE EXCEPTION 'email_unavailable'; END IF;
      INSERT INTO public.email_outbox (user_id, template, to_address, variables)
      VALUES (r.member_id, 'staff_message', address, jsonb_build_object(
        'subject', 'Your Venttly data',
        'body', 'You asked for a copy of the data Venttly holds about you. Download it here within 7 days: '
                || p_link || E'\n\nIf you did not ask for this, reply to this email or contact us from Settings, Contact Venttly.'));
      UPDATE private.privacy_requests SET export_path = p_export_path, export_sent_at = clock_timestamp(),
             export_expires_at = clock_timestamp() + interval '7 days',
             state = CASE WHEN state = 'received' THEN 'in_progress' ELSE state END,
             assigned_to = COALESCE(assigned_to, actor), updated_at = clock_timestamp(), version = version + 1
       WHERE request_id = p_request;
      event := 'export_sent';
    END IF;
  END IF;

  INSERT INTO private.privacy_request_events (request_id, actor_id, kind, note)
  VALUES (p_request, actor, event, CASE WHEN p_command IN ('complete','refuse') THEN btrim(p_note) END);
  PERFORM private.record_admin_operation(actor, p_operation, 'privacy.command', request, p_request);
  PERFORM private.record_operational_audit(actor, 'privacy.' || event, 'privacy_request', p_request, r.member_pseudonym,
    'Privacy request: ' || replace(event, '_', ' ') || '.', jsonb_build_object('kind', r.kind, 'previous_version', r.version));
END $$;

CREATE FUNCTION public.admin_privacy_requests(p_view TEXT DEFAULT 'open') RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_privacy_operator(false);
  IF NOT public.claim_rate_limit('privacy_read', 60, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_view IS NULL OR p_view NOT IN ('open','closed') THEN RAISE EXCEPTION 'invalid_input'; END IF;
  RETURN (SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::JSONB) FROM (
    SELECT r.request_id, r.member_id, r.member_pseudonym, u.display_name AS member_name, r.kind, r.source, r.state,
           r.due_at, r.due_at < now() AND r.state IN ('received','in_progress') AS overdue,
           r.created_at, r.closed_at, r.export_sent_at, r.support_case_id, a.display_name AS assignee_name
      FROM private.privacy_requests r
      LEFT JOIN public.users u ON u.user_id = r.member_id
      LEFT JOIN public.users a ON a.user_id = r.assigned_to
     WHERE (p_view = 'open') = (r.state IN ('received','in_progress'))
     ORDER BY CASE WHEN p_view = 'open' THEN r.due_at END ASC, r.closed_at DESC NULLS LAST
     LIMIT 200) x);
END $$;

CREATE FUNCTION public.admin_privacy_member_requests(p_member UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_privacy_operator(false);
  IF NOT public.claim_rate_limit('privacy_read', 60, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN jsonb_build_object(
    'email_available', private.member_email_address(p_member) IS NOT NULL,
    'requests', (SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::JSONB) FROM (
      SELECT r.request_id, r.kind, r.source, r.state, r.due_at, r.identity_note, r.support_case_id,
             r.due_at < now() AND r.state IN ('received','in_progress') AS overdue,
             r.export_path, r.export_sent_at, r.export_expires_at, r.outcome_note, r.closed_at, r.created_at, r.version,
             a.display_name AS assignee_name,
             (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', e.kind, 'note', e.note, 'at', e.created_at,
                       'actor', COALESCE(s.display_name, CASE WHEN e.actor_id = r.member_id THEN 'Member' ELSE 'System' END))
                       ORDER BY e.event_id), '[]'::JSONB)
                FROM private.privacy_request_events e LEFT JOIN public.users s ON s.user_id = e.actor_id AND s.user_id <> r.member_id
               WHERE e.request_id = r.request_id) AS events
        FROM private.privacy_requests r
        LEFT JOIN public.users a ON a.user_id = r.assigned_to
       WHERE r.member_id = p_member) x));
END $$;

REVOKE ALL ON FUNCTION public.admin_privacy_export(UUID),
  public.admin_open_privacy_request(UUID,UUID,TEXT,TEXT),
  public.admin_privacy_request_command(UUID,UUID,BIGINT,TEXT,TEXT,TEXT,TEXT),
  public.admin_privacy_requests(TEXT), public.admin_privacy_member_requests(UUID)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_privacy_export(UUID),
  public.admin_open_privacy_request(UUID,UUID,TEXT,TEXT),
  public.admin_privacy_request_command(UUID,UUID,BIGINT,TEXT,TEXT,TEXT,TEXT),
  public.admin_privacy_requests(TEXT), public.admin_privacy_member_requests(UUID)
  TO authenticated;

SELECT public.record_migration('20261090090000', 'privacy_requests');
COMMIT;
