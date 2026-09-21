# Shipping Venttly to the stores

What is already done, what only you can do, and the order that matters.

Two commands:

```bash
node scripts/check-release-readiness.mjs     # the store blockers, ~1 second
./scripts/release.sh android [--bump]        # AAB for Play Console
./scripts/release.sh ios     [--bump]        # IPA for App Store Connect
```

The readiness check also runs inside `./scripts/check.sh`, so the identifiers
cannot drift back without someone noticing.

---

## Where things stand

| | Android | iOS |
|---|---|---|
| app identifier | `rw.codafriqa.venttly` | `rw.codafriqa.venttly` |
| display name | Venttly | Venttly |
| Firebase config in the build | yes | yes |
| privacy manifest | n/a | yes, in the Runner target |
| push wired end to end | yes | needs the APNs key |
| signing | **needs a keystore** | **needs Apple enrollment** |
| can you build today | **yes** | no |

Android can be submitted this week. iOS cannot start until the Apple Developer
Program membership is active — there is no workaround, and it is the longest
lead time on the project.

---

## Things that are permanent

Read this once before the first upload. Everything below can be changed later
except these.

**The app identifier.** `rw.codafriqa.venttly`, on both platforms. Once an app
is published under an identifier it can never be changed — a different one is a
different app, with no path to carry over users, reviews or ratings. It was
`rw.vently.ventlyApp` / `rw.vently.vently_app` until 20 September, which was a
misspelling of the product name that would have shipped forever.

**The Android upload keystore.** Play binds the app to the first key it sees.
Lose the `.jks` and you lose the ability to update the app at all — not the
password, the file. Back it up somewhere that outlives this laptop.

**The Apple team the app is published under.** An individual membership lists
the app under a person's name; an organization membership lists CODAFRIQA.
Apple supports transferring an app between accounts afterwards, so this is
reversible, but it is paperwork rather than a setting.

---

## Android

### 1. Create the upload keystore — once, ever

```bash
keytool -genkey -v -keystore ~/venttly-upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias venttly
```

It asks for a password and some identity fields. The identity fields do not
appear anywhere users see.

### 2. Point the build at it

Create `android/key.properties` — already gitignored, so the password is not
committed:

```properties
storeFile=/Users/<you>/venttly-upload-keystore.jks
storePassword=<the password you chose>
keyAlias=venttly
keyPassword=<the same password, unless you chose a different one>
```

`android/app/build.gradle` reads this file and **fails the release build if any
of the four is missing**, rather than quietly falling back to debug keys. That
guard was already there; this file is what satisfies it.

### 3. Back the keystore up

Somewhere that is not this machine. A password manager's file attachment, or an
encrypted archive in the company drive. This is the single least recoverable
artefact in the project.

### 4. Build

```bash
./scripts/release.sh android
```

Produces `build/app/outputs/bundle/release/app-release.aab`.

### 5. Play Console

- **play.google.com/console** → Create app → Venttly, $25 one-time
- **App content**: privacy policy `https://venttly.com/privacy`
- **Data safety**: must match `ios/Runner/PrivacyInfo.xcprivacy` and the privacy
  policy. All three have to agree.
- **Content rating**: answer honestly about user-generated content. A social app
  where people discuss mental health will not come out as "Everyone".
- **Target audience**: 13+, matching the Terms
- Upload the AAB → Production (or Internal testing first, which is faster and
  reversible)

---

## iOS

### 0. Apple Developer Program — the blocker

Everything below needs an active membership: the APNs key, the distribution
certificate, TestFlight, and the submission itself. Right now the account shows
*"This resource is only for developers enrolled in a developer program"*, which
is the message for an account with no membership.

Two paths:

| | Organization | Individual |
|---|---|---|
| cost | $99/year | $99/year |
| needs a D-U-N-S number | yes | no |
| realistic wait | 1–3 weeks | 24–48 hours |
| app listed as | CODAFRIQA | your own name |

A D-U-N-S request for CODAFRIQA LTD is already in progress. If it has not
produced a number by **early October**, enrol as an Individual to unblock
shipping — Apple supports transferring the app to an organization account
afterwards.

### 1. APNs key — for push

Only possible once enrolled.

1. **developer.apple.com** → Certificates, Identifiers & Profiles → **Keys** → **+**
2. Name it `Venttly Push`, tick **Apple Push Notifications service (APNs)**
3. **Download the `.p8`. You get exactly one download.** Store it with the
   Android keystore.
4. Note the **Key ID** and your **Team ID**
5. Firebase Console → ⚙️ **Project settings → Cloud Messaging** → the iOS app →
   **APNs Authentication Key** → upload, with the Key ID and Team ID

### 2. Xcode capabilities

Runner target → **Signing & Capabilities**:

- **+ Capability → Push Notifications**
- **+ Capability → Background Modes**, tick **Remote notifications**

### 3. Build

```bash
./scripts/release.sh ios
```

The script refuses with an explanation if there is no distribution certificate,
rather than failing forty lines into a codesign error.

### 4. App Store Connect

- **Privacy answers must match `ios/Runner/PrivacyInfo.xcprivacy`.** That file
  declares: user ID, email address, other user content, photos/videos, audio,
  and crash data. Read it rather than trusting it — the data-type entries are a
  legal statement, and a mismatch between the manifest, the privacy policy and
  the console answers is a rejection.
- **Age rating**: expect the 17+ path for a mental-health app with user content
- **Export compliance**: the app uses HTTPS only, which is the standard
  exemption
- **Screenshots** on every required device size
- **Privacy policy URL**: `https://venttly.com/privacy`

---

## The two things reviewers reject this app for

**No way in.** Venttly is pseudonymous. A reviewer who signs up sees an empty
app and cannot judge it. Put a **demo account in the App Review notes** — one
that already has vents, tribes, a friend and some notifications — with its
handle and password written out.

**Account deletion they cannot find.** Apple requires an app with accounts to
offer in-app deletion. Venttly has it, in Settings, with a grace period before
the purge. Say so explicitly in the review notes and give the path, because a
reviewer who does not find it rejects for its absence rather than asking.

---

## Before you press submit

```bash
./scripts/check.sh
```

Everything must pass, including the device pass. Then:

- `./scripts/release.sh <platform> --bump` — every upload after the first needs
  a higher build number, and both stores reject a repeat silently until the
  upload fails
- commit the bumped `pubspec.yaml`
- confirm the working tree is clean: a build packages what is on disk, not what
  is committed

---

## Known gaps, honestly

**Three failing unit tests** gate a release build behind a typed `yes`. Two are
`schema_ledger_test` — migrations `20261026`–`20261029` do not call
`record_migration()`. One is `premium_member_ui_test`, a layout overflow on a
compact phone, which is the device size a reviewer is most likely to use. Fix
them rather than waving them through.

**Both policy documents still say "pending legal review"**, and they are now
public and linked from both store listings.

**Push has never been delivered to a real device.** The chain is proven as far
as FCM — trigger, `pg_net`, worker, outbox — but zero push tokens exist because
no build with Firebase configured has ever run. The first Android build will
register one.

**`release.sh` does not upload.** The first submission involves decisions — age
rating, privacy answers, export compliance, which build is the one — that belong
to a person looking at the console. Once the shape is known, uploading is a
two-line addition.
