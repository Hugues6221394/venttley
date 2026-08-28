# Venttly

> Your safe space to connect under a pseudonym. Vent. Heal. Belong.

Venttly is a pseudonymous social platform for emotional expression and
peer support — built with **Flutter** on the client and **Supabase /
PostgreSQL** on the server.

V1 keeps the surface area small and honest. Highlights:

* **Pseudonymous by default.** A public real identity is never required.
  Username/password accounts need no email or phone; optional contact,
  profile-photo, and coarse-location features collect data only when a member
  chooses the corresponding flow.
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
* **Server-enforced safety moderation.** PostgreSQL sanitizes and evaluates
  every content write even when a modified client bypasses Flutter. It blocks
  contact-detail exposure, hate, targeted harassment, and sexual solicitation;
  self-harm language remains publishable and is tagged for support.
* **Member reports.** Any signed-in user can flag a post. Reports are
  write-anyone / read-admin via Row Level Security.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Security hardening — users-table column-level grants, seed wipe | ✅ |
| 1 | Username + password sign-up, 12-word recovery phrase, login + restore | ✅ |
| 2 | Hybrid Tribes (members + keeper), Tribes directory/detail/create, Questions tab | ✅ |
| 3 | Server-enforced text safety, crisis tagging, member reports table | ✅ |
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
dark themes. Contrast, screen-reader, text-scale, and real-device checks remain
release gates; this document does not claim conformance from tokens alone.

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
admin/
├── app/(dashboard)/            # Next.js staff operations and moderation pages
├── app/api/                    # authenticated admin/auth route handlers
├── components/                 # console shell and shared UI
├── lib/                        # RBAC, Supabase clients, audit, Redis, IP rules
└── proxy.ts                    # session, IP, MFA, and route boundary
supabase/
├── migrations/                 # ordered schema, RLS, RPC, trigger changes
├── functions/                  # authenticated/webhook Edge Functions
└── tests/database/             # pgTAP authorization and behavior contracts
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

The authenticated `moderate` Edge Function validates identity, payload size,
and quota, but production contains no off-platform text classifier. The
authoritative moderation path is the database write guard. Adding any external
content processor requires a separate reviewed code and privacy change.

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

The security-sensitive release sequence, content-free SLOs, kill switches, and
rollback rules are in [`docs/trust-boundary-rollout.md`](docs/trust-boundary-rollout.md).

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
* `reports` (introduced in migration 0006 and consolidated in 0007) accepts
  authenticated member reports and restricts review to authorized staff via
  RLS and role-checked moderation RPCs.

## Super Admin and Trust & Safety console

The separate Next.js console in [`admin/`](admin/) is the internal operating
surface for Venttly. It is not part of the Flutter binary and must be deployed
on a restricted admin hostname. Its full developer handoff—including setup,
route ownership, database dependencies, staff roles, trust boundaries, and the
prioritized production gap—is in
[`admin/README.md`](admin/README.md).

### Implemented today

- Staff roles: `super_admin`, `admin`, `moderator`, `support`, `analyst`, and
  `read_only_auditor`, with route-level access mapping and stricter role checks
  inside privileged database RPCs.
- Report moderation, post removal, suspension/shadow-ban actions, an escalating
  suspension ladder, media review, and dynamic automod rules.
- A cross-surface crisis queue for Vents, Whispers, Tribe messages, DMs, and
  self-harm reports, with careful server-readable-DM wording.
- A super-admin-only CSAM incident ledger, session/IP views, verification
  decisions, and staff-role assignment.
- User and Tribe investigation pages, targeted broadcasts, analytics, cost and
  health views, runtime feature flags/kill switches, and an append-only audit
  ledger.
- Supabase cookie authentication, optional IP allowlisting, TOTP/AAL2 flow,
  and optional shared Upstash rate limiting.

### Production gap

The console builds and is connected to real backend controls, but it must not
yet be described as ready for moderation at million-user scale. Most urgently:

- Route authorization must become fail-closed. An unknown section currently
  falls through for any staff role, and a legacy `/notifications` fanout route
  is not in the role matrix.
- Remaining direct service-role writes must move behind actor-bound,
  transactional RPCs whose audit insert cannot fail independently.
- Production must require MFA, restricted network access, distributed rate
  limits, session revocation, origin/input checks, and adversarial RBAC tests.
- Moderation needs unified cases/evidence across every content surface,
  assignment and persistent SLAs, appeals/second review, reporter-abuse and
  coordinated-abuse tooling, and safe legal-hold workflows.
- Crisis and child-safety operations require qualified legal review,
  jurisdiction-aware global playbooks, trained 24/7 ownership, paging, and
  restore/incident drills. UI instructions are not evidence of compliance.
- Admin browser E2E, complete pgTAP role matrices, sustained concurrent queue
  testing, and user-outcome observability remain release gates.

These gaps are intentionally explicit so a developer assigned only to the
Super Admin system can work from a truthful production backlog rather than
assuming that page coverage equals operational readiness.

## Safety & compliance

* **Age safety.** The server requires a self-reported birth year before core
  social writes, rejects declared ages below 13, and places declared ages
  13–17 into the `restricted_minor` tier (no DM initiation or external links).
  This is an implemented control, not a claim of legal compliance.
* **No deceptive engagement.** Venttly never generates fake confessions or
  simulated messages to drive upgrades.
* **Moderation at ingress.** Database triggers enforce phone/email privacy,
  hate, harassment, sexual-solicitation, staff block rules, and age/account
  state on direct writes as well as RPC writes. Crisis support surfaces when
  self-harm signals fire, and self-harm content is *never* hard-blocked.
* **Server-readable chats.** Row-level policies restrict member access and
  reported chats can be reviewed. Database operators and narrowly scoped
  service processes can access plaintext; Venttly does not claim E2EE.
* **Explicit processors.** When media scanning is enabled, uploaded images are
  sent to Sightengine for a safety verdict. Firebase receives device tokens,
  generic notification copy, and bounded routing IDs—never authored previews.
  Space summaries and production text moderation make no third-party AI call.

## Running

```bash
flutter pub get
flutter run            # Live Supabase backend
flutter analyze        # zero errors
```

Run the staff console separately:

```bash
cd admin
npm ci
cp .env.local.example .env.local
npm run typecheck
npm run build
npm run dev
```

See [`admin/README.md`](admin/README.md) before granting a staff role or
configuring any server-only secret.

## Tech stack

* **Flutter 3.5+ / Dart 3.5+**
* `flutter_riverpod` for state management
* `go_router` for declarative navigation
* `supabase_flutter` for live data
* `cryptography` for the Argon2id KDF + AES-GCM recovery-phrase blob
* `flutter_secure_storage` for the on-device recovery phrase
* `http` for authenticated Edge Function calls
* `google_fonts` (Plus Jakarta Sans) for warm, organic typography
