-- Give a Tribe's rules a history, and tell members when they change.
--
-- Today replace_tribe_rules deletes every rule item and reinserts the list.
-- That has two consequences nobody chose: there is no record of what the rules
-- used to say, and a member who agreed to one set of rules can be moderated
-- under a different set without ever being told they changed.
--
-- For a community app that is a fairness problem before it is a feature gap.
-- A Keeper can quietly rewrite the terms after people have joined, and the
-- only evidence of the old terms is whatever a member happened to remember.
-- When someone is removed for breaking a rule, both sides should be able to
-- point at the same text and the same date.
--
-- So: every published set of rules is a numbered version with a timestamp, an
-- author and an optional note about what changed. Members are asked to read
-- the new version only if it was published after they joined — nobody is
-- nagged about history that predates them, and nobody is nagged about the
-- rules they agreed to on the way in.
--
-- A save that does not change the text does not create a version. Keepers
-- reorder and re-save while editing, and treating a no-op as a change would
-- train members to dismiss the notice without reading it, which defeats the
-- entire point.
--
-- Backfill starts the ledger at the tribe's creation date, not at now(). Rules
-- edited before this migration have no recorded history, and dating version 1
-- to today would tell every existing member their rules just changed when they
-- did not.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Where the versions live
-- ---------------------------------------------------------------------------

ALTER TABLE public.tribes
  ADD COLUMN IF NOT EXISTS rules_version INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.tribes.rules_version IS
  'Latest published rules version; 0 means no version has been published.';

CREATE TABLE IF NOT EXISTS public.tribe_rule_versions (
  tribe_id     UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
  version      INT  NOT NULL CHECK (version > 0),
  -- The full rule list as published, rule_id excluded on purpose: replacing
  -- rules regenerates every id, so ids say nothing about whether the text
  -- changed and storing them would make every save look like a change.
  rules        JSONB NOT NULL,
  change_note  TEXT CHECK (change_note IS NULL OR char_length(change_note) <= 280),
  published_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tribe_id, version)
);

COMMENT ON TABLE public.tribe_rule_versions IS
  'Immutable history of every published rule set. Written only by publish_tribe_rules.';

CREATE INDEX IF NOT EXISTS tribe_rule_versions_recent_idx
  ON public.tribe_rule_versions (tribe_id, version DESC);

-- One row per member per tribe: the newest version they have read. Kept apart
-- from tribe_members so that leaving and rejoining does not silently reset
-- someone's acknowledgement, and so this table can be read without widening
-- access to membership rows.
CREATE TABLE IF NOT EXISTS public.tribe_rule_acknowledgements (
  tribe_id        UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  version         INT  NOT NULL CHECK (version > 0),
  acknowledged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tribe_id, user_id)
);

COMMENT ON TABLE public.tribe_rule_acknowledgements IS
  'Newest rules version each member has confirmed reading.';

-- Both tables are reached only through the SECURITY DEFINER functions below.
-- RLS on with no policy is a deny-all, which is the intent: a client should
-- never be able to write an acknowledgement for somebody else, or edit
-- history after the fact.
ALTER TABLE public.tribe_rule_versions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tribe_rule_acknowledgements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.tribe_rule_versions        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.tribe_rule_acknowledgements FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Snapshotting
-- ---------------------------------------------------------------------------

-- The comparable form of a tribe's current rules: ordered, and without the
-- ids that change on every save.
CREATE OR REPLACE FUNCTION private.tribe_rules_snapshot(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'position',     ri.position,
           'title',        ri.title,
           'description',  ri.description,
           'template_key', ri.template_key,
           'is_enabled',   ri.is_enabled
         ) ORDER BY ri.position), '[]'::JSONB)
    FROM public.tribe_rule_items ri
   WHERE ri.tribe_id = p_tribe_id;
$$;

REVOKE ALL ON FUNCTION private.tribe_rules_snapshot(UUID) FROM PUBLIC, anon, authenticated;

-- Publishes the tribe's current rule items as the next version, unless they
-- are identical to the version already published. Returns the version number
-- in force afterwards.
CREATE OR REPLACE FUNCTION private.record_tribe_rules_version(
  p_tribe_id UUID,
  p_note     TEXT,
  p_actor    UUID
) RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_snapshot JSONB := private.tribe_rules_snapshot(p_tribe_id);
  v_latest   JSONB;
  v_current  INT;
  v_next     INT;
