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
