-- Open Tribe creation to every adult account, and put the 18+ floor on the
-- server where it belongs.
--
-- Until now create_managed_tribe opened with `plug_approval_required`: only an
-- account already carrying the plug role, or an approved plug_profiles row,
-- could create a Tribe. So the product was "apply, wait for approval, then you
-- may build a community" — and every entry point to /tribes/new sat inside
-- Keeper surfaces a normal member never reaches. A new user could not create a
-- Tribe at all.
--
-- The role transition itself already works and is not touched here.
-- is_keeper_mode() reports `v_role IN ('plug','super_admin') OR v_kept > 0`
-- where v_kept counts tribes with keeper_id = me, so owning a Tribe *is* Keeper
-- capability. It is additive: nothing about the account's normal social
-- abilities changes, and one account can keep many Tribes.
--
-- What replaces the approval gate is an age floor, because the thing being
-- handed out is authority over a space that minors use.
--
-- WHY 18 IS HARDER THAN IT LOOKS HERE
--
-- users.birth_year stores a year and deliberately nothing more — see
-- 20260811010000, which chose that on the grounds that a full date is more
-- identifying than the safety benefit warranted. Year arithmetic cannot then
-- separate a 17-year-old who turns 18 in November from an 18-year-old who
-- turned 18 in January. Both read as `now - birth_year = 18`.
--
-- The existing 13 floor resolves that ambiguity permissively. This one must
-- not: admitting a 17-year-old as the operator of a community is the exact
-- harm the floor exists to prevent, so ambiguity resolves to deny.
--
-- Denying an entire birth cohort for up to a year is also wrong, so the
-- ambiguous band — and only that band — is asked for its birth *month*. One
-- dropdown, asked once, of the roughly one-twelfth of users who need it. A
-- month narrows identifiability by a factor of twelve compared with a full
-- date while making the 18th-birthday question exactly answerable, and users
-- outside that band are never asked anything.
--
-- Within the birth month itself the day is still unknown, so that too resolves
-- to deny: you become eligible the month after you turn 18. Erring by weeks in
-- the safe direction is the right trade for who gets to run a Tribe.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Birth month — nullable, write-once, only ever needed by the 18-year band.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS birth_month SMALLINT;

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_birth_month_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_birth_month_check
    CHECK (birth_month IS NULL OR birth_month BETWEEN 1 AND 12);

COMMENT ON COLUMN public.users.birth_month IS
  'Birth month only, no day. Collected solely to resolve whether an account in its 18th year has already had its birthday. Never required of users whose birth_year alone settles the question.';

