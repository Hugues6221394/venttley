# Public profile redesign — handoff brief

Written at the end of a session that ran out of context before the redesign
could start. Everything below is verified against the code, not remembered.

**Target file:** `lib/presentation/screens/friends/friend_profile_screen.dart`
(1,840 lines). Route: `/user/:userId`, plus `/user/:userId/stat/:statKind`.

## Goal

Make it modern, professional, genuinely attractive, and smooth — with care on
the details. This is the screen someone reads to decide whether to open up to a
stranger on a platform about trauma and self-harm. Restraint reads as
trustworthy here; density and ornament read as a growth product.

## Current structure

Sliver order inside the profile body:

| Widget | Line | Notes |
| --- | --- | --- |
| `_FriendProfileBody` | 99 | owns the sliver list |
| `_Hero` | 465 | wraps banner + avatar + identity |
| `_HeroBanner` | 620 | photo header |
| `_BrandBanner` | 669 | fallback when no photo |
| `_HeroAvatar` | 692 | **tap-to-preview + semantics label — keep both** |
| `_MetaPill` | 767 | pronouns, current mood |
| `_StatsBanner` | 796 | stat band |
| `_MessageButton` / `State` | 851 / 859 | dimmed + hinted for restricted minors; tap stays enabled on purpose |
| `_Highlights` / `_HighlightCard` | 972 / 1003 | |
| `_MutualsSection` | 1074 | |
| `_StrangerCallout` | 1168 | shown to non-friends |
| `_BlockedNotice` | 1211 | |
| `_SectionTitle` / `_NotAvailable` | 1245 / 1266 | |
| `_ActivityHeatmap` | 1300 | + `_HeatmapCell` 1472, `_HeatmapDot` 1479 |
| `_WhispersSection` | 1537 | |
| `_QuestionsSection` | 1586 | |
| `_WhisperMiniCard` | 1630 | |
| `_TribesSection` | 1733 | |
| Tabs | `_VentsTab` 186 (`State` 194), `_AchievementsTab` 303, `_ActivityTab` 329 | |
| `_StreakCard` 356, `_VibeLevelBar` 402 | | |

Line numbers verified at commit `b2c0560`; the file is 1,840 lines. Re-derive
them before trusting this table — two changes have already shifted it.

A mood distribution ring used to sit between the stat band and the tabs. It was
removed (`420ff4d`) because mood changes daily and nobody maintains the
aggregate — it presented noise with the authority of a statistic. **Its removal
leaves a gap in the sliver rhythm that should be re-composed, not just closed.**

The hero's *current mood* pill was deliberately kept: a self-declared mood right
now is a different claim from an inferred trend.

## Constraints — these are real, do not rediscover them

1. **`HomeShell.navClearance`** (`screens/home/home_shell.dart`) is the bottom
   space every surface scrolling under the floating nav must reserve. Use it;
   do not introduce another magic number. Six screens still use 110/116/120 and
   should be folded onto it.
2. **`VentlyTokens`** (`presentation/theme/vently_tokens.dart`) defines a 4pt
   scale `s4…s32` plus `radiusChip/Card/Panel`. The feed references it **zero**
   times; this screen likely does too. Measure before adding spacing.
3. **`_HeroAvatar` carries an accessibility contract.** Its semantics label
   `'View @${profile.pseudonym} profile photo'` is asserted by
   `test/tribe_reliability_test.dart`. It is anchored on the label precisely
   because the widget's private class name has already churned once
   (`_PublicProfilePhoto` → `_HeroAvatar`). Keep the label if you rename again.
4. **Goldens.** `test/premium_member_ui_test.dart` is the only golden file, on
   the default `LocalFileComparator` — exact pixel match, no tolerance. It does
   not currently cover this screen. If you add coverage, know that any engine
   bump will break it.
5. **Verify with `flutter build bundle --debug`, not just `flutter analyze`.**
   Analyze has already reported zero errors while the CFE rejected the build.

## Method notes learned the hard way

- **Read each site before editing it.** A grep-driven pass on the feed produced
  a false positive: `horizontal: 16` looked like a section inset misaligned
  against a header at 20, but was internal padding of a fixed-width card in a
  horizontal rail, with nothing to align to.
- **Off-grid spacing is not automatically wrong.** Of 16 off-scale gaps in the
  feed, 9 were intentional micro-spacing (2–6px between an avatar and its
  label). Snapping those to 4pt doubles them and rewrites component proportions.
- Only 7 were block-level rhythm — and every off-grid value there (10, 14, 18)
  sits *equidistant* between two scale steps, so "snap to grid" is a
  tighten-or-loosen design choice, not a mechanical fix.
- The shell's `grep` broke mid-session with a "claude native binary not
  installed" error inside loops, returning silently empty results. If tooling
  looks wrong, verify with Python before trusting it.

## Open questions for the user

- Should the *current mood* pill stay? (Kept, on the reasoning above.)
- Does the stat band earn its space, or is it the same "authority without
  maintenance" problem as the mood ring?
- What does a stranger most need to see to feel safe messaging this person?
  That answer should drive the sliver order.

## Security work already landed (context, not a to-do)

The age floor and minor tier are now enforced server-side. `handle_new_auth_user()`
used to read `safety_tier` and `birth_year` from client-supplied signup
metadata, so both the under-13 gate and the minor DM restriction were
bypassable with the anon key that ships in the app.

Applied by hand in the Supabase SQL editor, then committed as `474ed98`:
`20260811010000_enforce_age_floor_server_side.sql`,
`20260811020000_restrict_minor_dm_initiation.sql`,
`20260811030000_backfill_derived_safety_tier.sql`.

`b2c0560` wired the client side: `canInitiateDm` → `dmInitiationAllowedProvider`
→ `_MessageButton`, which dims and carries a Semantics hint but **keeps the tap
enabled on purpose**. `can_initiate_dm` is false for a restricted minor even
when a room already exists, while `start_chat_room` refuses only *new* rooms —
so a hard disable would strand a minor whose adult friend opened the thread.
Preserve that distinction if you touch the CTA.

Still open: `isRestrictedMinor` in `entities.dart` has zero call sites. Other
restrictions the README claims for the tier (no external links) are enforced
nowhere. Worth an audit of what else it is meant to gate.
