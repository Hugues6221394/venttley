# Messaging hub + friends page redesign — handoff brief

Companion to `public-profile-redesign-brief.md`. Written from a structural scan,
not a full read of either file — the class inventory and the counts below are
verified; the design reading is argued from them and should be checked against
the running app.

Verified at commit `dcddc88`.

## The shared problem: primary content is buried under modules

Both screens push the thing you opened them for below a stack of discovery and
promotion widgets. This is the same fault already diagnosed on the feed, where
three rows of chrome (title, scope+sort pills, category rail — a hard-coded
158px `SliverPersistentHeader`) leave ~2.5 posts visible on a 6.7" screen.

**`inbox_screen.dart` (1,569 lines).** Before a single conversation row:
`_ChatHeader` → `_SearchField` → `_VibesRail` → `_TribeChatsRail` →
`_PendingRequestsCard` → `_ConversationsHeader` → `_FilterChip`. Seven blocks,
two of them horizontal rails, ahead of `_ConversationRow`. A messaging hub whose
messages start below the fold is not a messaging hub.

**`friends_screen.dart` (2,111 lines).** Before a single friend row:
`_CircleViewTabs` → `_TribeExploreControls` → `_RecommendedTribeCard` →
`_FriendsHeader` → `_InstantConnectCard` → `_RealQrCard` → `_RequestsSection` →
`_QuickSuggestionsSection` → `_MyFriendsHeader`, then `_FriendRow`.

`friends_screen` also does **two unrelated jobs**: managing people you know
(`_FriendRow`, `_RequestsSection`, `_FavoriteHeart`, `_OutgoingSheet`) and
browsing tribes (`_TribeExploreControls`, `_RecommendedTribeCard`). The `/tribes`
route already owns a directory screen. That conflation is likely why the page
needs a `_CircleViewTabs` switcher at all — it is arbitrating between two
screens crammed into one.

Worth deciding before any styling: **what is the one job of each screen?** No
amount of restyling fixes a page that is two pages.

## Class inventory

### `inbox_screen.dart`

| Line | Class |
| --- | --- |
| 22 / 39 | `InboxScreen` / `_InboxScreenState` |
| 29 | `_InboxFilter` |
| 266 | `_ChatHeader` |
| 336 | `_SearchField` |
| 401 | `_VibesRail` |
| 464 / 513 | `_TribeChatsRail` / `_TribeChatChip` |
| 613 | `_YourVentBubble` |
| 650 / 674 | `DottedCircle` / `_DottedCirclePainter` |
| 699 | `_VibeBubble` |
| 802 | `_PendingRequestsCard` |
| 895 | `_ConversationsHeader` |
| 939 | `_FilterChip` |
| 981 | `_ConversationRow` ← the actual content |
| 1313 | `_LastMessageLine` |
| 1370 | `_ReadStateGlyph` |
| 1409 | `_EmptyConversations` |
| 1507 | `_LoadingSkeleton` |

`DottedCircle` is the only public class here; check for external users before
renaming it.

### `friends_screen.dart`

| Line | Class |
| --- | --- |
| 34 / 45 | `FriendsScreen` / `_FriendsScreenState` |
| 41 / 43 | `_FriendSort` / `_CircleView` |
| 420 | `_AlphabeticalGroup` |
| 430 / 474 | `_CircleViewTabs` / `_CircleViewTab` |
| 530 | `_TribeExploreControls` ← belongs on /tribes |
| 648 / 661 | `_RecommendedTribeCard` / `State` ← belongs on /tribes |
| 852 | `_FriendsHeader` |
| 906 | `_InstantConnectCard` |
| 1103 | `_RealQrCard` |
| 1140 / 1243 / 1251 | `_RequestsSection` / `_RequestCard` / `State` |
| 1382 / 1443 / 1450 | `_QuickSuggestionsSection` / `_SuggestionCard` / `State` |
| 1569 | `_MyFriendsHeader` |
| 1660 | `_FriendRow` ← the actual content |
| 1865 / 1872 | `_FavoriteHeart` / `State` |
| 1912 | `_OutgoingSheet` |
| 2028 | `_EmptyState` |
| 2078 | `_ListSkeleton` |

