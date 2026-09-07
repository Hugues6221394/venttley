-- Make the legal_hold flag do something.
--
-- 20261004090000 added moderation_cases.legal_hold and an audited RPC to set
-- it, on the strength of the README's requirement to "prevent normal account
-- deletion or cleanup from destroying open-case material". It did not wire the
-- flag to anything. Verified: put a case under legal hold, delete the subject,
-- and the delete succeeds — the account and its content go, and the case is
-- left pointing at a subject_id of NULL via ON DELETE SET NULL. A preservation
-- flag that preserves nothing is worse than no flag, because the operator who
-- set it believes the evidence is safe.
--
-- public.users already has private.prevent_legal_hold_user_delete (from
-- 20260811222118_harden_trust_boundaries.sql), which blocks deletion while an
-- open CSAM incident names the author. That is the same job for a narrower
-- case, so this extends that function rather than adding a second trigger
-- competing for the same decision.
--
-- Scope note: this gates on legal_hold specifically, not on "any open case".
-- Blocking deletion for every unresolved report would make a spam report
-- enough to refuse a member's deletion request, which trades one obligation
-- for another. legal_hold is the deliberate, reasoned, audited "preserve this"
-- signal — admin_set_case_legal_hold already requires a reason — and it is
-- the right thing to enforce. Status is deliberately not part of the test: a
-- hold can outlive the decision, and it lifts when an operator lifts it.

CREATE OR REPLACE FUNCTION private.prevent_legal_hold_user_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_case_id UUID;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.csam_incidents AS incident
     WHERE incident.author_id = OLD.user_id
       AND incident.status IN ('detected', 'reported')
  ) THEN
    RAISE EXCEPTION 'legal_hold_active' USING ERRCODE = 'P0001';
  END IF;

  -- A moderation case explicitly placed under legal hold.
  SELECT c.case_id INTO v_case_id
    FROM public.moderation_cases AS c
   WHERE c.subject_id = OLD.user_id
     AND c.legal_hold
   LIMIT 1;

  IF v_case_id IS NOT NULL THEN
    -- Name the case, so the operator can find the hold and decide whether to
    -- lift it rather than guessing why the delete was refused.
    RAISE EXCEPTION
      'legal_hold_active: moderation case % is under legal hold; lift it with admin_set_case_legal_hold before deleting this account',
      v_case_id
      USING ERRCODE = 'P0001';
  END IF;

  RETURN OLD;
END;
$$;

REVOKE ALL ON FUNCTION private.prevent_legal_hold_user_delete()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
