# Messaging hub + friends page — brief and state

**Done and verified on device**, 2026-08-16: inbox `52f1244`, friends
`4249b07`, plus the Vibes consolidation in `e7e451b`.

Files: `lib/presentation/screens/inbox/inbox_screen.dart` and
`lib/presentation/screens/friends/friends_screen.dart`.

## What the brief got right, and what it got wrong

The original brief argued from a structural scan that both screens "bury
primary content under modules". That held: on a 6.7" display the inbox showed
2.5 conversations and the friends page showed **zero** friends without
scrolling.

It also claimed the inbox's "left edge never settles" across six different
insets, and called that "the most probable reason the hub reads as unpolished,
ahead of any single widget's styling". **That was wrong.** `_kColumn = 16`
already existed and was already used by the header, the conversations header
and the list. Only two real stragglers remained (a rail body at 14, the pending
card at 14), and fixing them changed almost nothing visually. The screens' real
problems were structural and behavioural, not alignment — the same false lead
the feed audit produced with `horizontal: 16`.

## What actually landed

### Inbox — `52f1244`

* **Ordering was a genuine bug.** `_allRoomsProvider` sorted by `createdAt`
  while `_ConversationRow` displayed `lastMessageAt ?? createdAt`, so the
  timestamps ran out of order down the screen and a thread replied to a minute
  ago stayed wherever its room happened to sit. On real data this hid a 7/27
  conversation below ones from 7/18 and 7/15.
* **Tribe chats were a horizontal rail of chats above a list of chats**, and
  with one tribe it rendered as a single card clipped by the screen edge.
  `_InboxEntry` now carries either a `ChatRoom` or a `TribeChatInboxSummary`;
  `_applyFilter` merges and sorts both by the same recency key and keeps tribes
  out of Requests, which only ever means friend requests. `_TribeChatsRail` and
  `_TribeChatChip` are gone.
* **The Vibes rail duplicated Home's 24h Vent Stories** and was the weaker
  copy: a gradient story ring means "has an unread story", but these bubbles
  showed every friend regardless and tapping opened a DM. Removed; stories live
  on Home only (still asserted by the feed test). New chats start from the
  compose button in the header.
* Search never looked at `groupTitle`, so searching a group by the name on its
  own row returned nothing.
* A room with no messages rendered a delivered/read double-tick beside an empty
  preview. Gated on `lastMessageAt != null`.
* "Tap to open chat" → "No messages yet".

Result: 2.5 conversations above the fold → 5, on the same device.

### Friends — `4249b07`

* The `_InstantConnectCard` was a 64pt QR tile plus a heading plus two lines of
  body copy, stacked above the two buttons it described. Now just the buttons,
  keeping the one sentence that earns its place on an anonymity-first product
  ("No phone numbers, no real names"). All four friends render on first paint.
* Alphabetical headers now start at 12 friends (`_kAlphabetIndexFrom`). Below
  that they produced three letters for four rows. Favourites still sort to the
  top — that was always the sort, never the headers.
* Magic `116` bottom inset folded onto `HomeShell.navClearance`.

**The golden caught a bug the simulator could not**: at 390pt "Share link"
wrapped to two lines inside its half-width pill; the 402pt simulator had just
enough room. `FilledButton.icon`'s default horizontal padding is too generous
for a two-up button.

## Goldens

`premium_chats.png` and `premium_circle.png` were regenerated and eyeballed;
`premium_circle_tribes.png` was unaffected because the block only renders on
the Friends tab. `premium_member_ui_test`'s circle assertion moved off the
removed "Instant connect" heading onto "Share link" / "My QR" — the heading was
explanatory copy, the buttons are the affordances the test is about.

## Still open

**The friends page does two unrelated jobs**: managing people you know
(`_FriendRow`, `_RequestsSection`, `_FavoriteHeart`, `_OutgoingSheet`) and
browsing tribes (`_TribeExploreControls`, `_RecommendedTribeCard`) — and
`/tribes` already owns a directory screen. That conflation is probably why the
page needs `_CircleViewTabs` at all: it is arbitrating between two screens
crammed into one. Raised with the user; deliberately not actioned, because
splitting it is a product decision, not a styling one.

## Constraints that still hold

1. `_kColumn = 16` is the inbox's section column. Use it; do not add a literal.
2. `_ConversationRow` and `_FriendRow` are the rows users scan. Row height and
   information hierarchy there matter more than anything above them.
3. Verify with `flutter build bundle --debug`, not just `flutter analyze` —
   analyze has passed while the CFE rejected the build.
4. Off-grid spacing is often deliberate: of 16 off-scale gaps on the feed, 9
   were intentional 2–6px micro-spacing inside components.