## Constraints

Same as the profile brief, plus:

1. **Neither screen uses `HomeShell.navClearance`.** Both reserve enough bottom
   space today (inbox ~120, friends ~116, found via mixed patterns — trailing
   `SizedBox`, `fromLTRB`, `EdgeInsets.only`) but with magic numbers. Fold them
   onto the constant; that inconsistency is exactly how `keeper_home` drifted to
   28 and clipped its last row.
2. **`VentlyTokens`** (4pt scale `s4…s32`) is almost certainly unreferenced here
   too, as on the feed. Measure before adding spacing.
3. **Goldens.** `premium_chats.png` covers the inbox and `premium_circle.png` /
   `premium_circle_tribes.png` cover friends, on the default
   `LocalFileComparator` — exact pixel match, zero tolerance. Any redesign will
   break all three; regenerate deliberately and eyeball them, do not
   `--update-goldens` reflexively.
4. `_ConversationRow` (inbox) and `_FriendRow` (friends) are the rows users
   actually scan. Row height and information hierarchy there matter more than
   anything above them.
5. **Verify with `flutter build bundle --debug`**, not just `flutter analyze` —
   analyze has already passed while the CFE rejected the build.

## Method notes

Carried from the profile brief because they cost real time to learn:

- Read each site before editing. A grep-driven pass on the feed produced a false
  positive — `horizontal: 16` looked like a misaligned section inset but was
  internal padding of a fixed-width card in a rail, with nothing to align to.
- Off-grid spacing is often deliberate: of 16 off-scale gaps on the feed, 9 were
  intentional 2–6px micro-spacing inside components. Snapping those to 4pt
  doubles them.
- The shell's `grep` failed mid-session with a "claude native binary not
  installed" error inside loops, returning silently empty results. Verify with
  Python if tooling looks wrong.

## Measured: the inbox's left edge never settles

Verified by scanning every horizontal inset in `inbox_screen.dart`. Reading down
the screen, section content starts at:

| Section | Left inset |
| --- | --- |
| `_ChatHeader` | 20 |
| `_SearchField` | 16 (inner 14) |
| `_VibesRail` heading / rail body | 16 / **14** |
| `_TribeChatsRail` heading / rail body | 16 / **14** |
| `_PendingRequestsCard` | 14 |
| `_ConversationsHeader` | 16 |
| conversation list | **12**, plus 10 inside `_ConversationRow` |
| `_LoadingSkeleton` | 16 |

Six values on one vertical axis, so no two sections share a column. Two are
outright defects of the kind already fixed on the feed greeting
(`feed_screen.dart:531`, commit `7853c49`):

- a rail heading at 16 with its chips at 14 — twice, in `_VibesRail` and
  `_TribeChatsRail`
- `_ConversationsHeader` at 16 above a list at 12, whose rows then add 10 of
  their own, so the heading and the avatars beneath it are ~6px apart

This is the most probable reason the hub reads as unpolished, ahead of any
single widget's styling. Establishing one section inset and applying it to
headings, card margins and the list — while leaving genuinely internal
component padding alone — is the highest-value first change.

Which value is a judgement call needing the running app: 16 is the de facto
standard here (five sections use it), while the feed uses 20 throughout, so
matching the feed would also make the two main surfaces agree.

**Not applied.** Every candidate change shifts `premium_chats.png` and needs a
visual pass to confirm the rails still read as aligned with their headings —
chips carry their own internal padding, so matching numbers is not the same as
matching optical alignment.

### Verified as *not* problems

- All three rails are correctly conditional: `_VibesRail` guards on
  `friends.isNotEmpty`, `_PendingRequestsCard` on `pending > 0`, and
  `_TribeChatsRail` self-hides with `SizedBox.shrink()` on loading, error and
  empty. It looked unconditional at the call site (line 108); it is not.
