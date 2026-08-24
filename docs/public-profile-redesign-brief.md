# Public profile — brief and state

**Target file:** `lib/presentation/screens/friends/friend_profile_screen.dart`
(1,974 lines) plus `lib/presentation/widgets/profile_stats_panel.dart` (281).
Route: `/user/:userId`, plus `/user/:userId/stat/:statKind`.

## Goal

Modern, professional, genuinely attractive, smooth — with care on the details.
This is the screen someone reads to decide whether to open up to a stranger on
a platform about trauma and self-harm. Restraint reads as trustworthy here;
density and ornament read as a growth product.

**The stats are the point.** People add people by seeing how active they are,
and the stats are how that shows. They can move anywhere, but they stay
prominent. (Explicit user direction, 2026-08-15, correcting an earlier plan
that demoted them in favour of mutuals.)

## What landed — 2026-08-15

Verified on the simulator against three real profiles: a friend
(`@GoldenHour`), a stranger with activity (`@HopeDealer`), and a stranger with
none (`@GlassHeart`).

### `faeaa04` — one stats system, not two

The screen opened with two stat blocks stacked back to back:

* `_StatsBanner` in the hero — Connections / **Posts** / Hugs, a tinted card
* `ProfileStatsPanel` "Overview" — Connections / **Vents** / Tribes as three
  large iconned cards, then Comments / Reactions / Badges / Streak as four
  cramped chips

Connections appeared **twice with the same number**. "Posts" (`postsTotal`,
vents + whispers) sat directly above "Vents" (`vents`), so the same person
appeared to have two different post counts — 3 and 2 for `@HopeDealer`. Neither
block deferred to the other: same tinted treatment, no hierarchy. And at
four-across the chips truncated "Reactions received" to "Reactions r…".

Now:

* **Hero band** (`_StatsBanner`, line 889) — Connections · Vents · Tribes. A
  hairline band, not a filled card, so it reads as part of the identity block.
  **Each column is tappable** and pushes the same `/stat/` route the grid does.
  They used to be inert, which meant a 22pt number that did nothing sat
  directly above an identical one that did.
* **`ProfileStatsPanel`** — "Activity": Reactions · Comments · Streak · Badges,
  one card design, 2×2, wrapped in `IntrinsicHeight` so the streak card's
  optional "best N" line does not leave its neighbour short.

No number appears in both places. `postsTotal` and `hugsReceived` are no longer
surfaced here — hugs are a subset of reactions received, and showing both
invited "why is Reactions 15 but Hugs 0?".

### `faeaa04` — two defects found while verifying

* **Avatar shape.** The hero ring is circular, but `ProfileAvatar` only clips
  *uploaded photos* to an oval — the anonymous fallback stays the squircle the
  feed uses. Its corners pushed past the ring on every profile without a photo.
  `_HeroAvatar` now wraps it in `ClipOval`.
* **The wall of zeros.** A new account rendered the Activity grid as four 0s —
  the block meant to answer "is this person worth connecting with" answered
  emphatically no. When every stat in it is zero the grid is replaced by a
  short `_JustGettingStarted` line; a lone zero among real numbers is muted
  rather than set in full-weight ink.

### `e7e451b` — the stats were gated, and wrong (2026-08-16)

Found by reading `user_profile_summary` while chasing a report that
@GoldenHour's profile said "1 comment" while one of her vents showed 5.

**That report was not a bug.** The profile counts replies the person *wrote*;
the post counts comments it *received*. Both numbers were right. The label was
wrong — "Comments" next to a number reads as comments *on* their posts. It is
"Replies" now, matching the subtitle that was already there, and the detail
screen says so explicitly (and no longer renders "1 replies given").

Reading the SQL to check that turned up four real defects:

