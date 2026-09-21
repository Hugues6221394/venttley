-- Privacy Policy and Terms, rewritten for Rwandan law.
--
-- The 2026-09-07 versions were honest and readable and said almost nothing that
-- protects CODAFRIQA. They named no provider, no governing law, no forum, no
-- limitation of liability, no indemnity, and no legal basis for processing
-- anybody's data. For a mental-health platform holding what people say when
-- they are at their worst, that is the wrong half of the document to have
-- finished first.
--
-- What is added, and why each one is load-bearing:
--
--   Provider identity        A user, a court and a regulator all need to know
--                            who they are dealing with. Absent, the operator is
--                            whoever a claimant says it is.
--   Governing law and forum  Rwandan law, courts of Kigali. Without it, a
--                            claimant chooses, and they will not choose Kigali.
--   Limitation of liability  The clause that decides whether a bad outcome is a
--                            refund or a company. Capped, with the carve-outs
--                            Rwandan law does not permit anyone to exclude.
--   Indemnity                Venttly hosts what other people write. Without
--                            this, their conduct is the operator's problem.
--   Not a crisis service     Already present and deliberately strengthened. On
--                            this product it is the single most important
--                            sentence in either document.
--   Legal basis + rights     Law N° 058/2021 relating to the protection of
--                            personal data and privacy requires both, names the
--                            National Cyber Security Authority as supervisory
--                            authority, and regulates transfer outside Rwanda.
--                            Every processor this service uses is outside
--                            Rwanda, so the transfer section is not optional.
--   Automated decisions      Automod acts on content without a human in the
--                            loop. A data subject is entitled to know that and
--                            to ask for review, which the appeals flow already
--                            provides -- the policy simply never said so.
--
-- MATERIAL, SO CONSENT IS ASKED AGAIN
--
-- These change what a member agreed to, so `material` is true and the previous
-- versions are retired rather than edited. policy_acceptances is keyed on
-- (user_id, kind, version), so every existing member is asked once more and the
-- old rows still resolve to the exact text they accepted at the time.
-- private.assert_user_can_write refuses content writes until they do.
--
-- NOT LEGAL ADVICE, AND NOT A SUBSTITUTE FOR COUNSEL
--
-- This was written by an engineer. It is structured so a Rwandan lawyer can
-- review it in one pass rather than start over, and the clauses most worth
-- their time are the liability cap, the crisis disclaimer and the
-- cross-border transfer basis. Two things are deliberately left for CODAFRIQA
-- to complete before launch: the registered office address and the company
-- registration number, neither of which should be guessed.

BEGIN;

UPDATE public.policy_documents
   SET retired_at = now()
 WHERE retired_at IS NULL
   AND kind IN ('privacy', 'terms');

INSERT INTO public.policy_documents
  (kind, version, title, summary, body_url, effective_at, material, body_markdown)
