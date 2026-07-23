# Venttly

> Your safe space to connect anonymously. Vent. Heal. Belong.

Venttly is an anonymous social platform for Gen Z emotional expression and
peer support — built with **Flutter** on the client and **Supabase /
PostgreSQL** on the server.

V1 keeps the surface area small and honest. Highlights:

* **Zero personal data.** No email, phone, or real name. Sign-up takes only a
  username + password; the username is mapped to a synthetic auth handle
  (`<username>@id.venttly.app`) that never receives mail.
* **Layered account recovery.** Optional 12-word recovery phrase seals the
  user's password into an AES-GCM blob whose key is derived (Argon2id) from
  the phrase. Blob + salt are stored on the user row and read back pre-auth
  during recovery — no email-reset needed.
* **20 emotional channels** with mood badges, mood filters, and category-
  specific UX (Confessions + Trauma disable DM initiations; Dark Thoughts
  surfaces crisis helplines automatically).
* **Hybrid Tribes.** Tribes are *both* communities (anyone can create, members
  join) *and* creator ecosystems (a Keeper — optionally a verified Plug —
  moderates). Bottom nav: Home · Tribes · Post · Questions · Inbox.
* **Threaded comments** powered by PostgreSQL's `ltree` extension and a GiST
  index for `O(log N)` deep-thread traversal. The client clusters siblings
  chronologically and collapses comments past depth 4 into a "View deeper
  replies" sheet.
* **Private DMs.** Plaintext server-side so reported chats can be reviewed;
  the UI never claims end-to-end encryption.
* **Two-tier safety moderation.** Local keyword scan (self-harm, doxxing/PII,
  hate, harassment, sexual content) feeds a Groq-hosted LLM safety check that
  returns a structured JSON verdict.
* **Member reports.** Any signed-in user can flag a post. Reports are
  write-anyone / read-admin via Row Level Security.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Security hardening — users-table column-level grants, seed wipe | ✅ |
| 1 | Username + password sign-up, 12-word recovery phrase, login + restore | ✅ |
| 2 | Hybrid Tribes (members + keeper), Tribes directory/detail/create, Questions tab | ✅ |
| 3 | Two-tier moderation (Tier-1 local + Tier-2 Groq), member reports table | ✅ |
| 4 | Private DMs (no E2EE claim), realtime chat, moderation on send | ✅ |
| 5 | Profile screen, recovery-phrase reveal, launch readiness | in progress |

## Visual identity

| Color | Token | Role |
| --- | --- | --- |
| `#FDECEF` | Pastel Blush Pink | Light canvas |
| `#D12E65` | Berry Magenta | Primary accent (light) |
| `#4A0E17` | Deep Burgundy | Light typography |
| `#E5A1B4` | Soft Mauve | Light dividers |
| `#120B0D` | Warm Charcoal | Dark canvas |
| `#D96B8A` | Desaturated Berry | Primary accent (dark) |
| `#E0D5D7` | Soft Off-White | Dark typography |
| `#361F23` | Muted Burgundy | Dark dividers |

All cards use `BorderRadius.circular(24.0)` and ship with matching light +
dark themes that meet WCAG 4.5:1 contrast.

## Architecture

```
lib/
├── core/                       # constants, Riverpod providers, DI
├── data/
│   ├── repositories/           # VentlyRepository facade (live + mock)
│   └── services/               # IdentityService, ModerationService, backends
├── domain/
│   └── entities/               # plain, immutable entities
└── presentation/
    ├── router/                 # GoRouter + session-aware redirect
    ├── screens/                # onboarding, feed, tribes, questions, inbox, profile
    ├── theme/                  # VentlyTheme.light/dark + VentlyColors
    └── widgets/                # AnonymousAvatar, PostCard, PromptCard, etc.
supabase/
└── migrations/
    ├── 0001_init_schema.sql    # Core schema, indexes, triggers, RPCs
    ├── 0003_security_hardening.sql
    ├── 0004_username_auth_and_recovery.sql
    ├── 0005_hybrid_tribes.sql
    └── 0006_reports.sql
```

`VentlyRepository` is the single data-layer facade. App runs use live Supabase
by default. The deterministic in-memory `MockBackend` is available only when
explicitly requested for offline development or automated tests, and release
builds reject mock mode.

## Configuration

Only publishable client configuration is passed at build time. Service secrets
belong in Supabase Edge Function secrets and must never enter Flutter builds.

| Variable | Required for | Default |
| --- | --- | --- |
| `SUPABASE_URL` | live backend | repo's project URL |
| `SUPABASE_ANON_KEY` | live backend | repo's publishable key |
| `USE_MOCK_BACKEND` | force the in-memory backend | `false` |

```bash
flutter run

# Explicit offline development only. This is rejected in release builds.
flutter run --dart-define=USE_MOCK_BACKEND=true
```

The authenticated `moderate` Edge Function reads `GROQ_API_KEY` and optional
`GROQ_GUARD_MODEL` from server-only Supabase secrets. Provider failures never
enter the trusted moderation cache.

## Database

Migrations live in `supabase/migrations/`. Validate the full chain and pgTAP
contracts against an empty local database:

```bash
supabase db start
supabase db reset --local --no-seed
supabase test db supabase/tests/database --local
```

Remote changes use the protected `Validate or apply Supabase staging` GitHub
workflow. It refuses an ambiguous target or any staging project ref that
matches the recorded production ref. Production changes require a separate,
explicit approval after staging evidence is reviewed.

Key schema notes:

* `users.recovery_blob` + `users.recovery_salt` — encrypted-password material
  read back pre-auth via the `fetch_recovery_material` SECURITY DEFINER RPC.
* `tribes` + `tribe_members` (migration 0005) replace the older
  `spaces` + `tribes_follows` split. Tribes have a `keeper_id` and an
  `is_private` flag.
* `tribe_directory` view denormalises the keeper's pseudonym, avatar seed,
  and `is_verified` flag so the directory list paints in one query.
* `feed_posts` view exposes `tribe_name` / `tribe_slug` alongside post data
  so the feed never round-trips per row.
* `post_reports` (migration 0006) is write-anyone / read-admin via RLS.

## Safety & compliance

* **COPPA / FTC compliance.** A DOB picker blocks under-13s outright and
  places 13–17 users into the `restricted_minor` safety tier (no DM
  initiation, no external links).
* **No deceptive engagement.** Venttly never generates fake confessions or
  simulated messages to drive upgrades.
* **Two-tier moderation cascade.** Tier-1 keyword scan runs in-process
  (self-harm phrases, phone/email PII, hate, harassment, sexual
  solicitation). Tier-2 is a Groq chat-completion JSON-mode call (skipped
  silently when no key is configured — never fails closed on infrastructure).
  Crisis helplines surface inline whenever self-harm signals fire — and
  self-harm content is *never* hard-blocked.
* **Reported chats.** Moderators can review messages in a reported chat;
  other conversations stay private.

## Running

```bash
flutter pub get
flutter run            # Live Supabase backend
flutter analyze        # zero errors
```

## Tech stack

* **Flutter 3.5+ / Dart 3.5+**
* `flutter_riverpod` for state management
* `go_router` for declarative navigation
* `supabase_flutter` for live data
* `cryptography` for the Argon2id KDF + AES-GCM recovery-phrase blob
* `flutter_secure_storage` for the on-device recovery phrase
* `http` for the Groq moderation call
* `google_fonts` (Plus Jakarta Sans) for warm, organic typography