BEGIN
  SELECT t.rules_version INTO v_current
    FROM public.tribes t WHERE t.tribe_id = p_tribe_id;
  IF v_current IS NULL THEN
    RAISE EXCEPTION 'tribe_not_found';
  END IF;

  SELECT rv.rules INTO v_latest
    FROM public.tribe_rule_versions rv
   WHERE rv.tribe_id = p_tribe_id
   ORDER BY rv.version DESC
   LIMIT 1;

  -- Unchanged text is not a new version, even when the note differs. A note
  -- describes a change; without one there is nothing to describe.
  IF v_latest IS NOT NULL AND v_latest = v_snapshot THEN
    RETURN v_current;
  END IF;

  v_next := COALESCE(v_current, 0) + 1;

  INSERT INTO public.tribe_rule_versions (
    tribe_id, version, rules, change_note, published_by
  ) VALUES (
    p_tribe_id, v_next, v_snapshot, NULLIF(btrim(COALESCE(p_note, '')), ''), p_actor
  );

  UPDATE public.tribes
     SET rules_version = v_next
   WHERE tribe_id = p_tribe_id;

  RETURN v_next;
END $$;

REVOKE ALL ON FUNCTION private.record_tribe_rules_version(UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Publishing
-- ---------------------------------------------------------------------------

-- The writer Keepers call. Deliberately a new name rather than a third
-- argument on replace_tribe_rules: adding a defaulted parameter would leave
-- two overloads that both match a two-argument call, and PostgREST resolves
-- that as an error rather than a preference.
CREATE OR REPLACE FUNCTION public.publish_tribe_rules(
  p_tribe_id    UUID,
  p_rules       JSONB,
  p_change_note TEXT
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item     JSONB;
  v_position INT := 0;
  v_version  INT;
BEGIN
  PERFORM public.require_tribe_owner(p_tribe_id);

  IF jsonb_typeof(COALESCE(p_rules, '[]'::JSONB)) <> 'array'
     OR jsonb_array_length(COALESCE(p_rules, '[]'::JSONB)) > 50 THEN
    RAISE EXCEPTION 'invalid_rules';
  END IF;

  DELETE FROM public.tribe_rule_items WHERE tribe_id = p_tribe_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_rules, '[]'::JSONB)) LOOP
    IF char_length(btrim(COALESCE(v_item->>'title', ''))) NOT BETWEEN 2 AND 100 THEN
      RAISE EXCEPTION 'invalid_rule_title';
    END IF;
    INSERT INTO public.tribe_rule_items (
      tribe_id, position, title, description, template_key, is_enabled, created_by
    ) VALUES (
      p_tribe_id, v_position, btrim(v_item->>'title'),
      NULLIF(btrim(v_item->>'description'), ''), NULLIF(v_item->>'template_key', ''),
      COALESCE((v_item->>'is_enabled')::BOOLEAN, TRUE), (SELECT auth.uid())
    );
    v_position := v_position + 1;
  END LOOP;

  UPDATE public.tribes
     SET rules = NULLIF((
       SELECT string_agg((position + 1)::TEXT || '. ' || title, E'\n' ORDER BY position)
       FROM public.tribe_rule_items WHERE tribe_id = p_tribe_id AND is_enabled
     ), ''), updated_at = now()
   WHERE tribe_id = p_tribe_id;

  v_version := private.record_tribe_rules_version(
    p_tribe_id, p_change_note, (SELECT auth.uid())
  );

  PERFORM public.log_tribe_action(
    p_tribe_id, 'TRIBE_RULES_REPLACED', 'rules', p_tribe_id::TEXT,
    NULLIF(btrim(COALESCE(p_change_note, '')), ''), NULL, NULL,
    jsonb_build_object('count', v_position, 'version', v_version)
  );

  RETURN public.tribe_management_overview(p_tribe_id);
END $$;