* **Gated.** The RPC returned only `vents` and `active_tribes` to non-friends;
  comments, reactions, badges and streak sat inside the friends/self branch. So
  a stranger's Activity grid rendered them as **zero — not "unknown", zero**.
  Every stranger looked like a dead account no matter how active they were, on
  the one screen whose job is to make someone worth adding. Counts now go to
  every viewer; post content, mood distribution and the 90-day heatmap stay
  friend-gated.
* `comments` counted rows with no regard for `deleted_at`, while `vents` on the
  adjacent line filtered it. Migration `0101` had already settled that live
  means `deleted_at IS NULL`, so the profile was the last place in the app
  disagreeing with every thread in it.
* `comments` ignored `whisper_comments` entirely, though the detail screen
  tells the reader the number covers "vents and whispers".
* `reactions_received` summed likes on posts only, so a like on a reply someone
  wrote was support they never got credit for.

Migration: `20260816090000_public_profile_stats_visible_and_live.sql`, applied
and verified on device — @GlassHeart went from four zeros to Reactions 12 ·
Replies 2 · Streak 1 · Badges 1.

**This also corrected a false claim shipped in `faeaa04`.** The
`_JustGettingStarted` empty state asserted "@X has not picked up reactions,
replies or badges yet" — which for a stranger was the client mistaking
"withheld" for "none". Reworded to describe the block, not the person.

### Bio — verified, not changed

`user_profile_summary` has returned `bio` to every viewer since
`20260727131446`; no earlier version of the RPC returned it at all. Neither
`_profileFromJson` nor `_Hero` gates it on friendship, and `copyWithConnections`
uses `bio ?? this.bio`, so the RLS-blocked direct users read cannot clobber the
RPC's value. Confirmed on device: no `profile.summary_missing_bio_column`
warning fires, so the key is present and the accounts simply have empty bios.

That warning is new (`_profileFromJson`) and exists because an absent `bio` key
and a present-but-null one look identical from the outside — the first is an
unapplied migration, the second is a user who has not written a bio, and
silently rendering nothing for both is how a whole feature disappears.

### `aee667c` — the top of the page once it scrolls

The app bar is transparent over an extended body so the banner runs to the top
of the screen. Right at rest, wrong in motion: content slid under the status
bar and behind the floating back chip. On the friend view "Vibe level 1"
rendered directly under the back arrow.

`_FriendProfileScreenState._scrim` fades a blurred scrim in over the first 80pt
of scroll. **Filtered to `n.depth == 0`** — the Vents tab has its own
`ListView`, and its offset says nothing about whether the header moved.

Also softened the pinned `TabBar` divider; M3 defaults it to `outlineVariant`,
a hard near-black rule across a very soft palette.

## Current structure

Sliver order — **stranger**: `_Hero` → `[_BlockedNotice]` → `ProfileStatsPanel`
→ `_StrangerCallout` → `[_MutualsSection]` → `navClearance`.

**Friend**: `_Hero` → `[_BlockedNotice]` → `ProfileStatsPanel` → `_VibeLevelBar`
→ `[_MutualsSection]` → pinned `SliverAppBar` TabBar → `SliverFillRemaining`
holding the `TabBarView`.

| Widget | Line |
| --- | --- |
| `FriendProfileScreen` / `_FriendProfileScreenState` | 32 / 41 |
| `_FriendProfileBody` | 160 |
| `_VentsTab` / `State` | 259 / 267 |
| `_AchievementsTab` / `_ActivityTab` | 376 / 402 |
| `_StreakCard` / `_VibeLevelBar` | 429 / 475 |
| `_Hero` | 538 |
| `_HeroBanner` / `_BrandBanner` | 693 / 742 |
| `_HeroAvatar` | 765 — **tap-to-preview + semantics label, keep both** |
| `_MetaPill` | 846 |
| `_StatsBanner` | 889 |
| `_MessageButton` / `State` | 969 / 977 — dimmed for restricted minors; tap stays enabled on purpose |
| `_Highlights` / `_HighlightCard` | 1090 / 1121 |
| `_MutualsSection` | 1192 |
| `_StrangerCallout` | 1286 |
| `_BlockedNotice` | 1346 |
| `_SectionTitle` / `_NotAvailable` | 1380 / 1401 |
| `_ActivityHeatmap` | 1435 (+ `_HeatmapCell` 1607, `_HeatmapDot` 1614) |
| `_WhispersSection` / `_QuestionsSection` | 1672 / 1721 |
| `_WhisperMiniCard` | 1765 |
| `_TribesSection` | 1868 |

