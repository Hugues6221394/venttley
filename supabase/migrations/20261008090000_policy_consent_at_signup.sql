-- Nothing in this application has ever asked anybody to agree to anything.
--
-- No Terms, no Privacy Policy, no acceptance record. `grep -riE
-- "terms|privacy|agree|policy"` across lib/presentation/screens/onboarding/
-- returns four hits and all four are password-policy imports. So every
-- account on this platform was created without consent to any document, and
-- there is no way to answer "what did this person agree to, and when" — which
-- is the one question a consent record exists to answer.
--
-- WHY CONSENT CANNOT RIDE ON SIGNUP METADATA
--
-- The obvious place to put this is handle_new_auth_user(), which already
-- reads pseudonym, avatar_seed and birth_year out of raw_user_meta_data. That
-- would be a mistake, and this repository already learned why: before
-- 474ed98 that same function trusted client metadata for the age gate, which
-- made the under-13 floor bypassable with the anon key that ships inside the
-- app. Consent written from `meta->>'accepted_terms'` would be forgeable the
-- same way, by the same key, and a forged acceptance is worse than a missing
-- one — it is a false record that looks authoritative.
--
-- It would also break the rule the feature exists to uphold: never silently
-- mark a user as having accepted. A trigger reading metadata marks everybody
-- who signs up, including a modified client that never displayed the
-- document.
--
-- So acceptance is an authenticated write through accept_policies(), the
-- server resolves which version is current, and the server stamps the time.
-- The client cannot name a version it likes, cannot backdate, and cannot
-- insert directly: policy_acceptances grants no INSERT and no UPDATE to
-- authenticated. There is no path to a consent row except the RPC.
--
-- ON THE GAP BETWEEN "ACCOUNT CREATED" AND "CONSENT RECORDED"
--
-- The account has to exist before it can make an authenticated call, so the
-- two writes cannot be one transaction. Rather than pretend otherwise, the
-- gap is made recoverable: my_outstanding_policies() reports every current
-- document the caller has not accepted, and the client routes on it. That is
-- the pattern this codebase already uses for an account with no birth_year —
-- the router sends it to /onboarding/age instead of letting it exist in a
-- half-made state — and it earns re-consent for free, because a new policy
-- version makes the same function non-empty for everybody.
--
-- WHY A TABLE AND NOT users.accepted_terms_at
--
-- A column holds one answer. Re-consent needs the history: which version, at
-- what time, for each document, kept after a newer version supersedes it.
-- One row per (user, kind, version) gives that, and makes the "has this
-- person accepted the current terms" question a join rather than a guess
-- about what a timestamp meant.
--
-- The document bodies live in the database for the same reason. Shipping them
-- as Flutter assets would version the text in the binary and the acceptance
-- in Postgres, and those two would drift the first time a policy changed
-- without an app release.
--
-- THE SEEDED v1 TEXT IS NOT LEGAL ADVICE
--
-- The bodies inserted at the bottom describe the data flows this repository
-- actually documents in docs/architecture.md — the processors, and the
-- categories of content that never reach them. They are accurate about the
-- system. They have not been reviewed by a lawyer, and the summary field says
-- so. Replace them before launch; the schema is built so that replacing them
-- is an INSERT of a new version, not an edit.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The versioned corpus
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.policy_documents (
    kind          TEXT NOT NULL CHECK (kind IN ('terms', 'privacy')),
    version       TEXT NOT NULL,
    title         TEXT NOT NULL,
    -- What changed since the previous version. Shown on the re-consent
    -- screen, because "the terms changed, agree again" with no statement of
    -- what changed is how consent becomes a click-through.
    summary       TEXT,
    body_markdown TEXT NOT NULL,
    -- The canonical hosted copy, for anybody who wants to read it outside the
    -- app or keep a link to it.
    body_url      TEXT,
    effective_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- FALSE for a correction that does not change what a member agreed to (a
    -- typo, a broken link). Those still create a version — the record should
    -- say which text was shown — but they do not put the whole userbase
    -- through a consent wall.
    material      BOOLEAN NOT NULL DEFAULT TRUE,
    retired_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (kind, version),
    CONSTRAINT policy_documents_body_present CHECK (length(btrim(body_markdown)) > 0)
);

COMMENT ON TABLE public.policy_documents IS
  'Versioned Terms and Privacy Policy text. A change is a new row, never an '
  'edit — an edited body would silently change what past acceptances mean.';

