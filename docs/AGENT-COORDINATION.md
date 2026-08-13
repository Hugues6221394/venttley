# Agent coordination

Two agents are working this repo concurrently: one on **security hardening**
(edge-function trust boundaries), one on **platform + UI** (build health,
navigation, spacing, redesigns). Direct messaging between sessions is not
available, so this file is the handshake. Append; do not rewrite others' entries.

---

## ⚠️ Collision risk: `handle_new_auth_user()`

**Read this before touching auth, `public.users` grants, or the signup trigger.**

Migration `20260811010000_enforce_age_floor_server_side.sql` **replaced**
`public.handle_new_auth_user()`. It is committed (`474ed98`) **and already
applied to the live database by hand via the Supabase SQL editor** — so the
deployed function is the new one, not what `0002_rls_and_supabase_integration.sql`
defines.

What it changed, and why it must not be silently reverted:

- `safety_tier` is now **derived server-side** from `birth_year`, never read from
  `raw_user_meta_data`. Previously both came from client-supplied signup
  metadata, so anyone with the shipped anon key could declare themselves
  `'standard'` or omit their age.
- Under-13 **raises** inside the trigger, aborting the `auth.users` insert.
- Implausible birth years are treated as absent rather than trusted.
- Unknown age **fails closed** to `restricted_minor` (matters for Google / phone
  OTP signups that carry no DOB).

A later `CREATE OR REPLACE FUNCTION public.handle_new_auth_user()` that omits any
of this **reopens an under-13 safety risk on a platform serving teens.** If
hardening work needs to touch that function, extend it — start from the version
in `20260811010000`, not from `0002`.

Companions: `20260811020000_restrict_minor_dm_initiation.sql` (adds
`is_restricted_minor()`, `can_initiate_dm()`, and gates `start_chat_room` **after**
its existing-room lookup so open threads keep working) and
`20260811030000_backfill_derived_safety_tier.sql`.

Note `start_chat_room` has now been redefined twice (`0026`, `20260718181541`,
`20260811020000`). Anything redefining it again must keep the minor gate *after*
the existing-room lookup, or a restricted minor loses access to conversations an
adult friend opened.

---

## Shared file: `lib/data/services/supabase_backend.dart`

Both agents have edited it. The UI side added `canInitiateDm()` next to
`canReplyToStory()` (`b2c0560`) — a thin RPC wrapper, no shared state, so it
should merge cleanly. Flagged only so neither side is surprised.

---

## Client-side facts the security work may care about

- `isRestrictedMinor` (`entities.dart`) still has **zero call sites**. The
  capability check is wired (`can_initiate_dm` → `dmInitiationAllowedProvider` →
  `_MessageButton`), but the tier itself gates nothing else. Other restrictions
  the README claims for it — no external links — are enforced **nowhere**.
- The DM CTA is **advisory, not disabled**, on purpose. `can_initiate_dm` is
  false for a restricted minor even when a room exists, while the server refuses
  only *new* rooms. A hard disable strands a minor whose friend opened the
  thread. Please keep that distinction if you touch it.
- `PiiScrubber` no longer mangles UUIDs (`73f3fc3`). Its `_phonePattern` matches
  7+ digits joined by hyphens, which also describes a UUID, so every logged
  `user_id` used to reach Sentry as rubble. Whole-value canonical identifiers now
  pass through; phone detection in free text is unchanged, and a test pins both
  halves. If you add scrubbing, keep that test green.

---

## Build health — do not regress these

Android was **unbuildable** until this session (`4904040`); CI had no Android job
and never noticed. It now needs Gradle 9.1.0 / AGP 9.0.1 / Kotlin 2.3.20, which
is the combination Flutter 3.44.9's own template ships.

- CI pins `flutter-version: 3.44.9` (`quality.yml`). `pubspec.lock` resolves to a
  Dart >=3.10 floor, so an older pin fails at `pub get`.
- `flutter analyze` has passed while the CFE rejected the build. Verify with
  **`flutter build bundle --debug`**.
- Suite is **149 tests, 0 errors, 0 warnings**. Goldens run on the default
  `LocalFileComparator` — exact pixel match, no tolerance.

---

## Verification tooling

`idb` drives the simulator, so neither agent needs the user to tap:

```
idb ui tap --udid <udid> <x> <y>    # logical points; iPhone 17 is 402x874 @3x
```

Client at `~/Library/Python/3.9/bin/idb`, installed under `/usr/bin/python3`
(3.9.6) deliberately — `fb-idb` calls `asyncio.get_event_loop()` and raises on
3.12+, and the system Python is the only compatible one here.

Use it rather than reasoning from a stale screenshot. Two conclusions in this
session were wrong for exactly that reason.

---

## Open, ranked

See `open-issues-2026-08-12.md`. Highest-impact item is the inbox showing a
message the chat does not contain — likely `request_preview` rendered as if it
were a message. That outranks all redesign work.
