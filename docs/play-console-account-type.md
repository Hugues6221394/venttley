# Why Venttly must publish from an Organisation account

**Decision:** Venttly ships from a Google Play **Organisation** account registered to
CODAFRIQA LTD. We are waiting on D-U-N-S verification to complete before the first
production release.

**Status:** blocked on D-U-N-S. Everything else is moving in parallel.

---

## The short version

Google treats personal and organisation developer accounts differently, and the
difference is not cosmetic. A personal account cannot release to production until it
has run a closed test with **at least 12 testers for 14 continuous days**. An
organisation account has no such requirement.

That single rule is the reason for this decision. It is an automated gate — there is
no appeal, no expedite, and no support ticket that removes it.

---

## The comparison

|                                          | Individual                     | Organisation                 |
| ---------------------------------------- | ------------------------------ | ---------------------------- |
| What Google verifies                      | A person's government ID       | The company, via **D-U-N-S** |
| 12 testers × 14 continuous days           | **Required**                   | Not required                 |
| Public developer name on the listing      | A person's name                | **CODAFRIQA LTD**            |
| Time from upload to production            | 14 days minimum, then review   | Review only                  |
| Can it be changed later?                  | **No**                         | **No**                       |

That last row is why this is worth writing down.

---

## You cannot change your mind later

Google does not support converting a developer account between types. Choosing
Individual is not a shortcut that can be undone once D-U-N-S arrives — it is a
permanent property of the account.

The only route from one to the other is to register a **second** developer account
(another $25, another verification) and then transfer the app between them, which
requires both accounts to be fully verified first. That takes longer than simply
waiting for D-U-N-S, and it means the app's history, reviews and install base move
through a process that can go wrong.

**Doing it right the first time is the fast path.** It does not feel like it this
week.

---

## Why it matters beyond the deadline

The tester gate is the urgent reason. These are the lasting ones.

**The listing says who built it.** An individual account shows a person's name as the
developer. An organisation account shows CODAFRIQA LTD. For an app handling the
mental health of people as young as 13, in a market where users reasonably ask who
is behind the software, "CODAFRIQA LTD" is not a branding preference — it is part of
being trustworthy.

**Continuity.** A personal account is tied to one individual. If that person leaves,
loses access, or their Google account is compromised, the company's app goes with
them. An organisation account can have multiple users with defined roles, which is
the only arrangement that survives a team changing.

**What it unlocks.** Several Play features assume an organisation: managed publishing
workflows, some commerce and subscription capabilities, and clean access control
across a team. We do not need all of them today, but we should not have to migrate
accounts to get one of them in a year.

**Policy scrutiny.** Apps in sensitive categories — health, minors, user-generated
content — attract more review. Venttly is all three. A verified company behind the
listing is the position we want to be reviewed from.

---

## What D-U-N-S is, and how to get it

A D-U-N-S number is a nine-digit identifier issued by Dun & Bradstreet that
identifies a business. It is free.

1. Apply through Dun & Bradstreet for **CODAFRIQA LTD**, or via the link Google
   surfaces during organisation verification.
2. Use the company's **exact registered legal name and address**. A mismatch against
   the Rwanda company register is the single most common cause of rejection and
   restarting costs more time than getting it right.
3. Standard issuance is **up to two weeks**. Expedited processing exists in some
   regions for a fee.
4. Once issued, enter it in Play Console. Google then verifies the details against
   D&B's record — so the two must agree.

**Check first whether CODAFRIQA LTD already has one.** Companies are sometimes
assigned a D-U-N-S without applying, and if one exists this step may already be done.

---

## What this costs us, honestly

A production release is not available until D-U-N-S verification completes. Best case
that is a few days; plan for two weeks.

Worth knowing: **a first release on any new developer account is typically reviewed
for three to seven days.** So even with an instantly verified organisation account,
"publicly live tomorrow" was never available. The D-U-N-S wait overlaps a delay we
would have had regardless.

---

## What is not blocked

Nothing in the engineering or content path depends on account type. All of this
proceeds now, and none of it is wasted:

- Store listing: title, descriptions, categorisation
- Graphics: 512×512 icon, 1024×500 feature graphic, phone screenshots
- Data safety declaration
- Privacy policy published at a public URL
- Content rating questionnaire
- Signed release bundle, built and verified
- **Internal testing track** — up to 100 testers, available immediately, no waiting
  period, installable from the real Play Store app within minutes of upload

That last point matters for anyone who needs to *see* Venttly on Play before the
public launch. An internal testing link installs through the Play Store and behaves
exactly like the finished product. For a demo, a review, or an investor, it is
indistinguishable from the real thing.

---

## What we are asking the team to do

| Who              | What                                                                 | When       |
| ---------------- | -------------------------------------------------------------------- | ---------- |
| Whoever holds the company registration | Check whether CODAFRIQA LTD already has a D-U-N-S; if not, apply today | Immediately |
| Play Console owner | Confirm the account type and creation date in Settings → Developer account | Immediately |
| Product / content  | Store listing copy, screenshots, privacy policy URL                  | This week  |
| Engineering        | Signed release bundle, data safety answers, internal testing upload   | This week  |

The D-U-N-S application is the only item with a clock we do not control. Everything
else can be finished while it runs.

---

## One thing to verify, not assume

Google's requirements change. Before acting on this document, confirm the current
rules in **Play Console → Release → Production**, which states any outstanding
requirement on the account directly, and on Google's developer registration help
pages.

The specific thing to look for is whether the account shows a **"complete 14 days of
closed testing with 12 testers"** requirement. If that text appears, the tester gate
is active.