REVOKE ALL ON FUNCTION public.publish_tribe_rules(UUID, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_tribe_rules(UUID, JSONB, TEXT) TO authenticated;

-- The existing two-argument entry point keeps working and now versions too,
-- so an older client build cannot write rules that bypass the history.
CREATE OR REPLACE FUNCTION public.replace_tribe_rules(p_tribe_id UUID, p_rules JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.publish_tribe_rules(p_tribe_id, p_rules, NULL);
END $$;

REVOKE ALL ON FUNCTION public.replace_tribe_rules(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_tribe_rules(UUID, JSONB) TO authenticated;

-- The other writer, which has been throwing since migration 0071.
--
-- 0071 changed tribes.rules from JSONB to TEXT and rebuilt the view that
-- depended on it, but left set_tribe_rules from 0045 assigning a JSONB
-- expression to the column. Postgres refuses that assignment, so every Save
-- Rules press in the moderation screen and the chat hub has raised 42804 —
-- the very bug 0071's own header says it was fixing, fixed in the column and
-- missed in the function.
--
-- Rather than repair it as a second, separate place rules can live, it now
-- writes the same rule items everything else reads. The free-text editors
-- become a plain-text view of the structured list: one rule per line, which
-- is exactly the shape those editors already load, because tribes.rules is
-- rendered as a numbered list. The leading "1. " is stripped on the way back
-- in so a load-then-save round trip does not accumulate numbering.
CREATE OR REPLACE FUNCTION public.set_tribe_rules(
  p_tribe_id UUID,
  p_rules    JSONB
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_text     TEXT;
  v_line     TEXT;
  v_desc     TEXT;
  v_template TEXT;
  v_items    JSONB := '[]'::JSONB;
BEGIN
  -- Accepts what the clients send ({"text": "..."}), a bare JSON string, or
  -- an already-structured array for anything that grows into it later.
  IF jsonb_typeof(COALESCE(p_rules, 'null'::JSONB)) = 'array' THEN
    PERFORM public.publish_tribe_rules(p_tribe_id, p_rules, NULL);
    RETURN;
  END IF;

  v_text := CASE jsonb_typeof(COALESCE(p_rules, 'null'::JSONB))
              WHEN 'object' THEN p_rules->>'text'
              WHEN 'string' THEN p_rules #>> '{}'
              ELSE NULL
            END;

  FOR v_line IN
    SELECT btrim(regexp_replace(raw_line, '^\s*\d+[\.\)]\s*', ''))
      FROM regexp_split_to_table(COALESCE(v_text, ''), '\r?\n') AS raw_line
  LOOP
    IF char_length(v_line) >= 2 THEN
      -- The plain-text form carries titles only. Without this lookup, a Keeper
      -- who opens the free-text editor and presses Save would silently erase
      -- every description written in the structured one — the text they were
      -- shown simply never contained them. An untouched line keeps its
      -- description; a genuinely new line has none to keep.
      SELECT ri.description, ri.template_key INTO v_desc, v_template
        FROM public.tribe_rule_items ri
       WHERE ri.tribe_id = p_tribe_id AND ri.title = left(v_line, 100)
       LIMIT 1;

      v_items := v_items || jsonb_build_array(jsonb_build_object(
        -- A rule title is capped at 100 characters; anything longer keeps its
        -- tail in the description rather than being silently truncated.
        'title',        left(v_line, 100),
        'description',  COALESCE(v_desc, NULLIF(btrim(substr(v_line, 101)), '')),
        'template_key', v_template,
        'is_enabled',   TRUE
      ));
      v_desc := NULL;
      v_template := NULL;
    END IF;
    EXIT WHEN jsonb_array_length(v_items) >= 50;
  END LOOP;

  PERFORM public.publish_tribe_rules(p_tribe_id, v_items, NULL);
END $$;

REVOKE ALL ON FUNCTION public.set_tribe_rules(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_tribe_rules(UUID, JSONB) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reading, as a member
-- ---------------------------------------------------------------------------

-- What the caller needs to know about this tribe's rules: the current text,
-- when it was published, what the Keeper said changed, and whether the caller
-- is being asked to read it.
--
-- needs_acknowledgement is true only when all three hold: the caller is a
-- member, a version exists that is newer than the one they last confirmed,
-- and that version was published after they joined. The last condition is
-- what keeps a new member from being handed a change notice for rules that
-- were already in force when they arrived.
CREATE OR REPLACE FUNCTION public.my_tribe_rules_status(p_tribe_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me        UUID := (SELECT auth.uid());
  v_joined    TIMESTAMPTZ;
  v_acked     INT;
  v_version   INT;
  v_published TIMESTAMPTZ;
  v_note      TEXT;
  v_needs     BOOLEAN := FALSE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT t.rules_version INTO v_version
    FROM public.tribes t WHERE t.tribe_id = p_tribe_id;
  IF v_version IS NULL THEN
    RAISE EXCEPTION 'tribe_not_found';
  END IF;

  SELECT rv.published_at, rv.change_note INTO v_published, v_note
    FROM public.tribe_rule_versions rv
   WHERE rv.tribe_id = p_tribe_id AND rv.version = v_version;

  SELECT tm.joined_at INTO v_joined
    FROM public.tribe_members tm
   WHERE tm.tribe_id = p_tribe_id AND tm.user_id = v_me;

  SELECT a.version INTO v_acked
    FROM public.tribe_rule_acknowledgements a
   WHERE a.tribe_id = p_tribe_id AND a.user_id = v_me;

  IF v_joined IS NOT NULL
     AND v_version > 0
     AND v_version > COALESCE(v_acked, 0)
     AND v_published IS NOT NULL
     AND v_published > v_joined THEN
    v_needs := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'tribe_id', p_tribe_id,
    'version', v_version,
    'published_at', v_published,
    'change_note', v_note,
    'acknowledged_version', v_acked,
    'is_member', v_joined IS NOT NULL,
    'needs_acknowledgement', v_needs,
    'rules', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'rule_id', ri.rule_id,
               'position', ri.position,
               'title', ri.title,
               'description', ri.description,
               'template_key', ri.template_key,
               'is_enabled', ri.is_enabled
             ) ORDER BY ri.position)
        FROM public.tribe_rule_items ri
       WHERE ri.tribe_id = p_tribe_id AND ri.is_enabled
    ), '[]'::JSONB)
  );
END $$;

REVOKE ALL ON FUNCTION public.my_tribe_rules_status(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_tribe_rules_status(UUID) TO authenticated;

-- Confirms the caller has read a version. Recording the version they saw,
-- rather than the current one, means a version published while the sheet was
-- open still gets shown rather than being marked read unseen.
CREATE OR REPLACE FUNCTION public.acknowledge_tribe_rules(
  p_tribe_id UUID,
  p_version  INT
) RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me     UUID := (SELECT auth.uid());
  v_exists BOOLEAN;
  v_final  INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_version IS NULL OR p_version < 1 THEN RAISE EXCEPTION 'invalid_version'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.tribe_members tm
     WHERE tm.tribe_id = p_tribe_id AND tm.user_id = v_me
  ) INTO v_exists;
  IF NOT v_exists THEN RAISE EXCEPTION 'not_a_member'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.tribe_rule_versions rv
     WHERE rv.tribe_id = p_tribe_id AND rv.version = p_version
  ) INTO v_exists;
  IF NOT v_exists THEN RAISE EXCEPTION 'unknown_version'; END IF;

  INSERT INTO public.tribe_rule_acknowledgements AS a (tribe_id, user_id, version)
  VALUES (p_tribe_id, v_me, p_version)
  ON CONFLICT (tribe_id, user_id) DO UPDATE
    -- GREATEST so a stale sheet cannot walk somebody's acknowledgement
    -- backwards and re-raise a notice they already cleared.
    SET version         = GREATEST(a.version, EXCLUDED.version),
        acknowledged_at = now()
  RETURNING a.version INTO v_final;

  RETURN v_final;