-- "Current" is the newest in-force version of each kind. Resolved in one
-- place so the accept path, the read path and the outstanding check can never
-- disagree about which document is live.
CREATE INDEX IF NOT EXISTS policy_documents_current_idx
    ON public.policy_documents (kind, effective_at DESC)
    WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. The acceptance record
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.policy_acceptances (
    user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,
    version     TEXT NOT NULL,
    accepted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, kind, version),
    FOREIGN KEY (kind, version)
        REFERENCES public.policy_documents (kind, version) ON DELETE RESTRICT
);

COMMENT ON TABLE public.policy_acceptances IS
  'One row per person per document version. Append-only by construction: no '
  'UPDATE or DELETE is granted to any client role, and accepted_at is set by '
  'the server, so an acceptance cannot be backdated or rewritten.';

-- ON DELETE RESTRICT above is deliberate. A policy version somebody accepted
-- must not be deletable, or the record of what they agreed to disappears
-- while the acceptance row survives. Retire it instead.

CREATE INDEX IF NOT EXISTS policy_acceptances_user_idx
    ON public.policy_acceptances (user_id, kind, accepted_at DESC);

-- ---------------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.policy_documents   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.policy_acceptances ENABLE ROW LEVEL SECURITY;

-- The documents are public, and have to be readable before an account exists
-- — somebody must be able to read the Terms while deciding whether to sign
-- up. Retired versions stay readable so a past acceptance can be explained.
DROP POLICY IF EXISTS "policy documents readable" ON public.policy_documents;
CREATE POLICY "policy documents readable"
    ON public.policy_documents FOR SELECT TO anon, authenticated
    USING (TRUE);

-- Your own consent history, plus staff for compliance questions. Not other
-- members': whether somebody accepted a policy is not public.
DROP POLICY IF EXISTS "policy acceptances own read" ON public.policy_acceptances;
CREATE POLICY "policy acceptances own read"
    ON public.policy_acceptances FOR SELECT TO authenticated
    USING (
      user_id = auth.uid()
      OR public.is_staff(auth.uid(), ARRAY['super_admin', 'admin'])
    );

GRANT SELECT ON public.policy_documents   TO anon, authenticated;
GRANT SELECT ON public.policy_acceptances TO authenticated;
-- No INSERT/UPDATE/DELETE to any client role on either table. Acceptance
-- enters through accept_policies() and nowhere else.

