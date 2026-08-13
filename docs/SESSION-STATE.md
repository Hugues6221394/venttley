# Where we stopped — 2026-08-14

Read this first, then `AGENT-COORDINATION.md` (a second agent works security
hardening in this repo concurrently; uncommitted files under `supabase/` and
`.github/` are usually theirs).

**Suite: 158 tests, 0 errors, 0 warnings. iOS and Android both build.**

---

## Resume here

1. **Group invite link is blurred** (`open-issues-2026-08-12.md` section 3) — the
   only reported defect still untouched. The blur presumably guards against
   shoulder-surfing, but it stops the person who needs to *send* the link from
   reading it. The real question is product: reveal on tap, or skip revealing and
   use share-sheet / copy so the token never has to be read aloud.
2. **Four redesigns**, all specified with line numbers:
   `public-profile-redesign-brief.md`, `inbox-friends-redesign-brief.md`, and
   Plug Studio (`open-issues-2026-08-12.md` section 4).
3. **Whispers ranking beyond recency** — the user chose recency + already-heard +
   randomised entry, and explicitly rejected engagement weighting. Do not
   reintroduce it without revisiting that reasoning; on this platform it would
   amplify the most distressing content to the accounts least able to handle it.

---

## The whispers work is done and verified on device

Every item below was checked by driving the simulator with `idb`, not inferred.

| Behaviour | Commit |
| --- | --- |
| Keyset pagination (replaced OFFSET) | `2b0f637` |
| No autoplay from an off-screen branch | `6575bcc` |
| Mini-player for a user-chosen whisper | `78416cf` |
| Mini-player draggable | `170f7d1` |
| Hidden on its own tab; clamped out of the notch | `7877113` |
| Already-heard filter (`whisper_listens`) | `a195356` |
| Randomised first-page entry point | `8a609bd` |
| Reachable mini-player, refresh button, escapable category rail | `e391070` |
| Resume instead of restart on re-entry | `9061865` |
| **Stopped awaiting `play()`** | `c53c1d3` |
| Loading spinner on the transport | `cdc6516` |

Both whispers migrations are applied and live: `20260813200000` (already-heard
filter, never-empty fallback, keyset index) and `20260813210000` (randomised
entry point). Confirmed by `whispers.unheard_rpc_unavailable` dropping to 0.

### The one worth reading about: `c53c1d3`

`just_audio`'s `play()` returns a Future that completes when playback
**finishes**, not when it starts. `startPlayback` awaited it, so it stayed
pending for the entire whisper and silently disabled three things:

* the now-playing handle was never published, so the mini-player never appeared
* `recordWhisperListen` never fired, so the already-heard filter was querying an
  almost-empty table — correct code running on no data
* the next track was never preloaded, so every swipe paid a cold load

No exception, no log. Found by instrumenting each `await` after two wrong
hypotheses. **Lesson worth keeping: when a code path just stops with no error,
suspect an un-completing Future before suspecting logic.**

The user has since confirmed via SQL that listens are recording again.

---

## Known gaps — do not rediscover these as bugs

- **Backgrounding is untested** for both autoplay and the mini-player.
- **The already-heard filter cannot be isolated in the UI** at this data size.
  With ~7 whispers and a randomised entry point, distinct results are consistent
  with either mechanism. Observe `whisper_listens` instead.
- **Member view does not survive a reinstall** — the app opens in Keeper Studio,
  where branch 1 is Spaces, not Whispers. Switch via the Studio drawer then
  "Member feed". This invalidated a test run before it was noticed.
- **Three methods still use offset-range** — `_refreshLikedAndSaved`, `votePoll`,
  `plugByName`. All bounded sets, so not urgent, but the same pattern keyset
  replaced in `listWhispers`.
- **`isRestrictedMinor`** still has zero call sites; other restrictions the
  README claims for that tier (no external links) are enforced nowhere.

---

## Method notes that cost real time

- **Drive the app; do not reason from a screenshot.** Several conclusions this
  session were wrong that way — an "inbox tab is broken" call, a grep false
  positive on `post_card.dart`, an "empty feed" theory.
- **Read each site before editing.** A grep-driven pass on the feed flagged
  `horizontal: 16` as a misaligned inset when it was internal padding of a
  fixed-width card, with nothing to align to.
- **`Positioned` must be a *direct* child of `Stack`.** Wrapped in a
  `LayoutBuilder` it is silently discarded and the child lands top-left — which
  is why the mini-player appeared over the status bar. Flutter logs "Incorrect
  use of ParentDataWidget"; grep for it.
- **State read outside a subscription never updates.** The transport's
  active/inactive branch returned early outside its stream, so it could not react
  to loading finishing.
- **`flutter analyze` can pass while the CFE rejects the build.** Verify with
  `flutter build bundle --debug`.
- The shell's `grep` broke mid-session with a "claude native binary not
  installed" error inside loops, returning silently empty results. Verify with
  Python if tooling looks wrong.

---

## Tooling

```
idb ui tap   --udid <udid> <x> <y>
idb ui swipe --udid <udid> <x1> <y1> <x2> <y2> --duration 0.5
```

Logical points; iPhone 17 is 402x874 @3x. Client at
`~/Library/Python/3.9/bin/idb`, installed under `/usr/bin/python3` (3.9.6)
because `fb-idb` calls `asyncio.get_event_loop()` and raises on 3.12+.

Member-view nav at y=810: Home 48, Whispers 109, Post 170, Friends 232,
Inbox 295, Profile 353. Studio drawer (38, 105); "Member feed" (115, 202).
Whispers refresh button (320, 91).

Swipe the whisper PageView from a clear band — roughly y 500 to 150. Lower starts
land on the transport card, which swallows the drag.

No Docker locally, so migrations cannot be replayed before pushing; CI's
`database` job is the first real execution. The user applies them by hand.
