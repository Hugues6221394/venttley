-- The Privacy Policy and Terms counsel approved, effective 1 October 2026.
--
-- Material, so everybody re-accepts. That is not ceremony: the age floor moved
-- from 13 to 16, the processor list now names who holds what and in which
-- country, the transfer section says plainly that no authorisation exists yet,
-- and analytics stopped going to the United States. A person who accepted the
-- September version agreed to a different set of facts.
--
-- Every claim in here was checked against the running system before it was
-- written, and three were false when the check started — the retention periods
-- nothing enforced, the audit log that could be edited, and the age floor.
-- Those were fixed in 20261082090000 rather than softened in the text, which
-- is the order the Master Framework asks for: the capability first, then the
-- promise.
--
-- Regions were verified rather than assumed. Supabase, Sentry and Upstash in
-- Germany; Resend, Firebase, Sightengine and Cloudflare outside the EU for
-- reasons the document states one by one, because "EU-friendly vendor" and
-- "your data is in the EU" are different claims.

UPDATE public.policy_documents
   SET retired_at = now()
 WHERE retired_at IS NULL
   AND kind IN ('privacy', 'terms');

INSERT INTO public.policy_documents
  (kind, version, title, summary, body_url, effective_at, material, body_markdown)
VALUES
(
  'terms',
  '2026-10-01',
  'Venttly Terms of Service',
  'Minimum age is now 16. Adds personas, the recovery-phrase warning, and a stronger statement that Venttly is not a crisis service. Requires acceptance again.',
  'https://venttly.com/terms',
  -- UTC midnight, not Kigali midnight. +02 is 22:00 on 30 September in UTC,
  -- so the stored date read 2026-09-30 while both documents say they take
  -- effect on 1 October. A policy whose recorded date disagrees with its own
  -- text is the kind of detail an audit stops on.
  TIMESTAMPTZ '2026-10-01 00:00:00+00',
  TRUE,
$TERMS$
# Venttly Terms of Service

**Version 1.0 · Effective 1 October 2026**
**Operated by CODAFRIQA LTD, Kigali, Rwanda · Company Code / TIN 155397275**
**Governing law: the laws of the Republic of Rwanda**

These Terms are a legally binding agreement between **CODAFRIQA LTD**, a company
incorporated under the laws of the Republic of Rwanda ("CODAFRIQA", "we", "us"),
and any person who accesses or uses Venttly ("you").

By creating an account or using Venttly, you confirm you have read and agree to
these Terms and to the **Venttly Privacy Policy**. If you do not agree, do not
use Venttly.

---

## 1. What Venttly is

Venttly is a pseudonymous social platform for saying things that are hard to say
elsewhere. Depending on the version available to you it may provide profiles,
personas, Vents and posts, Whispers, Tribes, private and group messaging,
notifications, discovery, reporting and moderation tools, and verification.

Features may be added, changed, suspended or withdrawn. Not every feature is
available to every account, territory or device.

> **Venttly is not a crisis service, a counselling service, or a medical
> service, and it is not a substitute for professional help.** Section 9 says
> what that means in practice. Please read it.

---

## 2. Accepting these Terms

**2.1** By selecting "Create account", "Continue", "I agree" or a similar
control, or by otherwise using Venttly, you confirm you have read and understood
these Terms, agree to comply with applicable law, acknowledge the Privacy
Policy, and accept that Venttly carries content created by other people.

**2.2 Electronic acceptance.** Electronic acceptance is acceptance, to the
extent applicable law permits. We retain a record of it — the version presented,
the date and time, and the account identifier.

**2.3 Consent under data-protection law.** Accepting these Terms is **not** a
substitute for any consent required under data-protection law. Where we rely on
consent to process personal data, we ask for it separately and for a specified
purpose, as the DPP Law requires.

---

## 3. Who may use Venttly

**3.1 Minimum age: 16.** Venttly is for people aged **16 and over**. The service
refuses to create an account for anyone younger, and if we learn an account
belongs to someone under 16 we will restrict or close it and delete the
associated personal data. Members aged 16 and 17 are placed in a restricted tier
with additional protections.

**3.2 What you are telling us.** By using Venttly you represent that you meet
the age requirement, that the information you give is accurate, that you have
the authority to enter into these Terms, and that your use breaks no law that
applies to you.

---

## 4. Your account

You are responsible for keeping your credentials confidential, for taking
reasonable care of your account and device, and for telling us promptly if you
suspect unauthorised access.

You are responsible for activity through your account — except where applicable
law says otherwise, or where the activity resulted directly from our failure to
maintain required security safeguards.

**Your recovery phrase is the only guaranteed way back into an anonymous
account.** We store it only as a hash, which means we cannot read it, cannot
recover it for you, and cannot reset it on request. If you lose it and have set
no recovery email, the account cannot be recovered by anyone, including us.

---

## 5. Identity, personas and pseudonymity

Venttly allows pseudonyms and personas. A persona is shown to other people in
place of your account, and readers cannot link a persona's post back to you.

> **Pseudonymity is not absolute anonymity.** Venttly can still associate
> activity with an account, and we retain what is necessary for security, legal
> compliance, abuse investigation, account recovery and enforcement. Where the
> law requires it, or where it is lawful and reasonably necessary, we may
> disclose relevant information to competent authorities, courts or regulators.

We do not promise that a user can never be identified.

---

## 6. Your content

**"Your Content"** means anything you submit through Venttly — text, images,
video, audio, profile information, messages, comments, posts, Vents, Whispers,
usernames, reactions, reports and feedback.

You remain responsible for it, and you confirm you hold the rights and
permissions needed to submit it.

**You keep ownership of your Content.** By submitting it you grant CODAFRIQA a
non-exclusive, worldwide, royalty-free, sublicensable and transferable licence —
for as long as necessary to operate the service — to host, store, reproduce,
process, format, transmit, display and distribute it as reasonably necessary to
run Venttly, deliver it to the people you intended, keep backups, secure and
moderate the service, investigate abuse, and comply with the law.

We do not acquire ownership. When Content is deleted, this licence continues
only as far as reasonably necessary for backups, legal compliance, security and
dispute resolution, as the Privacy Policy describes.

---

## 7. What you must not post

You must not use Venttly to submit, distribute or facilitate content that:

- is unlawful, or threatens or facilitates violence;
- exploits or sexually abuses a minor, or is child sexual abuse material;
- is a credible threat against a person;
- facilitates terrorism or serious crime;
- impersonates another person in order to defraud or harm;
- is harassment, stalking or targeted abuse;
- unlawfully exposes another person's private information;
- facilitates fraud, scams or identity theft;
- infringes intellectual-property rights;
- distributes malware, or attempts unauthorised access;
- manipulates platform systems or artificially inflates engagement;
- encourages or instructs suicide, self-harm or serious physical harm;
- unlawfully distributes intimate or private material; or
- otherwise creates a significant risk of harm.

We may remove or restrict content that breaches these Terms, the law, or our
Community Guidelines.

---

## 8. What you must not do

You may not reverse engineer the service except where the law permits,
circumvent security controls, scrape or harvest user information without
authorisation, create accounts by automated means, sell or transfer accounts,
interfere with our infrastructure, probe for vulnerabilities without
authorisation, use Venttly for unlawful surveillance, evade enforcement
measures, manipulate moderation, impersonate Venttly staff, or help somebody
else do any of these.

---

## 9. Safety, distress and crisis content

Venttly is a place where people share difficult experiences. It matters that you
understand what the service is and is not.

> **Venttly is not a crisis service, a counselling service or a medical service,
> and it is not a substitute for professional help.**

**We do not monitor communications in real time** and cannot be relied on to
notice that somebody is in danger or to get help on their behalf. If you or
somebody else is at immediate risk of harm, contact local emergency services or
a qualified professional.

Where content suggests somebody may be at risk we may show safety information
and signposting, and we may restrict content that encourages or instructs
self-harm. Nothing in this section obliges CODAFRIQA to intervene in any
particular case, and nothing here is a promise of rescue, treatment, emergency
dispatch or any response time.

**Content posted by other people is not professional advice.** Do not rely on it
in place of advice from a qualified practitioner.

---

## 10. Other people

Venttly connects you to people you do not know. We do not verify every
member's identity, we do not guarantee that what they tell you is true, and we
cannot guarantee that anybody will behave well.

Once you disclose something to another person, we cannot control what they do
with it. Other people can screenshot, copy or record. You interact with others
at your own discretion and risk. We do not become party to a dispute between
users merely because our platform carried the conversation.

Nothing in this section limits obligations that cannot lawfully be excluded.

---

## 11. Moderation

We may — but are not obliged to — review, moderate, restrict, remove or disable
Content. Depending on the circumstances we may remove content, limit its
distribution, restrict functionality, warn, suspend or terminate accounts,
prevent new accounts, preserve information, investigate, and cooperate with
competent authorities.

Content is checked automatically when posted, and automated rules can act before
a person has looked. **We do not guarantee that all prohibited content will be
found or removed**, and the existence of moderation tools does not create an
obligation to monitor every message.

**If a decision affects you, you are told and you may appeal to a human
reviewer**, who will be somebody other than whoever made the original decision.

---

## 12. Reporting

You can report content, accounts or conduct through the tools in the app.
Submitting a report does not guarantee a particular outcome; we assess reports
against our policies, the law, the available evidence and the safety
considerations involved. Reports that are false, malicious or deliberately
abusive may themselves breach these Terms.

---

## 13. Suspension and termination

We may suspend or terminate an account where reasonably necessary to enforce
these Terms, protect people, prevent fraud or abuse, investigate a security
incident, comply with a legal obligation, respond to a lawful request, protect
our rights, address serious or repeated violations, or protect the integrity of
the service.

Where it is reasonably practicable and lawful, we will give notice or a chance
to put something right. Immediate action may be taken where delay would create a
safety, security, legal or operational risk. You may stop using Venttly at any
time.

**On termination** your access may cease immediately and your Content may stop
being publicly accessible. Some information may remain in backups for a limited
period or be retained where the law permits or requires. Provisions that by
their nature should survive termination continue to apply.

---

## 14. Intellectual property

Venttly — its software, interface, branding, trademarks, designs, graphics,
architecture, original content and underlying technology — is owned by or
licensed to CODAFRIQA and protected by intellectual-property law. Except as
these Terms expressly permit, you may not copy, modify, distribute, sell, lease,
sublicense, reverse engineer, commercially exploit or create derivative works
from it.

**Feedback.** If you volunteer a suggestion about Venttly, you grant CODAFRIQA
the right to use it without compensation or obligation. This does not transfer
ownership of separate intellectual property you independently own.

---

## 15. Third-party services

Venttly relies on third-party infrastructure — hosting, authentication,
messaging, analytics and security providers — which operate under their own
terms and privacy policies. We are not responsible for their independent acts or
omissions outside our reasonable control. The providers we use are named in the
Privacy Policy.

---

## 16. Availability

Venttly is provided on an evolving basis. We do not guarantee that it will
always be available or uninterrupted, that every feature will remain, that it
will work on every device, that defects will be fixed immediately, that content
will never be lost, that messages or notifications will always be delivered, or
that the service will be free of security vulnerabilities. Maintenance, updates,
technical failures, cyber incidents, third-party failures and events outside our
reasonable control may affect availability.

---

## 17. Privacy and security

Your use of Venttly is also governed by the **Venttly Privacy Policy**, which
forms part of this agreement.

We apply reasonable technical and organisational measures to protect personal
data and the service. **No internet service can guarantee absolute security.**
Your own device may be compromised independently of Venttly, and you are
responsible for protecting your credentials and device. We handle personal-data
incidents under the DPP Law, including its breach-notification requirements.

---

## 18. Disclaimer

To the maximum extent applicable law permits, Venttly is provided **"as is"** and
**"as available"**. We make no representation or warranty that it will meet every
requirement, be uninterrupted or error-free, be completely secure, remain
permanently available, produce any particular outcome, or be free of harmful
content submitted by other people.

**Nothing in these Terms excludes a statutory right or liability that cannot
lawfully be excluded.**

---

## 19. Limitation of liability

To the maximum extent applicable law permits, CODAFRIQA LTD and its directors,
officers, employees, contractors, affiliates and service providers are not
liable for: indirect, consequential or incidental loss; loss of profits,
business, opportunity, reputation or anticipated savings; loss of data where the
law permits that exclusion; loss arising from interactions between users or from
content submitted by users; the unauthorised conduct of other users; temporary
unavailability; third-party services; or events outside our reasonable control.

Where liability cannot lawfully be excluded, it is limited to the maximum extent
applicable law permits. If paid services are introduced, the monetary limit will
be set out in the terms for those services.

---

## 20. Indemnity

To the maximum extent applicable law permits, you agree to indemnify CODAFRIQA
LTD, its affiliates, directors, officers, employees, contractors and service
providers against claims, losses, liabilities, damages, costs and reasonable
expenses arising from your breach of these Terms, your unlawful use of Venttly,
your Content, your infringement of another person's rights, your fraud or
intentional misconduct, your breach of applicable law, or your misuse of another
person's personal information.

This does not require you to indemnify CODAFRIQA for its own liability to the
extent such an indemnity would be unlawful or unenforceable.

---

## 21. Complaints and disputes

If you have a dispute with us, contact us first and allow a reasonable
opportunity to investigate and resolve it:

**CODAFRIQA LTD**, Akintwari, Kibagabaga, Kimironko Sector, Gasabo District,
Kigali City, Rwanda — **info@codafriqa.rw**

Nothing here prevents you exercising a right available under mandatory law or
approaching a competent regulator. Disputes that cannot be resolved informally
are subject to the jurisdiction of the competent courts of the Republic of
Rwanda, subject to any mandatory jurisdictional rights available to you.

---

## 22. Governing law

These Terms are governed by and interpreted under the laws of the Republic of
Rwanda, except where mandatory provisions of another applicable law require
otherwise.

---

## 23. Changes to these Terms

We may update these Terms. Where changes are material we will give notice
through the app, by email, or by another reasonable method, and the updated
Terms will state their effective date. Continued use after they take effect is
acceptance, where applicable law permits. We keep a record of which version you
accepted and when.

---

## 24. General

**24.1 Severability.** If a provision is found invalid or unenforceable, it will
be interpreted or modified to the minimum extent necessary to make it
enforceable, and the rest continues in effect.

**24.2 No waiver.** Not enforcing a provision is not a waiver of the right to
enforce it later.

**24.3 Entire agreement.** These Terms, with the Privacy Policy and any policy
expressly incorporated into them, are the agreement between you and CODAFRIQA
concerning your use of Venttly.

---

*Venttly is operated by CODAFRIQA LTD, Kigali, Rwanda.*
*Legal and data: info@codafriqa.rw · Technical support: support@venttly.com*
$TERMS$
),
(
  'privacy',
  '2026-10-01',
  'Venttly Privacy Policy',
  'Names every processor and the country it works in, states that messages are not end-to-end encrypted and that pseudonymity is not anonymity, and confirms no transfer authorisation is held yet. Requires acceptance again.',
  'https://venttly.com/privacy',
  -- UTC midnight, not Kigali midnight. +02 is 22:00 on 30 September in UTC,
  -- so the stored date read 2026-09-30 while both documents say they take
  -- effect on 1 October. A policy whose recorded date disagrees with its own
  -- text is the kind of detail an audit stops on.
  TIMESTAMPTZ '2026-10-01 00:00:00+00',
  TRUE,
$PRIVACY$
# Venttly Privacy Policy

**Version 1.0 · Effective 1 October 2026**
**Data Controller: CODAFRIQA LTD, Kigali, Rwanda · Company Code / TIN 155397275**

This Policy explains how CODAFRIQA LTD, as Data Controller for Venttly,
collects, uses, stores, shares and protects personal data when you use Venttly.
It is written around **Law N° 058/2021 of 13 October 2021 relating to the
protection of personal data and privacy** (the "DPP Law"), Rwanda's governing
framework, together with other applicable law.

We have tried to write this so you can actually read it. Where something is
uncomfortable — that your messages are not end-to-end encrypted, that
pseudonymity is not the same as anonymity — we have said so plainly rather than
in language designed to be skipped.

---

## 1. Who we are

**CODAFRIQA LTD**
Akintwari, Kibagabaga, Kimironko Sector, Gasabo District, Kigali City, Rwanda
Company Code / TIN: **155397275**
Data Controller registration: **001/2651/0826**, issued 28 August 2026 by the
Data Protection and Privacy Office, National Cyber Security Authority, and
valid until **27 August 2028**

**Data Protection Officer:** URAYENEZA Dian King — dpo@codafriqa.rw
**Privacy, legal and data-rights requests:** info@codafriqa.rw
**Technical support:** support@venttly.com

---

## 2. The short version

- You are pseudonymous here. We do not ask for your real name.
- We do not sell your personal data, and we do not use it for advertising.
- What you vent about, what you say in a message, and what you record as a
  Whisper are **never** sent to any advertising, analytics or third-party AI
  service.
- Your private messages are **not end-to-end encrypted**. See section 9.
- Pseudonymity is **not** absolute anonymity. See section 10.
- Venttly is for people aged **16 and over**.

---

## 3. What personal data means

Information relating to an identified or identifiable person. Under the DPP Law
this expressly includes location data and online identifiers. For Venttly it may
include your username, email address, account identifier, profile information,
device information, online identifiers, country, communications, activity
records, images, video and audio.

---

## 4. What we collect

**4.1 Your account.** Pseudonym, display name, avatar, the hash of your password
and recovery phrase, your birth year, and your account preferences.

**4.2 What you submit.** Vents, posts, comments, Whispers, messages, Tribe
activity, images, video, audio, reactions and reports.

**4.3 Device and technical information.** Device type, operating system,
application version, unique installation identifiers, crash reports, security
events, timestamps and diagnostic information.

**4.4 Usage information.** Features used, screens viewed, account activity,
moderation events and technical performance. These pass through a scrubber that
removes personal data **on your device**, before they are sent anywhere.

**4.5 Country.** The country you connect from, at country level only, taken from
a header set by our deployment edge. **We do not store your IP address for this,
we never collect precise location, and no IP-geolocation request is made to
another company.**

**4.6 Recovery contacts, if you give them.** An email address you nominate, used
only to get you back into your account.

We do not ask for your real name. If you type it into a post, that is your
disclosure, not ours.

---

## 5. Why we process it, and on what basis

| Purpose | Lawful basis |
|---|---|
| Creating and running your account; delivering messages and content | Performance of a contract |
| A recovery email; push notifications | Consent — withdrawable in Settings |
| Moderation, abuse prevention, security records, debugging | Legitimate interests |
| Child-safety reporting, lawful requests, legal claims | Legal obligation |
| Protecting someone's life or physical safety | Vital interests |

Where we rely on consent, we ask for it for a specified purpose and you may
withdraw it at any time. Withdrawal does not affect processing already carried
out. Where we rely on legitimate interests, we do so only where those interests
are not overridden by your rights.

---

## 6. Who we share it with

Each of these acts on our instructions as a processor, under contract. We have
named them rather than describing them generically, because the DPP Law requires
us to be able to say where your data goes — and because you cannot assess a risk
you are not told about.

| Processor | What it receives | Why | Where it processes |
|---|---|---|---|
| **Supabase** | Everything in section 4 | Our database, storage, authentication and server functions | **Germany** (eu-central-1, Frankfurt) |
| **Sentry** | Scrubbed error reports | Diagnosing crashes | **Germany** (de.sentry.io) |
| **Resend** | Your email address and the message text | Sending an email you asked for | **United States.** Account data, logs, templates and metadata are held in the US; selecting an EU dispatch region changes delivery latency only, not where data is stored |
| **Firebase Cloud Messaging (Google)** | A device token and generic notification text | Delivering push notifications | **United States and Google's global infrastructure.** Messaging has no single project-wide region |
| **Sightengine** | An uploaded image | Checking whether it is unsafe before it is shown | **Global.** Media is processed at the nearest location; confining it to the EU requires an enterprise plan we do not hold |
| **Cloudflare** | Connection metadata for requests to the admin console | Protecting the console from attack | **Global edge network.** Requests are handled at the nearest data centre; confining this to the EU requires Cloudflare's Data Localization Suite, which is not enabled |
| **Upstash** | Request metadata used for rate limiting | Preventing abuse of the admin console | **Germany** (eu-central-1, Frankfurt) |

**PostHog.** Venttly previously sent scrubbed usage events to PostHog's United
States cloud. As of this version that is switched off, and the destination has
been moved to PostHog's **European Union** cloud. Until the EU project is
provisioned, **no usage analytics are collected or sent anywhere at all.**
Events already sent to the US project before this change remain there until
they are deleted.

**In short:** the things that hold what you write — the database, the crash
reports and the rate-limit cache — are in **Germany**. What is handled outside
the EU is edge routing, content delivery and push delivery, together with the
email and image-scanning services named above.

**What none of them ever receives:** the text of your Vents, the contents of
your messages, Whisper audio or transcripts, your recovery phrase, or a real
name if you ever entered one. A push notification never contains what somebody
wrote.

We also disclose personal data where the law requires it, to competent
authorities, courts and regulators, and to protect life or safety — most
importantly, a report of child sexual abuse material goes to the authorities.

We **do not sell personal data.**

---

## 7. Sending data outside Rwanda

The processors above operate outside Rwanda, so your personal data is
transferred and stored outside the country. The DPP Law regulates transfer and
storage abroad and may require authorisation from the supervisory authority.

**We do not currently hold a transfer authorisation from the supervisory
authority.** We have applied for one and the application is in progress. In the
meantime we rely on **contractual safeguards**: a written agreement with each
processor binding it to protect your personal data, to process it only on our
instructions, and to apply security measures appropriate to the risk.

We are telling you this rather than implying an approval we do not have. If the
Data Protection and Privacy Office requires a different basis, or declines the
application, we will change how and where data is processed and update this
Policy accordingly.

You can ask us which country your data sits in, at info@codafriqa.rw.

---

## 8. What other people can see

- **Public to anyone:** your pseudonym, display name, avatar, bio and public
  activity counts.
- **Visible to your connections:** the content of your posts, your mood history
  and your activity heatmap.
- **Never public:** your birth year, your email address, your security records,
  and whether you have accepted a policy.

**Posting under a persona.** A persona is shown to other people in place of your
account: readers see the persona's name and face and cannot link the post back
to you. Venttly itself can still make that link, and will where moderation,
safety or law requires it.

**Anything you publish, you have published.** Once you share something with
another person, we cannot control what they do with it. Other people can
screenshot, copy or record. Do not publish information you need to stay private
— a home address, a phone number, financial details, an identification number,
or information belonging to somebody else.

---

## 9. Messages and private communications

We process information associated with private communications in order to
deliver them, protect the platform, enforce our policies, investigate reports
and comply with legal obligations.

> **Your private messages are not end-to-end encrypted.** They are encrypted in
> transit and at rest, but they remain technically accessible to CODAFRIQA where
> necessary for the purposes described in this Policy. We would rather say this
> plainly than let you assume otherwise.

---

## 10. Pseudonymous activity

Venttly is built to let you take part without giving your name. Appearing
anonymous to another person does **not** mean no information exists that could
technically associate activity with an account or a device. We retain the
technical and security information necessary to protect the service, prevent
abuse, investigate incidents, enforce our Terms and respond to lawful requests.

**We do not represent Venttly as providing absolute anonymity.** If your safety
depends on never being identified under any circumstances, Venttly is not a
sufficient protection on its own.

---

## 11. Automated processing and moderation

Content is checked automatically when you post it. Automated rules can hide or
remove a post, or restrict an account, before a person has looked at it. We also
use automated systems to rank and recommend content, detect spam and suspicious
activity, and identify potential policy violations.

**If a decision affects you, you are told, and you can ask for it to be reviewed
by a person.** That is what the appeal in the app does, and an appeal is decided
by somebody other than whoever made the original decision.

---

## 12. How long we keep it

| What | How long |
|---|---|
| Your account and content | While your account exists |
| After you delete your account | Removed from the live service promptly; backups age out on their normal schedule |
| Security records | 12 months, then deleted automatically |
| Moderation and appeal records | 24 months after the decision, then deleted automatically |
| Records the law requires us to keep, such as a child-safety report | As long as the law requires |

The 12- and 24-month periods are enforced by a scheduled job that runs daily.
Records attached to an open case, or under legal hold, are not deleted while
that remains true — the DPP Law permits longer retention for legal proceedings.

---

## 13. Account deletion

You can delete your account from the account controls, or by contacting us.
Deletion is not instantaneous destruction of every trace: information may remain
briefly in backups, security logs and fraud-prevention systems, or where
immediate deletion is technically impracticable. When the applicable retention
period expires, it is destroyed.

---

## 14. Your rights

Subject to the limits in the DPP Law, you may:

- **access** the personal data we hold about you;
- **be informed** about how it is processed;
- **correct** it if it is wrong;
- **erase** it — deleting your account does this;
- **restrict** or **object to** processing based on our legitimate interests;
- **receive a copy** in a portable form;
- **withdraw consent** where we relied on it;
- **ask for a human review** of an automated decision;
- **complain** to the supervisory authority.

Write to **info@codafriqa.rw**. We respond within the time the law allows and
free of charge. We may need to verify your identity first — otherwise one person
could obtain, alter or delete another person's information. We may refuse or
limit a request where the law permits.

---

## 15. Security

Personal data is encrypted in transit and at rest. Staff access is limited by
role, requires two-factor authentication, and every privileged action is written
to an append-only audit log that cannot be altered or deleted. Passwords and
recovery phrases are stored only as hashes — we cannot read them.

No service connected to the internet can be guaranteed completely secure, and
nothing in this Policy removes a statutory obligation imposed on us.

---

## 16. Personal data breaches

If a breach occurs we respond under the DPP Law and our incident procedure. We
notify the supervisory authority within **48 hours** of becoming aware, with a
fuller report within **72 hours**, and we tell affected people directly where the
breach is likely to create a high risk to them.

---

## 17. Sensitive personal data

You should not submit sensitive personal data unless a feature expressly asks
for it. Sensitive data includes health information, biometric and genetic data,
political opinions, religious or philosophical beliefs, sexual life, and
criminal records. The DPP Law imposes additional requirements on processing it.

> Venttly is a place where people discuss personal experiences, and some of what
> you choose to share may be sensitive by nature. That is your decision, and you
> should assume other people can see, copy and keep it.

---

## 18. People under 18

Venttly is for people aged **16 and over**, and the service refuses to create an
account for anyone younger. Members aged 16 and 17 are placed in a restricted
tier with additional protections.

If we learn that an account belongs to someone under 16, we remove it. The DPP
Law contains specific provisions on children's personal data and parental
responsibility, and we apply them.

---

## 19. Cookies and similar technologies

Venttly may use cookies, SDKs, local storage, device identifiers and similar
technologies for authentication, security, remembering preferences, analytics
and abuse prevention. Where the law requires it, we ask for consent before using
non-essential technologies.

---

## 20. Third-party links

Venttly may link to services we do not control. We are not responsible for their
privacy practices; read their policies before giving them information.

---

## 21. Business transfers

If CODAFRIQA undergoes a merger, acquisition, restructuring or sale of the
Venttly business, personal data may transfer as part of that transaction where
the law permits. Any transfer remains subject to applicable data-protection
requirements.

---

## 22. Changes to this Policy

We may update this Policy. Where a change materially affects how we process your
personal data, we will give notice and, where the law requires, ask for your
consent again. We keep a record of which version you accepted and when. The
version and effective date at the top identify the current one.

---

## 23. Complaints

Please contact us first at **info@codafriqa.rw**. You also have the right to
complain to Rwanda's **Data Protection and Privacy Office**, under the National
Cyber Security Authority — toll-free **9080**, **dpp@dpo.gov.rw**.

---

*Venttly is operated by CODAFRIQA LTD, Kigali, Rwanda.*
*Privacy and data rights: info@codafriqa.rw · Data Protection Officer:
dpo@codafriqa.rw · Technical support: support@venttly.com*
$PRIVACY$
)
ON CONFLICT (kind, version) DO UPDATE
  SET title         = EXCLUDED.title,
      summary       = EXCLUDED.summary,
      body_url      = EXCLUDED.body_url,
      effective_at  = EXCLUDED.effective_at,
      material      = EXCLUDED.material,
      body_markdown = EXCLUDED.body_markdown,
      retired_at    = NULL;

SELECT public.record_migration('20261084090000', 'policies_2026_10_01');

NOTIFY pgrst, 'reload schema';
