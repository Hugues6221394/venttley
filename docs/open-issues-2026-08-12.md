# Open issues — reported 2026-08-12

Three user-reported defects plus one added redesign target. Written at a session
boundary; hypotheses are marked as such and need confirming before any fix.

Ranked by user impact. #1 is fixed; #2 is root-caused but unfixed; #3 is
uninvestigated.

---

## 1. Inbox shows a message that the chat does not contain

**Reported:** "while inbox I can see a message from a friend that says 'Hey' but
when I enter in chats it's empty… I doubt the reliability of the app."

**Confirmed independently.** A simulator capture of the inbox during the same
session shows a row reading `HealingSlow · Hey · 7/15`.

**FIXED — `f8f37df`.** Confirmed by reading the code, not by querying:
`_LastMessageLine` read `room.lastMessagePreview ?? room.requestPreview`, and
`requestPreview` is a column `start_chat_room` writes on `chat_rooms`, not a row
in `chat_messages`. A room with no messages therefore rendered text nobody had
sent, and the empty chat was correct all along.

**Nothing was ever lost.** Delivery, storage and retrieval were all working — the
list was displaying a field that is not a message. Worth telling the user
explicitly, since they said this made them doubt the app's reliability.

Requests already have their own branch a few lines above ("Wants to chat"), so
that fallback was only ever reached by non-request rooms, where a request preview
has no meaning. Removed; such rooms now fall through to the existing "Tap to open
chat".

Left deliberately: the request *sheet* still renders `requestPreview` in italic
quotes, where it genuinely is the sender's note. The search filter
(`inbox_screen.dart:271`) still matches on it — harmless, though it means you can
now match text the row does not display.

`premium_chats`, the inbox golden, passed unchanged — evidence the fix is narrow.

Disappearing messages (`set_room_disappearing`) were considered as an alternative
cause and are **not** implicated; the fallback fully explains the symptom.

---

## 2. Whispers autoplay on login

**Reported:** audio starts by itself after signing in. Desired behaviour, in the
user's words: playback only while on the Whispers page; when navigating away a
short widget follows you where applicable and can be dismissed so it does not
drag you back.

**Root cause (investigated 2026-08-12): the off-screen branch is mounted and
plays.**

There is no rogue `play()` call. Every one was checked:

- `whisper_audio_preview.dart:82` — behind `_toggle()`, a user tap. Clean.
- `popular_whispers_rail.dart`, `whisper_carousel_tile.dart` — no `play()` at all,
  so the home rail is **not** the trigger (the earlier guess was wrong).
- `whisper_player.dart:27` — the loop handler, replaying on completion when loop
  is enabled. Legitimate.
- `whispers_screen` calls `loadAndPlay` on page change, which is correct *on that
  screen*.

`StatefulShellRoute.indexedStack` renders its branches into an **`IndexedStack`**,
and `IndexedStack` builds *every* child into the tree — it only controls which is
visible. So once the shell exists, `whispers_screen` (branch 1) is constructed and
mounted while Home is on screen. Its `PageView` settles on page 0, `loadAndPlay`
fires, and audio plays from a screen the user never opened.

That matches the report precisely: it happens "whenever you log in" because that
is when the shell is first built — no session hook involved.

Corroborating: `providers.dart:358` already lists "no whisper autoplay" as a
data-saver behaviour. Someone knew autoplay fired too eagerly and gated it behind
a setting instead of fixing the trigger.

**Fix shape:** make playback conditional on the branch being visible — gate
`loadAndPlay` on `navigationShell.currentIndex`, or use `TickerMode` /
a visibility check so an off-screen branch never starts audio.

**Verify all of these before calling it done**, because the failure mode of a
careless fix is whispers that never play at all — worse than the bug:

- audio stops when switching away from the Whispers branch
- it does not double-start when returning to it
- backgrounding and resuming does not restart it
- the mini-player, once added, is the only thing that continues playback off-branch

**Touches `app_router.dart` / `HomeShell`** — contested with the security agent's
in-flight work as of 2026-08-12. Read `AGENT-COORDINATION.md` first.

**Pieces that exist:** `WhisperPlayerController` (`whisper_player.dart`),
`whisper_audio_preview.dart`, `whisper_carousel_tile.dart`,
`vently_audio_session.dart`.

**Shape of the fix:** one global owner of "what is playing", never started from a
list-item build; plus a dismissible mini-player mounted in `HomeShell` so it can
persist across branches. `HomeShell` already floats the nav pill, so it is the
natural host — mind `HomeShell.navClearance` if the mini-player stacks above it.

