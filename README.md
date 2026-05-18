# Vently

> Your safe space to connect anonymously. Vent. Heal. Belong.

Vently is a standalone, zero-PII anonymous social platform for Gen Z emotional
expression and peer support — built with **Flutter** on the client and
**Supabase / PostgreSQL** on the server. Highlights:

* **Zero personal data.** No email, phone, or real name. Onboarding hashes a
  device-side recovery key with a per-device Argon2-style salt and maps it to a
  UUID. The only way back into your sanctuary is your Secret Recovery Key.
* **18 emotional channels** with mood badges, mood filters, and category-
  specific UX (Confessions + Trauma disable DM initiations; Dark Thoughts
  surfaces crisis helplines automatically).
* **Plugz & Tribes.** Verified community keepers post styled "Question of the
  Day" prompts in a heart-shaped Berry Magenta speech bubble. Following a Plug
  joins their Tribe.
* **Threaded comments** powered by PostgreSQL's `ltree` extension and a GIST
  index for `O(log N)` deep-thread traversal. The client clusters siblings
  chronologically and collapses comments past depth 4 into a "View deeper
  replies" sheet.
* **End-to-end encrypted DMs.** Curve25519 + AES-GCM-256, gated behind a
  structured message-request handshake so users can never receive unsolicited
  pings.
* **Voice vents with masking.** Local pitch shift + breathy whisper layer +
  white-noise floor before bytes leave the device.
* **Llama Guard 3 safety cascade.** A fast local keyword tier (self-harm /
  doxxing) feeds into the edge model. Average review latency ≤ 100 ms.
* **Pink-gradient share cards.** Built-in Instagram / Snap / TikTok / WhatsApp
  exporter with QR back-link.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Zero-PII Onboarding, security, DB setup | ✅ |
| 2 | Categorized Feeds, Plugz, Tribes, Q&A prompt cards, comment tree | ✅ |
| 3 | E2EE messaging, voice masking, client-side reporting | ✅ |
| 4 | Theming, glassmorphism, share sheets, polish | ✅ |

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

All cards use `BorderRadius.circular(24.0)`, glassmorphic surfaces use
`BackdropFilter(ImageFilter.blur(10))`, and the entire shell ships with
matching light + dark themes that meet WCAG 4.5:1 contrast.

## Architecture

```
lib/
├── core/                       # constants, providers, DI
├── data/
│   ├── repositories/           # VentlyRepository facade
│   └── services/               # identity, crypto, moderation, voice mask, mock backend
├── domain/
│   └── entities/               # plain, immutable entities
└── presentation/
    ├── router/                 # GoRouter + redirect on session
    ├── screens/                # onboarding, feed, post detail, plugz, inbox, chat, voice, share, profile
    ├── theme/                  # VentlyTheme.light/dark + VentlyColors
    └── widgets/                # AnonymousAvatar, PostCard, PromptCard, MoodChip, GlassCard, VentlyLogo
supabase/
├── migrations/0001_init_schema.sql   # Full schema, indexes, triggers, RPCs
└── seed/seed_demo.sql                # Demo users, Plugz, posts, threads, prompts
```

The `data/` layer is a single `VentlyRepository` facade. By default it talks
to a deterministic in-memory `MockBackend` that mirrors `seed_demo.sql` so
the UI is fully populated without a live Supabase instance.

To switch to live Supabase, build with `--dart-define`:

```
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=ey...
```

## Database

The schema lives in `supabase/migrations/0001_init_schema.sql`. It includes:

* The `users`, `plug_profiles`, `tribes_follows`, `spaces`,
  `space_memberships`, `posts`, `post_polls`, `poll_options`, `poll_votes`,
  `post_likes`, `post_saves`, `posts_comments`, `comment_likes`,
  `chat_rooms`, `chat_messages`, `user_blocks`, `moderation_reports`,
  `plug_prompts`, `prompt_answers`, and `notifications` tables.
* `mood_badge_type`, `user_role_type`, and `safety_tier_type` enums.
* A `path ltree` column on `posts_comments` plus a GiST index for fast
  subtree traversal.
* Atomic count triggers for likes, comments, and tribe counts.
* Two RPC helpers — `create_threaded_comment` and `fetch_comment_tree`.

Deploy locally:

```bash
PGPASSWORD=trigga psql -U postgres -h localhost -d vently_db \
  -f supabase/migrations/0001_init_schema.sql
PGPASSWORD=trigga psql -U postgres -h localhost -d vently_db \
  -f supabase/seed/seed_demo.sql
```

The `fetch_comment_tree(post_id)` RPC sorts results by ltree path + created_at
so siblings cluster naturally and threads display oldest→newest from each
parent. The client computes depth on the fly:

```
indentation_offset(d) = min(d × 12px, 36px)   // capped at depth 3
```

For `d ≥ 4` the client renders a "View deeper replies (N)" button that opens
the sub-thread in a focused bottom sheet.

## Safety & compliance

* **COPPA / FTC compliance.** A neutral DOB picker blocks under-13s outright
  and places 13–17 users into the `restricted_minor` safety tier (no DM
  initiation, no external links).
* **No deceptive engagement.** Vently never generates fake confessions or
  simulated messages to drive upgrades. Premium tiers are aesthetic only.
* **Llama Guard 3 cascade.** `ModerationService` first runs a local
  dictionary scan for self-harm + phone numbers, then the edge model.
  Crisis helplines are surfaced inline whenever self-harm signals fire.
* **Encrypted-payload report path.** When a chat is reported, the most recent
  encrypted block + the local session keys are exported to the moderation
  queue so reviewers can see context without unlocking unrelated chats.

## Running

```bash
flutter pub get
flutter run            # uses MockBackend by default
flutter test           # unit + widget tests
flutter analyze        # zero errors, zero warnings
```

## Tech stack

* **Flutter 3.5+ / Dart 3.5+**
* `flutter_riverpod` for state management
* `go_router` for declarative navigation
* `supabase_flutter` for live data
* `cryptography` for E2EE primitives (Curve25519 + AES-GCM-256)
* `flutter_secure_storage` for encrypted local secrets (recovery key, salt)
* `record` + `just_audio` + `permission_handler` for voice vents
* `screenshot` + `share_plus` for the pink-gradient share-card exporter
* `google_fonts` (Plus Jakarta Sans) for warm, organic typography