GRANT SELECT (birth_month) ON public.users TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Eligibility, decided on the server.
-- ---------------------------------------------------------------------------
-- Returns exactly one of:
--   'adult'          — provably 18 or over
--   'minor'          — provably under 18, or claiming nothing at all
--   'month_required' — in the 18th year, birthday unknown
--
-- A NULL birth_year returns 'minor', not 'unknown'. An account that has never
-- stated an age has not earned the benefit of the doubt for this particular
-- permission.
CREATE OR REPLACE FUNCTION private.tribe_creation_age_status(p_user UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_year  INT;
  v_month INT;
  v_tier  TEXT;
  v_age   INT;
  v_now   DATE := (now() AT TIME ZONE 'UTC')::DATE;
BEGIN
  SELECT u.birth_year, u.birth_month, COALESCE(u.safety_tier::TEXT, 'standard')
    INTO v_year, v_month, v_tier
    FROM public.users AS u
   WHERE u.user_id = p_user;

  IF NOT FOUND THEN RETURN 'minor'; END IF;

  -- The tier is set by the server from the age the account declared at signup.
  -- If it says minor, that settles it regardless of what the columns now say —
  -- it is the one signal a later edit cannot quietly launder.
  IF v_tier = 'restricted_minor' THEN RETURN 'minor'; END IF;
  IF v_year IS NULL THEN RETURN 'minor'; END IF;

  v_age := EXTRACT(YEAR FROM v_now)::INT - v_year;
  IF v_age > 18 THEN RETURN 'adult'; END IF;
  IF v_age < 18 THEN RETURN 'minor'; END IF;

  -- Exactly 18 by year arithmetic: the birthday may or may not have happened.
  IF v_month IS NULL THEN RETURN 'month_required'; END IF;
  -- Strictly earlier month: the birthday is definitely past. The birth month
  -- itself is not enough, because the day is unknown.
  IF v_month < EXTRACT(MONTH FROM v_now)::INT THEN RETURN 'adult'; END IF;
  RETURN 'minor';
END $$;

REVOKE ALL ON FUNCTION private.tribe_creation_age_status(UUID) FROM PUBLIC;

-- What the client asks so it can show the right screen rather than guessing,
-- and so a refusal is explainable instead of a bare failure.
CREATE OR REPLACE FUNCTION public.my_tribe_creation_eligibility()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me     UUID := (SELECT auth.uid());
  v_status TEXT;
BEGIN
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('status', 'minor', 'eligible', FALSE);
  END IF;
  v_status := private.tribe_creation_age_status(v_me);
  RETURN jsonb_build_object(
    'status', v_status,
    'eligible', v_status = 'adult',
    'tribes_kept',
      (SELECT count(*)::INT FROM public.tribes t WHERE t.keeper_id = v_me)
  );
END $$;

REVOKE ALL ON FUNCTION public.my_tribe_creation_eligibility()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_tribe_creation_eligibility()
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Setting the month.
-- ---------------------------------------------------------------------------
-- Write-once. Without that, an account refused in March could retry in
-- April with a different month until one is accepted, which would make the
-- whole check theatre. Changing it afterwards is a support action, not a
-- client one.
CREATE OR REPLACE FUNCTION public.set_my_birth_month(p_month INT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_existing INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_month IS NULL OR p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_birth_month';
  END IF;

  SELECT u.birth_month INTO v_existing
    FROM public.users AS u WHERE u.user_id = v_me FOR UPDATE;

  IF v_existing IS NOT NULL AND v_existing <> p_month THEN
    RAISE EXCEPTION 'birth_month_already_set';
  END IF;

  UPDATE public.users SET birth_month = p_month WHERE user_id = v_me;
  RETURN public.my_tribe_creation_eligibility();
END $$;

REVOKE ALL ON FUNCTION public.set_my_birth_month(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_my_birth_month(INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. The gate itself.
-- ---------------------------------------------------------------------------
-- Body carried over verbatim from 20260716175655 apart from the gate and the
-- rate limit, so the validation, the tribes insert, the owner membership row
-- and the rules insert stay exactly as they were — all still one transaction.
CREATE OR REPLACE FUNCTION public.create_managed_tribe(
  p_name TEXT,
  p_category TEXT,
  p_description TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT 'public',
  p_tags TEXT[] DEFAULT '{}'::TEXT[],
  p_welcome_message TEXT DEFAULT NULL,
  p_settings JSONB DEFAULT '{}'::JSONB,
  p_rules JSONB DEFAULT '[]'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_tribe_id UUID;
  v_slug TEXT;
  v_item JSONB;
  v_position INT := 0;
  v_settings JSONB;
  v_age_status TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  -- Age, not approval. The old gate here required the plug role or an approved
  -- plug_profiles row, so a normal member could not create a Tribe at all and
  -- every entry point lived inside Keeper surfaces they never saw. Keeper
  -- capability is already conferred by owning a Tribe (is_keeper_mode counts
  -- tribes.keeper_id = me), so nothing needs granting afterwards — the only
  -- question worth asking at this boundary is whether this account is old
  -- enough to hold authority over a space that minors use.
  v_age_status := private.tribe_creation_age_status(v_me);
  IF v_age_status = 'month_required' THEN
    RAISE EXCEPTION 'age_verification_required';
  ELSIF v_age_status <> 'adult' THEN
    RAISE EXCEPTION 'adults_only';
  END IF;

  -- Creation is cheap to request and expensive to moderate, and it is now open
  -- to everyone, so it needs a ceiling. Five a day is far above any honest use
  -- and well below what makes spam worthwhile.
  IF NOT public.claim_rate_limit('tribe_create', 86400, 5) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  IF char_length(btrim(COALESCE(p_name, ''))) NOT BETWEEN 3 AND 50 THEN
    RAISE EXCEPTION 'tribe_name_length';
  END IF;
  IF char_length(btrim(COALESCE(p_category, ''))) NOT BETWEEN 2 AND 40 THEN
    RAISE EXCEPTION 'tribe_category_length';
  END IF;
  IF p_description IS NOT NULL AND char_length(p_description) > 500 THEN
    RAISE EXCEPTION 'tribe_description_length';
  END IF;
  IF p_visibility NOT IN ('public', 'private', 'invite_only') THEN
    RAISE EXCEPTION 'invalid_visibility';
  END IF;
  IF cardinality(COALESCE(p_tags, '{}'::TEXT[])) > 8 THEN
    RAISE EXCEPTION 'too_many_tags';
  END IF;
  IF jsonb_typeof(COALESCE(p_rules, '[]'::JSONB)) <> 'array'
     OR jsonb_array_length(COALESCE(p_rules, '[]'::JSONB)) > 50 THEN
    RAISE EXCEPTION 'invalid_rules';
  END IF;

  v_slug := btrim(regexp_replace(lower(btrim(p_name)), '[^a-z0-9]+', '-', 'g'), '-');
  IF v_slug = '' THEN v_slug := 'tribe'; END IF;
  WHILE EXISTS (SELECT 1 FROM public.tribes WHERE slug = v_slug) LOOP
    v_slug := v_slug || '-' || substr(md5(random()::TEXT), 1, 5);
  END LOOP;
  v_settings := jsonb_build_object(
    'join_approval_required', FALSE,
    'minimum_account_age_days', 0,
    'post_approval_mode', 'off',
    'posting_permission', 'members',
    'slow_mode_seconds', 0,
    'allow_whispers', TRUE,
    'allow_polls', TRUE,
    'allow_anonymous_reactions', TRUE,
    'content_sensitivity_filter', 'standard',
    'show_content_when_paused', TRUE,
    'invite_links_enabled', TRUE
  ) || COALESCE(p_settings, '{}'::JSONB);

  IF COALESCE((v_settings->>'minimum_account_age_days')::INT, 0) NOT BETWEEN 0 AND 3650 THEN
    RAISE EXCEPTION 'invalid_minimum_account_age';
  END IF;
  IF COALESCE((v_settings->>'slow_mode_seconds')::INT, 0) NOT BETWEEN 0 AND 86400 THEN
    RAISE EXCEPTION 'invalid_slow_mode';
  END IF;
  IF COALESCE(v_settings->>'post_approval_mode', 'off') NOT IN ('off', 'new_members', 'all') THEN
    RAISE EXCEPTION 'invalid_post_approval_mode';
  END IF;
  IF COALESCE(v_settings->>'posting_permission', 'members') NOT IN ('members', 'mods', 'keeper') THEN
    RAISE EXCEPTION 'invalid_posting_permission';
  END IF;
  IF COALESCE(v_settings->>'content_sensitivity_filter', 'standard') NOT IN ('off', 'standard', 'strict') THEN
    RAISE EXCEPTION 'invalid_sensitivity_filter';
  END IF;

  INSERT INTO public.tribes (
    name, slug, category, description, is_private, keeper_id,
    visibility, tags, welcome_message, settings, lifecycle_status, is_active
  ) VALUES (
    btrim(p_name), v_slug, btrim(p_category), NULLIF(btrim(p_description), ''),
    p_visibility <> 'public', v_me, p_visibility, COALESCE(p_tags, '{}'::TEXT[]),
    NULLIF(btrim(p_welcome_message), ''), v_settings, 'active', TRUE
  ) RETURNING tribe_id INTO v_tribe_id;

  INSERT INTO public.tribe_members (tribe_id, user_id, role)
  VALUES (v_tribe_id, v_me, 'keeper')
  ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = 'keeper';

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(COALESCE(p_rules, '[]'::JSONB))
  LOOP
    IF char_length(btrim(COALESCE(v_item->>'title', ''))) NOT BETWEEN 2 AND 100 THEN
      RAISE EXCEPTION 'invalid_rule_title';
    END IF;
    INSERT INTO public.tribe_rule_items (
      tribe_id, position, title, description, template_key, is_enabled, created_by
    ) VALUES (
      v_tribe_id, v_position, btrim(v_item->>'title'),
      NULLIF(btrim(v_item->>'description'), ''),
      NULLIF(v_item->>'template_key', ''),
      COALESCE((v_item->>'is_enabled')::BOOLEAN, TRUE),
      v_me
    );
    v_position := v_position + 1;
  END LOOP;

  IF v_position > 0 THEN
    UPDATE public.tribes
       SET rules = (
         SELECT string_agg((position + 1)::TEXT || '. ' || title, E'\n' ORDER BY position)
           FROM public.tribe_rule_items
          WHERE tribe_id = v_tribe_id AND is_enabled
       )
     WHERE tribe_id = v_tribe_id;
  END IF;
  PERFORM public.log_tribe_action(
    v_tribe_id,
    'TRIBE_CREATED',
    'tribe',
    v_tribe_id::TEXT,
    NULL,
    NULL,
    jsonb_build_object('name', btrim(p_name), 'visibility', p_visibility)
  );
  RETURN v_tribe_id;
END;
$$;

COMMIT;

SELECT public.record_migration(
  '20260828120000', 'open_tribe_creation_with_age_floor'
);

NOTIFY pgrst, 'reload schema';