VALUES
(
  'terms',
  '2026-09-21',
  'Venttly Terms & Conditions',
  'Adds the provider, Rwandan governing law, liability limits and an indemnity. Requires acceptance again.',
  'https://venttly.com/terms',
  now(),
  TRUE,
$TERMS$
# Venttly Terms & Conditions

_Version 2026-09-21._

These Terms are a binding agreement between you and CODAFRIQA LTD. Please read
section 11 (Liability) and section 10 (Not a crisis service) carefully: they
limit what we are responsible for.

## 1. Who we are

Venttly is operated by **CODAFRIQA LTD**, a company incorporated in the Republic
of Rwanda ("CODAFRIQA", "we", "us"). You can reach us at
[support@venttly.com](mailto:support@venttly.com).

## 2. What Venttly is

Venttly is a space for pseudonymous emotional support. You post under a
pseudonym. We do not ask for your real name, and you should not post it.

Venttly is a platform for what its members write. Except where these Terms say
otherwise, we do not create, endorse or verify that content.

## 3. Who may use it

You must be 13 or older. Members under 18 are placed in a restricted tier with
reduced messaging permissions. Your age is recorded from the date of birth you
supply at signup and is enforced by our servers.

If you are under the age of majority where you live, you confirm that a parent
or guardian has agreed to these Terms on your behalf.

## 4. Your account

Your account is protected by a password and a recovery phrase. **The recovery
phrase is the only off-device copy.** If you lose it and forget your password,
we cannot restore your account — we do not hold anything that would let us.

You are responsible for what is done through your account, and for keeping your
credentials to yourself.

## 5. What you may not do

- Harass, threaten, dox or impersonate anybody.
- Post sexual content involving minors. This is reported to the authorities.
- Encourage suicide or self-harm. Support is welcome; encouragement is not.
- Post another person's private information.
- Evade a moderation decision with a new account.
- Automate access, scrape the service, or attempt to breach its security.
- Use Venttly for anything unlawful under Rwandan law or the law where you are.

## 6. Moderation

Content is checked automatically on submission and may be reviewed by our
moderation team after a report. We may remove content, restrict a feature,
suspend an account, or ban it.

Where we act, we tell you what happened and you may appeal. An appeal is decided
by somebody other than the person who made the original decision.

Reports of illegal content can be sent to
[support@venttly.com](mailto:support@venttly.com) and are acted on without undue
delay.

## 7. Tribes

A Tribe is a community with a Keeper who moderates it. A Keeper sets the Tribe's
rules and may remove or ban members from that Tribe. Keepers act within their
own Tribes only, and remain subject to these Terms. A Keeper is not our agent
or employee, and we are not responsible for how a Keeper runs their Tribe beyond
our own moderation obligations.

## 8. Your content

You keep ownership of what you write.

You grant CODAFRIQA a non-exclusive, worldwide, royalty-free licence to host,
store, reproduce, adapt for technical purposes, and display your content to the
audience you chose, for as long as your content is on the service, and solely in
order to operate it. This licence exists so that we can show your post to the
people you posted it to, and for nothing else.

Deleting content removes it from the service; backups age out on their normal
schedule.

## 9. The service itself

We may change, suspend or discontinue any part of Venttly. Where a change
materially reduces what the service does, we will give reasonable notice unless
the change is needed for security, safety or the law.

Venttly is free to use today. If we introduce paid features, we will say so
before you are asked to pay for anything.

## 10. Not a crisis service

**Venttly is not a medical, clinical, counselling or emergency service.** Nobody
who reads or replies to your posts is acting as your clinician, and nothing on
Venttly is medical advice or treatment.

**If you are in immediate danger, or you are thinking of harming yourself,
contact your local emergency number or a crisis line now.** The app lists
some. Do not wait for a reply on Venttly.

We do not monitor posts in real time and cannot guarantee that anyone — a member,
a Keeper or our moderators — will see any particular message, or see it in time.

## 11. Warranties and liability

Venttly is provided **as is** and **as available**. To the fullest extent
permitted by Rwandan law, we exclude implied warranties of merchantability,
fitness for a particular purpose and non-infringement.

To the fullest extent permitted by law, CODAFRIQA is not liable for:

- what other members post, say or do, on or off the service;
- any decision you take, or do not take, because of something on Venttly;
- loss of data, content or an account, including where a recovery phrase has
  been lost;
- interruption, delay or unavailability of the service;
- indirect, incidental, special or consequential loss, or loss of profits,
  revenue, goodwill or anticipated savings.

Where we are liable, our total liability to you for all claims in any twelve
month period is limited to the greater of the amount you paid us in that period
and **RWF 50,000**.

**Nothing in these Terms limits liability that Rwandan law does not allow to be
limited**, including liability for death or personal injury caused by
negligence, or for fraud.

## 12. Indemnity

You agree to indemnify CODAFRIQA against claims, losses and reasonable legal
costs arising from content you post, your use of Venttly, or your breach of
these Terms — except to the extent the claim arises from our own breach or
negligence.

## 13. Ending your account

You may delete your account at any time from Settings. Deletion removes your
content and personal data from the live service, subject to records we are
required to keep.

We may suspend or terminate an account for a serious or repeated breach of these
Terms, or where we are required to by law. Where we do, we tell you why unless
the law prevents us.

## 14. Governing law and disputes

These Terms are governed by the **laws of the Republic of Rwanda**.

If something goes wrong, contact us first at
[support@venttly.com](mailto:support@venttly.com). We will try to resolve it
within 30 days.

If we cannot, the **courts of Kigali, Rwanda** have exclusive jurisdiction —
except that, where the law where you live gives you the right to bring a claim
in your local courts, that right is unaffected.

## 15. General

If any part of these Terms is found unenforceable, the rest continues to apply.
Our not enforcing a term is not a waiver of it. You may not transfer your rights
under these Terms; we may transfer ours to a company that takes over the
service, on notice to you. These Terms, with the Privacy Policy, are the whole
agreement between us about Venttly. Neither of us is liable for a failure caused
by something genuinely outside our control.

## 16. Changes

If we change these Terms in a way that affects what you agreed to, we will ask
you to agree again before you continue using the service. We keep a record of
which version you accepted and when.
$TERMS$
),
(
  'privacy',
  '2026-09-21',
  'Venttly Privacy Policy',
  'Adds the data controller, legal bases under Law N° 058/2021, your rights, transfers outside Rwanda, and automated moderation. Requires acknowledgement again.',
  'https://venttly.com/privacy',
  now(),
  TRUE,
$PRIVACY$
# Venttly Privacy Policy

_Version 2026-09-21._

## 1. The short version

You are pseudonymous here. We hold as little about you as the service can work
with, and the things people are most afraid of us sharing — what you vent about,
what you say in a message, what you record as a Whisper — are never sent to any
advertising, analytics or third-party AI service.

We do not sell your data. We do not use it for advertising. We do not profile
you to sell to anybody.

## 2. Who is responsible for your data

**CODAFRIQA LTD**, a company incorporated in the Republic of Rwanda, is the data
controller for the personal data described here.

Questions, requests and complaints:
[support@venttly.com](mailto:support@venttly.com).

## 3. What we hold

- **Your account:** pseudonym, display name, avatar, the hash of your password
  and recovery phrase, and your date of birth.
- **What you post:** Vents, comments, Whispers, messages, Tribe activity, and the
  reactions you give and receive.
- **Recovery contacts, if you give them:** an email address you nominate, used
  only to get you back into your account.
- **How you use the app:** the events needed to operate and debug it, and to
  count activity. These pass through a scrubber that strips personal data before
  they leave the device.
- **Security records:** sign-in attempts, device sessions and risk signals, kept
  to protect accounts from takeover.
- **Country:** the country you connect from, at country level only, from your
  connection. We do not store your IP address for this, and we never collect
  precise location.

We do not ask for your real name. If you type it into a post, that is your
disclosure, not ours.

## 4. Why we are allowed to hold it

Under Rwanda's **Law N° 058/2021 relating to the protection of personal data and
privacy**, we rely on:

- **Performance of a contract** — to give you the account and service you asked
  for: your account, your posts, your messages.
- **Consent** — for a recovery email, and for push notifications. You can
  withdraw either at any time, in Settings.
- **Legitimate interests** — to keep the service safe and working: moderation,
  abuse prevention, security records, and debugging. We rely on this only where
  it does not override your rights.
- **Legal obligation** — where the law requires us to keep or report something,
  such as a child-safety report.

## 5. Who we share it with

- **Supabase** — everything listed above. It is our database, and it is where the
  service runs.
- **Resend** — your email address, and only for an email you asked for.
- **Firebase (Google)** — a device token and generic notification text. The
  notification never contains what somebody wrote.
- **Sightengine** — an uploaded image, when image scanning is on, to check
  whether it is unsafe.
- **PostHog** — scrubbed usage events.
- **Sentry** — scrubbed error reports.

Each acts on our instructions as a processor, under contract.

**What none of them ever receive:** the text of your Vents, the contents of your
messages, Whisper audio or transcripts, your recovery phrase, or a real name if
you ever entered one.

We also disclose data where the law requires it, and to protect somebody's life
or safety — most importantly, a report of child sexual abuse material goes to
the authorities.

## 6. Sending data outside Rwanda

The processors above operate outside Rwanda, so your data is transferred and
stored outside the country. Rwandan law allows this where the destination offers
adequate protection or appropriate safeguards are in place; we rely on our
contracts with each processor, which bind them to protect your data and to act
only on our instructions.

You can ask us which country your data sits in.

## 7. Automated moderation

Content is checked automatically when you post it, and automated rules can hide
or remove a post, or restrict an account, without a person looking first.

If a decision affects you, you are told, and **you can ask for it to be reviewed
by a person** — that is what the appeal in the app does. An appeal is decided by
somebody other than whoever made the original decision.

## 8. What is public

Your pseudonym, display name, avatar, bio, and your public activity counts are
visible to anyone. The content of your posts, your mood history and your activity
heatmap are visible only to your connections. Whether you have accepted a policy,
your date of birth, your email and your security records are never public.

## 9. How long we keep it

- **Your account and content:** while your account exists.
- **After you delete your account:** removed from the live service promptly.
  Backups age out on their normal schedule.
- **Security records:** up to 12 months, to investigate account takeover.
- **Moderation and appeal records:** up to 24 months, so a decision can be
  reviewed and so repeated behaviour can be recognised.
- **Records the law requires us to keep**, such as a child-safety report: as
  long as the law requires.

## 10. Your rights

Under Rwandan data protection law you may:

- **access** the personal data we hold about you;
- **correct** it if it is wrong;
- **erase** it — deleting your account does this;
- **object to** or **restrict** processing based on our legitimate interests;
- **withdraw consent** where we relied on it;
- **receive a copy** of the data you gave us, in a portable form;
- **ask for a human review** of an automated moderation decision.

Write to [support@venttly.com](mailto:support@venttly.com). We respond within
the time the law allows, and free of charge.

If you are not satisfied, you may complain to Rwanda's supervisory authority for
data protection, the **National Cyber Security Authority (NCSA)**.

## 11. How we protect it

Data is encrypted in transit and at rest. Access by our staff is limited by role,
requires two-factor authentication, and every privileged action is written to an
audit log that cannot be edited. Passwords and recovery phrases are stored only
as hashes.

If a breach puts your rights at risk, we notify the supervisory authority and,
where the law requires, you.

## 12. Children

Venttly is not for anybody under 13. If we learn an account belongs to a child
under 13, we remove it. Members aged 13 to 17 are placed in a restricted tier.

## 13. Changes

If we change this policy in a way that affects you, we will ask you to
acknowledge the new version before you continue. We keep a record of which
version you acknowledged and when.
$PRIVACY$
);

SELECT public.record_migration(
  '20261036090000', 'policy_documents_2026_09_21'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
