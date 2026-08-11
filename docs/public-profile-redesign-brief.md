# Public profile redesign — handoff brief

Written at the end of a session that ran out of context before the redesign
could start. Everything below is verified against the code, not remembered.

**Target file:** `lib/presentation/screens/friends/friend_profile_screen.dart`
(1,795 lines). Route: `/user/:userId`, plus `/user/:userId/stat/:statKind`.

## Goal

Make it modern, professional, genuinely attractive, and smooth — with care on
the details. This is the screen someone reads to decide whether to open up to a
stranger on a platform about trauma and self-harm. Restraint reads as
trustworthy here; density and ornament read as a growth product.

## Current structure

Sliver order inside the profile body:

| Widget | Line (pre-redesign) | Notes |
| --- | --- | --- |
| `_FriendProfileBody` | 100 | owns the sliver list |
| `_Hero` | 464 | wraps banner + avatar + identity |
| `_HeroBanner` | 619 | photo header |
| `_BrandBanner` | 668 | fallback when no photo |
| `_HeroAvatar` | 691 | **tap-to-preview + semantics label — keep both** |
| `_MetaPill` | 766 | pronouns, current mood |
| `_StatsBanner` | 795 | stat band |
| `_MessageButton` | 850 | DM CTA |
| `_Highlights` / `_HighlightCard` | 1092 / 1123 | |
| `_MutualsSection` | 1194 | |
| `_StrangerCallout` | 1286 | shown to non-friends |
| Tabs | `_VentsTab` 189, `_AchievementsTab` 304, `_ActivityTab` 330 | |
| `_StreakCard` 357, `_VibeLevelBar` 403 | | |

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

## Higher priority than this redesign

Three **unrun** migrations sit in `supabase/migrations/`:
`20260811010000_enforce_age_floor_server_side.sql`,
`20260811020000_restrict_minor_dm_initiation.sql`,
`20260811030000_backfill_derived_safety_tier.sql`.

`handle_new_auth_user()` reads `safety_tier` and `birth_year` from
client-supplied signup metadata, so the under-13 gate and the minor DM
restriction are both bypassable using the shipped anon key. On a platform
serving 13–17 year olds that is a compliance exposure. Run `010000` first and
test a signup immediately — it replaces the trigger firing on every
`auth.users` insert. They are unvalidated (no Docker locally); CI's `database`
job replays them.