Worth stating plainly: unrequested audio on a mental-health app is worse than a
cosmetic bug. Someone may open this in public, or beside a sleeping partner.

### Mini-player — design, and why it is not additive

**Do not bolt this onto the current exit path.** `6575bcc` makes leaving the
Whispers branch *pause* (`didChangeDependencies` -> `_pauseOffStage`), verified on
device. A mini-player means leaving must instead **keep playing and hand off**, so
this rewrites that path. Built carelessly it reintroduces the original bug —
audio from a screen nobody opened.

The distinction to preserve: **playback continues only when the user explicitly
started it.** Autoplay-on-page-settle must still die with the branch; a whisper
the user chose to listen to may follow them. Today those are the same code path
(`_onPageChanged` -> `startPlayback`), so they have to be separated first.

Suggested shape:

1. **Move ownership out of the screen.** A `Notifier` holding
   `{whisperId, title, author, isPlaying, startedByUser}` — `whispers_screen`
   reports into it rather than owning `WhisperPlayerController` lifecycle.
2. **Branch exit consults `startedByUser`**: autoplayed -> pause as now; explicitly
   started -> keep playing and surface the mini-player. That keeps the verified
   behaviour for the case that caused the complaint.
3. **Host it in `HomeShell`**, stacked above the nav pill — mind
   `HomeShell.navClearance`; the mini-player's own height must be added to what
   scroll views reserve, or it re-creates the occlusion bug fixed in `e371aba`.
4. **Dismiss must stop playback**, not just hide the widget. The user's words:
   "you can cancel it when you don't want to go back to the whisper audio."
5. **Tapping it returns to that whisper** — `goBranch(1)` plus seek to the live
   position, not a restart.

Re-run the whole checklist above afterwards, plus: dismiss actually silences;
mini-player does not appear for autoplayed whispers; no double audio when
returning to the branch while it is showing.

Backgrounding remains untested from the `6575bcc` verification and is easiest to
cover at the same time.

---

## 3. Group invite link is blurred, so nobody can be invited

**Reported:** users cannot invite friends via "Invite Link" because it is
blurred for privacy/safety.

**Not investigated.** Owning files: `group_invite_screen.dart`,
`group_chat_settings_screen.dart`. The deep link is parsed by
`groupInvitePathFromUri` in `main.dart` (`venttly://group-invite/<token>`, max
128 chars, strictly validated).

**The real question is a product one:** the blur presumably guards against
shoulder-surfing a token. But an invite token is single-purpose and revocable,
so hiding it from the person who needs to send it defeats the feature. Options:
reveal on explicit tap, or skip revealing entirely and offer share-sheet /
copy-to-clipboard so the token never has to be read aloud. The second is both
safer and better UX.

---

## 4. Plug Studio needs the same design work

Added to the redesign scope alongside the public profile, inbox and friends
page. **File:** `lib/presentation/screens/home/keeper_home_screen.dart` (2,199
lines) — branch 0 of the shell when `isKeeper && !keeperMemberView`.

Observed live: a "Control Center" gradient hero with a prompt nudge and a
*Manage Tribe* CTA, then "Tribe overview" with a 2×2 stat grid (Members,
Reports, 24h vents, Tribe health) and a *Member feed* link.

Already fixed there: the bottom row of stat cards was clipped behind the
floating nav — it reserved 28px against the pill's ~108 (commit `e371aba`, now
`HomeShell.navClearance`).

Worth carrying in: this is an operator console, not a social feed. Keepers come
to answer "is my tribe healthy and is anything on fire?" — so reports and
moderation queues deserve more weight than a health percentage, and the same
question applies here as to the profile's stat band and the removed mood ring:
**does each number mean something the team actually maintains?** A "55% Tribe
health" figure nobody can explain is the mood ring in a different costume.

---

## Tooling note

`idb` is installed and working, so a session can now drive the simulator itself
instead of asking the user to tap:

```
idb ui tap --udid <udid> <x> <y>     # logical points, iPhone 17 is 402x874 @3x
```

Client lives at `~/Library/Python/3.9/bin/idb` — installed under
`/usr/bin/python3` (3.9.6) on purpose, because `fb-idb` calls
`asyncio.get_event_loop()` and raises on Python 3.12+. `idb-companion` came from
the `facebook/fb` tap, which Homebrew 6 required `brew trust` for.

Use it. Two conclusions this session were wrong from reasoning off a stale
screenshot instead of driving the app.