END $$;

REVOKE ALL ON FUNCTION public.acknowledge_tribe_rules(UUID, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.acknowledge_tribe_rules(UUID, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Reading, as a Keeper
-- ---------------------------------------------------------------------------

-- The history, newest first, with how many members have confirmed each
-- version. Keeper only: it is an administration view, and the per-version
-- counts would otherwise let any member measure the tribe.
CREATE OR REPLACE FUNCTION public.tribe_rules_history(
  p_tribe_id UUID,
  p_limit    INT DEFAULT 20
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
BEGIN
  PERFORM public.require_tribe_owner(p_tribe_id);

  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.version DESC) FROM (
      SELECT rv.version,
             rv.rules,
             rv.change_note,
             rv.published_at,
             u.anonymous_pseudonym AS published_by_pseudonym,
             (SELECT count(*) FROM public.tribe_rule_acknowledgements a
               WHERE a.tribe_id = rv.tribe_id AND a.version >= rv.version)
               AS acknowledged_count
        FROM public.tribe_rule_versions rv
        LEFT JOIN public.users u ON u.user_id = rv.published_by
       WHERE rv.tribe_id = p_tribe_id
       ORDER BY rv.version DESC
       LIMIT v_limit
    ) x
  ), '[]'::JSONB);
END $$;

REVOKE ALL ON FUNCTION public.tribe_rules_history(UUID, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tribe_rules_history(UUID, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Backfill
-- ---------------------------------------------------------------------------

-- Version 1 for every tribe that already has rules, dated to the tribe's
-- creation rather than to today. Every current member joined at or after that
-- moment, so the published_at > joined_at test is false for all of them and
-- nobody wakes up to a change notice for rules that did not change.
INSERT INTO public.tribe_rule_versions (tribe_id, version, rules, published_by, published_at)
SELECT t.tribe_id,
       1,
       private.tribe_rules_snapshot(t.tribe_id),
       t.keeper_id,
       t.created_at
  FROM public.tribes t
 WHERE EXISTS (SELECT 1 FROM public.tribe_rule_items ri WHERE ri.tribe_id = t.tribe_id)
ON CONFLICT (tribe_id, version) DO NOTHING;

UPDATE public.tribes t
   SET rules_version = v.max_version
  FROM (SELECT tribe_id, max(version) AS max_version
          FROM public.tribe_rule_versions GROUP BY tribe_id) v
 WHERE v.tribe_id = t.tribe_id
   AND t.rules_version < v.max_version;

COMMIT;

SELECT public.record_migration(
  '20260831090000', 'tribe_rules_versioning'
);

NOTIFY pgrst, 'reload schema';