Line numbers at `aee667c`. Re-derive before trusting them — this table has been
wrong twice.

A mood distribution ring used to sit between the stat band and the tabs,
removed in `420ff4d` because mood changes daily and nobody maintains the
aggregate — it presented noise with the authority of a statistic. The hero's
*current mood* pill was deliberately kept: a self-declared mood right now is a
different claim from an inferred trend.

## Constraints — these are real, do not rediscover them

1. **`HomeShell.navClearance`** is the bottom space every surface scrolling
   under the floating nav must reserve. This screen uses it (`b7526c9`); six
   other screens still use magic 110/116/120 and should be folded onto it.
2. **Alignment is not this screen's problem.** Every section inset is already
   20. The outliers found by grep (`_MetaPill` 11, `_MessageButton` 14,
   `_WhisperMiniCard` 8, heatmap cells 2) are all *internal* component padding
   with nothing to align to. `VentlyTokens` is referenced zero times here, as
   in the feed. Measure before "fixing" spacing.
3. **`_HeroAvatar` carries an accessibility contract.** Its semantics label
   `'View @${profile.pseudonym} profile photo'` is asserted by
   `test/tribe_reliability_test.dart`, anchored on the label precisely because
   the private class name has already churned once (`_PublicProfilePhoto` →
   `_HeroAvatar`). Keep the label if you rename again.
4. **Goldens.** `test/premium_member_ui_test.dart` is the only golden, on the
   default `LocalFileComparator` — exact pixel match, no tolerance. It does not
   cover this screen.
5. **Verify with `flutter build bundle --debug`, not just `flutter analyze`.**
   Analyze has reported zero errors while the CFE rejected the build.

## Still open here

* **No recency signal.** "Joined 5 weeks ago" is the only time information a
  stranger gets. "Last active" would be the single strongest input to the add
  decision — and is exactly the kind of presence data that is sensitive on an
  anonymous mental-health app. Needs a product call before it needs code.
* The `/user/:id/stat/:kind` detail screens are thin — a title, a one-line
  restatement, and a paragraph. Now that every stat on the profile routes into
  them, they carry more weight than they did.
* `isRestrictedMinor` in `entities.dart` still has zero call sites, and other
  restrictions the README claims for that tier (no external links) are enforced
  nowhere.
* **Two of the `20260816090000` fixes cannot be observed at this data size** —
  the `deleted_at` filter on replies and the inclusion of `whisper_comments`.
  Same limitation as the whispers already-heard filter: the SQL is applied and
  correct, but distinguishing it from the old formula needs a user who has
  deleted a comment or replied to a whisper. Do not record it as verified.
* `hugsReceived` and `postsTotal` are still fetched by `userProfile` (via
  `user_profile_extra_stats`) but nothing renders them since `faeaa04`. Either
  surface them or stop paying for the round trip.

## Security context (not a to-do)

The age floor and minor tier are enforced server-side as of `474ed98`;
`handle_new_auth_user()` used to trust client-supplied signup metadata, so both
the under-13 gate and the minor DM restriction were bypassable with the anon
key that ships in the app.

`b2c0560` wired the client: `canInitiateDm` → `dmInitiationAllowedProvider` →
`_MessageButton`, which dims and carries a Semantics hint but **keeps the tap
enabled on purpose**. `can_initiate_dm` is false for a restricted minor even
when a room already exists, while `start_chat_room` refuses only *new* rooms —
so a hard disable would strand a minor whose adult friend opened the thread.
Preserve that distinction if you touch the CTA.
