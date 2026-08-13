# Where we stopped — 2026-08-12, late

Read this first, then `AGENT-COORDINATION.md` (a second agent is working
security hardening in this repo concurrently).

**Suite: 155 tests, 0 errors, 0 warnings. iOS and Android both build.**
All of this session's work is committed. Anything uncommitted in the tree
belongs to the other agent.

---

## Resume here

### ⚠️ Keyset pagination is APPLIED but UNCOMMITTED — and blocked on the other agent

Written, formatted, analyze-clean, 155 tests pass. It is **not committed**,
because all three files it touches also hold the security agent's uncommitted
work (diffs of 366 / 339 / 1276 lines — theirs, not mine). Committing any of them
would sweep their in-flight changes into my commit, and non-interactive git
cannot split hunks by author.

**Two risks while it sits there:** their next write to these files can silently
clobber it, and nobody can review either change cleanly.

**Unblock by having them commit first, then commit mine.** If it is lost, this is
the whole change — about ten minutes to re-apply:

1. `supabase_backend.dart` `listWhispers` — replace `int offset` with
   `DateTime? beforeCreatedAt` + `String? beforeWhisperId`; drop
   `.range(offset, offset + limit - 1)` for `.limit(limit)`; order by
   `created_at desc, whisper_id desc`; when a cursor is present filter
   `or('created_at.lt.<iso>,and(created_at.eq.<iso>,whisper_id.lt.<id>)')`.
   PostgREST cannot express a row-value comparison, hence the spelled-out tuple —
   and the tuple matters, or two whispers sharing a timestamp straddle the
   boundary and one is dropped.
2. `vently_repository.dart` `listWhispers` — same signature swap, pass through.
3. `providers.dart` `WhispersFeedNotifier` — delete `_offset`; `_fetch` takes
   `Whisper? after` and sends `after?.createdAt` / `after?.whisperId`;
   `loadMore` passes `current.last`; `build` passes null; `loadMore` also returns
   early when the list is empty, since there is then no cursor to seek from.

Deriving the cursor from the last row on screen rather than a counter means the
two can never disagree — which is precisely how offset pagination skipped rows
once new whispers shifted the window.

Not yet done: verifying paging depth on device. The dev database has few
whispers, so `loadMore` reaches the end almost immediately and a second page was
never exercised.

The ranking question (item 3) stays open until the user answers it; do not pick
one unilaterally.

### The whispers feed at scale

You asked for random refresh that brings new suggested whispers. Reading the
implementation, there are three separate problems:

1. **Offset pagination will not survive scale.** `listWhispers`
   (`supabase_backend.dart:1690`) uses `.range(offset, offset + limit - 1)` —
   Postgres `OFFSET n LIMIT m`. At offset 100,000 the database scans and discards
   100k rows to return 30. It gets linearly slower the further anyone scrolls.
   Fix: keyset pagination — `WHERE created_at < <cursor> ORDER BY created_at DESC
   LIMIT 30`. Constant cost at any depth; `whispers_feed` already exposes
   `created_at`.
2. **Offset pagination silently skips whispers.** New rows shift the window, so
   page 2 overlaps page 1. `loadMore` (`providers.dart:1319`) dedups by
   `whisperId`, which hides duplicates — but anything that shifted *past* the
   boundary is never shown. Keyset fixes this too.
3. **Refresh cannot bring variety.** Ordering is `created_at DESC` and nothing
   else, so every user sees the same newest whispers in the same order and
   `refresh()` returns an identical list unless somebody posted. This is the
   actual gap behind your request — it is unachievable client-side because there
   is no suggestion signal, only recency.

**(1) and (2) are mechanical — no product decision, pure win. APPROVED: do these
first thing, before anything else in this file.**

**(3) needs your answer.** Pick one:

- **Recency with jitter** — cheapest. Seed a random offset within a recent window
  so refresh reshuffles. Ships in an hour, feels random, is not personalised.
- **Engagement-weighted** — order by a score over `plays_count` / `likes_count`
  with a per-refresh seed. Needs a server-side ordering change, probably an RPC.
- **Per-user recommendation** — `recordWhisperListen` already captures listen
  history, so the data exists. Most work, the only one that is genuinely
  "suggested".

Note: no Docker locally, so migrations cannot be replayed before pushing. CI's
`database` job is the first real execution.

---

## Landed today, verified on device

| Commit | What |
| --- | --- |
| `7877113` | mini-player hidden on its own tab; clamped out of the notch |
| `170f7d1` | mini-player draggable; **fixed a blank-shell regression I caused** |
| `78416cf` | dismissible mini-player for a user-chosen whisper |
| `6575bcc` | no autoplay from an off-screen branch (the reported bug) |
| `f8f37df` | inbox no longer shows a preview as if it were a message |
| `8f21d9b` `6ee9b92` | one 16pt column for the inbox |
| `474ed98` `b2c0560` | server-side age floor + minor DM gating, wired client-side |
| `4904040` `13a3da8` | Android buildable again, plus a CI job so it cannot rot silently |
| `396e1ec` | iOS shared-axis transitions keeping swipe-back |
| `73f3fc3` | PII scrubber stopped mangling UUIDs |
| `e371aba` `0df7623` | five surfaces stopped clipping content behind the nav |
| `420ff4d` | mood distribution ring removed |

### Verified by driving the simulator with idb

- autoplay: silent on Home, plays on entering Whispers, stops on leaving, no
  double-start on return
- mini-player: appears only for a whisper the user swiped to, survives
  leave → return → leave, dismiss removes it, tap-to-return reaches the right
  whisper, **drag works**
- inbox column: headings and avatars share one left edge

### Known gaps, not bugs to rediscover

- **Tap-to-return restarts playback** (0:05 of 7:05) instead of resuming at the
  live position — re-entry re-runs `startPlayback`.
- **Backgrounding** is untested for both autoplay and the mini-player.
- **Member view does not survive a reinstall** — the app comes up in Keeper
  Studio, where branch 1 is Spaces, not Whispers. Cost me one invalid test run.
  Switch via the Studio drawer → "Member feed".

---

## Still open

1. Whispers feed — keyset pagination, then the ranking decision above.
2. `#3` from `open-issues-2026-08-12.md`: the blurred group invite link.
   Untouched. The real question is product: reveal on tap, or skip revealing and
   use share/copy so the token never has to be read.
3. Four redesigns, all specified with line numbers:
   `public-profile-redesign-brief.md`, `inbox-friends-redesign-brief.md`, and
   Plug Studio (`open-issues-2026-08-12.md` §4).
4. `isRestrictedMinor` still has zero call sites; other restrictions the README
   claims for that tier (no external links) are enforced nowhere.

---

## Tooling

`idb` drives the simulator — use it rather than reasoning from a screenshot.
Two conclusions this session were wrong for exactly that reason, and both drag
bugs above were only found by actually dragging.

```
idb ui tap   --udid <udid> <x> <y>
idb ui swipe --udid <udid> <x1> <y1> <x2> <y2> --duration 0.35
```

Logical points; iPhone 17 is 402x874 @3x. Client at
`~/Library/Python/3.9/bin/idb`, installed under `/usr/bin/python3` (3.9.6)
because `fb-idb` calls `asyncio.get_event_loop()` and raises on 3.12+.

Nav positions in member view, y=810: Home 48 · Whispers 109 · Post 170 ·
Friends 232 · Inbox 295 · Profile 353. Studio drawer is (38, 105);
"Member feed" is (115, 202).