-- ---------------------------------------------------------------------------
-- 4. Reading the current documents
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_policies()
RETURNS TABLE (
    kind          TEXT,
    version       TEXT,
    title         TEXT,
    summary       TEXT,
    body_markdown TEXT,
    body_url      TEXT,
    effective_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT DISTINCT ON (d.kind)
           d.kind, d.version, d.title, d.summary,
           d.body_markdown, d.body_url, d.effective_at
      FROM public.policy_documents d
     WHERE d.retired_at IS NULL
       AND d.effective_at <= now()
     ORDER BY d.kind, d.effective_at DESC, d.version DESC;
$$;

COMMENT ON FUNCTION public.current_policies() IS
  'The in-force Terms and Privacy Policy. Callable by anon: the documents '
  'must be readable before signup completes.';

REVOKE ALL ON FUNCTION public.current_policies() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_policies() TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. What the caller still owes
-- ---------------------------------------------------------------------------
-- Empty means fully consented. Non-empty drives both the signup gate and
-- re-consent, which is why it is one function and not two: a new material
-- version makes it non-empty for the whole userbase with no other change.
CREATE OR REPLACE FUNCTION public.my_outstanding_policies()
RETURNS TABLE (
    kind          TEXT,
    version       TEXT,
    title         TEXT,
    summary       TEXT,
    body_markdown TEXT,
    body_url      TEXT,
    effective_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT c.kind, c.version, c.title, c.summary,
           c.body_markdown, c.body_url, c.effective_at
      FROM public.current_policies() c
      JOIN public.policy_documents d
        ON d.kind = c.kind AND d.version = c.version
     WHERE auth.uid() IS NOT NULL
       -- Never accepted this document at all: always outstanding, whether or
       -- not the live version is a material one.
       AND (
         NOT EXISTS (
           SELECT 1 FROM public.policy_acceptances a
            WHERE a.user_id = auth.uid() AND a.kind = c.kind
         )
         -- Otherwise only a material version forces a fresh acceptance. A
         -- typo fix creates a version so the record says which text was
         -- shown, but it does not put the whole userbase through a wall.
         OR (
           d.material
           AND NOT EXISTS (
             SELECT 1 FROM public.policy_acceptances a
              WHERE a.user_id = auth.uid()
                AND a.kind    = c.kind
                AND a.version = c.version
           )
         )
       );
$$;

REVOKE ALL ON FUNCTION public.my_outstanding_policies() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_outstanding_policies() TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Accepting
-- ---------------------------------------------------------------------------
-- The client passes the versions it actually rendered. The server checks each
-- against the live document and refuses a mismatch rather than recording the
-- current version regardless — otherwise a policy that changed while somebody
-- was reading the old one would be recorded as accepted unread, which is the
-- silent acceptance this whole design exists to prevent.
CREATE OR REPLACE FUNCTION public.accept_policies(
    p_terms_version   TEXT,
    p_privacy_version TEXT
) RETURNS TABLE (kind TEXT, version TEXT, accepted_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_me      UUID := auth.uid();
    v_terms   TEXT;
    v_privacy TEXT;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'not signed in' USING ERRCODE = '42501';
    END IF;

    SELECT c.version INTO v_terms
      FROM public.current_policies() c WHERE c.kind = 'terms';
    SELECT c.version INTO v_privacy
      FROM public.current_policies() c WHERE c.kind = 'privacy';

    IF v_terms IS NULL OR v_privacy IS NULL THEN
        -- No document to agree to. Failing closed is right: recording an
        -- acceptance of nothing would be a false record, and silently
        -- skipping consent is the thing this must never do.
        RAISE EXCEPTION 'policy_documents_missing' USING ERRCODE = 'P0002';
    END IF;

    IF p_terms_version IS DISTINCT FROM v_terms
       OR p_privacy_version IS DISTINCT FROM v_privacy THEN
        RAISE EXCEPTION 'policy_version_stale'
          USING ERRCODE = 'P0001',
                DETAIL  = format(
                  'current terms=%s privacy=%s; caller sent terms=%s privacy=%s',
                  v_terms, v_privacy, p_terms_version, p_privacy_version
                ),
                HINT    = 'Re-read the current documents and accept those.';
    END IF;

    -- DO NOTHING, not DO UPDATE. A repeat call is a retry of the same intent,
    -- and it must converge on the row that already exists rather than moving
    -- accepted_at forward — the first acceptance is the true one.
    --
    -- No conflict target on purpose. `ON CONFLICT (user_id, kind, version)`
    -- does not compile here: kind and version are also this function's OUT
    -- parameters, so the inference list is ambiguous between the variable and
    -- the column ("column reference \"kind\" is ambiguous", and the whole RPC
    -- fails at runtime rather than at CREATE time). A bare DO NOTHING infers
    -- from the primary key, which is the only unique constraint on the table,
    -- so it is exactly equivalent and cannot be shadowed.
    INSERT INTO public.policy_acceptances (user_id, kind, version)
    VALUES (v_me, 'terms', v_terms), (v_me, 'privacy', v_privacy)
    ON CONFLICT DO NOTHING;

    RETURN QUERY
        SELECT a.kind, a.version, a.accepted_at
          FROM public.policy_acceptances a
         WHERE a.user_id = v_me
           AND ((a.kind = 'terms'   AND a.version = v_terms)
             OR (a.kind = 'privacy' AND a.version = v_privacy));
END $$;

COMMENT ON FUNCTION public.accept_policies(TEXT, TEXT) IS
  'Record the caller''s agreement to the exact versions they were shown. '
  'Refuses a stale version instead of substituting the current one.';

REVOKE ALL ON FUNCTION public.accept_policies(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_policies(TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. The v1 documents
-- ---------------------------------------------------------------------------
-- Accurate about the system, per docs/architecture.md. Not lawyer-reviewed —
-- the summary field says so in the product, not just in this comment, because
-- a reviewer should be able to see the caveat without reading the migration.
INSERT INTO public.policy_documents
    (kind, version, title, summary, body_url, body_markdown, effective_at)
VALUES (
    'terms', '2026-09-07',
    'Venttly Terms & Conditions',
    'First published version. Pending legal review before public launch.',
    'https://venttly.app/terms',
$md$
# Venttly Terms & Conditions

_Version 2026-09-07. This text is pending legal review._

## 1. What Venttly is

Venttly is a space for anonymous emotional support. You post under a
pseudonym. We do not ask for your real name, and you should not post it.

## 2. Who may use it

You must be 13 or older. Members under 18 are placed in a restricted tier
with reduced messaging permissions. Your age is recorded from the date of
birth you supply at signup and is enforced by our servers.

## 3. Your account

Your account is protected by a password and a recovery phrase. **The recovery
phrase is the only off-device copy.** If you lose it and forget your password,
we cannot restore your account — we do not hold a copy that would let us.

You are responsible for what you post from your account.

## 4. What you may not do

- Harass, threaten, dox or impersonate anybody.
- Post sexual content involving minors. This is reported to the authorities.
- Encourage suicide or self-harm. Support is welcome; encouragement is not.
- Post another person's private information.
- Evade a moderation decision with a new account.
- Automate access, scrape the service, or attempt to breach its security.

## 5. Moderation

Content is checked automatically on submission and may be reviewed by our
moderation team after a report. We may remove content, restrict a feature,
suspend an account, or ban it. Where we do, you are told what happened and
may appeal.

## 6. Tribes

A Tribe is a community with a Keeper who moderates it. A Keeper sets the
Tribe's rules and may remove or ban members from that Tribe. Keepers act
within their own Tribes only, and remain subject to these Terms.

## 7. Your content

You keep ownership of what you write. You grant us the licence needed to
store it, show it to the audience you chose, and back it up. Deleting content
removes it from the service; backups age out on their normal schedule.

## 8. Ending your account

You may delete your account at any time from Settings. We may terminate an
account for a serious or repeated breach of these Terms.

## 9. No warranty; not a crisis service

Venttly is provided as is. **It is not a medical, clinical or emergency
service.** If you are in immediate danger, contact your local emergency
number or a crisis line — the app lists some.

## 10. Changes

If we change these Terms in a way that affects what you agreed to, we will
ask you to agree again before you continue using the service. We keep a
record of which version you accepted and when.
$md$,
    now()
), (
    'privacy', '2026-09-07',
    'Venttly Privacy Policy',
    'First published version. Pending legal review before public launch.',
    'https://venttly.app/privacy',
$md$
# Venttly Privacy Policy

_Version 2026-09-07. This text is pending legal review._

## 1. The short version

You are pseudonymous here. We hold as little about you as the service can
work with, and the things people are most afraid of us sharing — what you
vent about, what you say in a message, what you record as a Whisper — are
never sent to any advertising, analytics or third-party AI service.

## 2. What we hold

- **Your account:** pseudonym, display name, avatar, the hash of your
  password and recovery phrase, and your date of birth.
- **What you post:** Vents, comments, Whispers, messages, Tribe activity, and
  the reactions you give and receive.
- **How you use the app:** the events needed to operate and debug it, and to
  count activity. These pass through a scrubber that strips personal data
  before they leave the device.
- **Security records:** sign-in attempts, device sessions and risk signals,
  kept to protect accounts from takeover.

We do not ask for your real name. If you type it into a post, that is your
disclosure, not ours.

## 3. Who we share it with, and what they get

- **Supabase** — everything listed above. It is our database, and it is where
  the service runs.
- **Resend** — your email address, and only for an email you asked for, such
  as sign-in or account recovery.
- **Firebase** — a device token and generic notification text, to deliver push
  notifications. The notification never contains what somebody wrote.
- **Sightengine** — an uploaded image, when image scanning is switched on, to
  check whether it is unsafe.
- **PostHog** — scrubbed usage events, to understand how the app is used.
- **Sentry** — scrubbed error reports, so we can find crashes.

**What none of them ever receive:** the text of your Vents, the contents of
your messages, Whisper audio or transcripts, your recovery phrase, or a real
name if you ever entered one.

## 4. What is public

Your pseudonym, display name, avatar, bio, and your public activity counts
are visible to anyone. The content of your posts, your mood history and your
activity heatmap are visible only to your connections. Whether you have
accepted a policy, your date of birth, your email and your security records
are never public.

## 5. How long we keep it

For as long as your account exists. When you delete your account we remove
your content and personal data from the live service; backups age out on
their normal schedule. Records we are legally required to keep — such as a
child-safety report — are retained as the law requires.

## 6. Your choices

- Read, correct or export what we hold about you.
- Delete your account, from Settings.
- Turn off push notifications, from Settings or your device.
- Ask us a question about any of this.

## 7. Children

Venttly is not for anybody under 13. If we learn an account belongs to a
child under 13, we remove it.

## 8. Changes

If we change this policy in a way that affects you, we will ask you to
acknowledge the new version before you continue. We keep a record of which
version you acknowledged and when.
$md$,
    now()
)
ON CONFLICT (kind, version) DO NOTHING;

COMMIT;

SELECT public.record_migration(
  '20261008090000', 'policy_consent_at_signup'
);

NOTIFY pgrst, 'reload schema';
