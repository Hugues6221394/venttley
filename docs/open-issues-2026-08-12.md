# Open issues — reported 2026-08-12

Three user-reported defects plus one added redesign target. Written at a session
boundary; hypotheses are marked as such and need confirming before any fix.

Ranked by user impact. Fix #1 first — messaging correctness outranks everything
visual in this list.

---

## 1. Inbox shows a message that the chat does not contain

**Reported:** "while inbox I can see a message from a friend that says 'Hey' but
when I enter in chats it's empty… I doubt the reliability of the app."

**Confirmed independently.** A simulator capture of the inbox during the same
session shows a row reading `HealingSlow · Hey · 7/15`.

**Hypothesis (untested): the preview is not a message.**
`start_chat_room(p_target, p_preview, p_origin_post_id)` writes `p_preview` into
`chat_rooms.request_preview` — a column on the *room*, not a row in
`chat_messages`. If `_LastMessageLine` (`inbox_screen.dart:1313`) falls back to
`request_preview` when a room has no messages, the list advertises text that was
never sent, and the chat is correctly empty because nothing exists.

If that holds it is a **display bug, not data loss** — nothing is being lost,
the list is lying. Still serious: it makes the app feel unreliable, which on this
product is the whole asset.

**Confirm first:** does that room have any `chat_messages` rows?

```sql
SELECT count(*) FROM public.chat_messages WHERE room_id = '<room>';
SELECT room_status, request_preview FROM public.chat_rooms WHERE room_id = '<room>';
```

Zero messages + non-empty `request_preview` confirms it.

**Rule out:** disappearing messages. `set_room_disappearing` exists and the
inbox renders "Disappearing messages turned off" on one room, so expired message
rows alongside a surviving denormalised preview would look identical and needs a
different fix.

**Then decide the contract:** either the inbox never shows `request_preview` as
if it were a message (render it as "wants to connect" instead), or accepting a
request materialises the preview into a real first message. The first is
honest and smaller.

---

## 2. Whispers autoplay on login

**Reported:** audio starts by itself after signing in. Desired behaviour, in the
user's words: playback only while on the Whispers page; when navigating away a
short widget follows you where applicable and can be dismissed so it does not
drag you back.

**Likely cause:** not login itself. The home feed renders a *Popular Whispers*
rail (`popular_whispers_rail.dart`) and the feed is the post-login landing
route — so a carousel tile or preview autoplaying on build is the more probable
trigger than any session hook.

**Pieces that exist:** `WhisperPlayerController` (`whisper_player.dart`),
`whisper_audio_preview.dart`, `whisper_carousel_tile.dart`,
`vently_audio_session.dart`.

**Shape of the fix:** one global owner of "what is playing", never started from a
list-item build; plus a dismissible mini-player mounted in `HomeShell` so it can
persist across branches. `HomeShell` already floats the nav pill, so it is the
natural host — mind `HomeShell.navClearance` if the mini-player stacks above it.

Worth stating plainly: unrequested audio on a mental-health app is worse than a
cosmetic bug. Someone may open this in public, or beside a sleeping partner.

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
