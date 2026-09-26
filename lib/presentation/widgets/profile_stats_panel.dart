import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/entities.dart';
import '../../domain/profile/profile_stat_kind.dart';
import '../theme/colors.dart';
import 'glass_card.dart';
import 'post_card.dart' show PostCard;

/// The detail half of a public profile's stats — tappable glass cards.
///
/// Connections, vents and tribes are deliberately *not* here: they are the
/// hero's headline band. This panel used to repeat Connections verbatim and put
/// "Vents" directly under the hero's "Posts" (a different number for the same
/// idea), so the screen opened with two stat blocks disagreeing with each other.
///
/// One card design for all four, in a 2×2 grid. The old layout mixed three large
/// iconned cards with four cramped chips, which is what made the block read as
/// ragged — and at four-across the chips truncated "Reactions received" to
/// "Reactions r…". Two-across leaves every label room to breathe.
class ProfileStatsPanel extends StatelessWidget {
  const ProfileStatsPanel({super.key, required this.profile});
  final UserProfileView profile;

  static const _kinds = [
    ProfileStatKind.reactions,
    ProfileStatKind.comments,
    ProfileStatKind.streak,
    ProfileStatKind.badges,
  ];

  void _open(BuildContext context, ProfileStatKind kind) {
    context.push('/user/${profile.userId}/stat/${kind.routeSegment}');
  }

  int _value(ProfileStatKind kind) => switch (kind) {
    ProfileStatKind.connections => profile.connectionsCount,
    ProfileStatKind.vents => profile.vents,
    ProfileStatKind.comments => profile.comments ?? 0,
    ProfileStatKind.reactions => profile.reactionsReceived ?? 0,
    ProfileStatKind.tribes => profile.activeTribes,
    ProfileStatKind.badges => profile.badgesCount ?? profile.badges.length,
    ProfileStatKind.streak => profile.currentStreak ?? 0,
  };

  String? _suffix(ProfileStatKind kind) {
    if (kind != ProfileStatKind.streak) return null;
    final best = profile.bestStreak ?? 0;
    if (best <= (profile.currentStreak ?? 0)) return null;
    return 'best $best';
  }

  @override
  Widget build(BuildContext context) {
    final values = [for (final k in _kinds) _value(k)];

    // _StatCard is its own Expanded: it sits inside a Row of four either way,
    // and having the column own that keeps the divider arithmetic in one place.
    Widget cell(int i) => _StatCard(
      kind: _kinds[i],
      value: values[i],
      suffix: _suffix(_kinds[i]),
      onTap: () => _open(context, _kinds[i]),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Activity',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 13,
              letterSpacing: 0.6,
              color: context.ink.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 10),
          if (values.every((v) => v == 0))
            _JustGettingStarted(pseudonym: profile.pseudonym)
          else
            // One card, four columns, hairlines between them.
            //
            // This was a two-by-two grid of large cards, each holding an icon,
            // a chevron, a number and a label — four tall boxes whose contents
            // were usually "0", taking half a screen to say very little. Four
            // numbers in a row is the same information at a quarter of the
            // height, and it stops the page reading like a dashboard somebody
            // forgot to fill in.
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 14),
              borderRadius: 18,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _kinds.length; i++) ...[
                      if (i > 0)
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          indent: 4,
                          endIndent: 4,
                          color: context.ink.withOpacity(0.07),
                        ),
                      cell(i),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown instead of the grid when every stat in it is zero.
///
/// A profile's job here is to answer "is this person worth connecting with",
/// and four cards reading 0 answer it emphatically in the wrong direction —
/// a normal new account looks abandoned. The hero band above still carries
/// their real numbers, so nothing is hidden; this only replaces a block that
/// would otherwise say nothing four times.
class _JustGettingStarted extends StatelessWidget {
  const _JustGettingStarted({required this.pseudonym});
  final String pseudonym;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      borderRadius: 18,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: VentlyColors.berryMagenta.withOpacity(0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 17,
              color: VentlyColors.berryMagenta,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Just getting started',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: context.ink,
                  ),
                ),
                const SizedBox(height: 3),
                // Phrased as "nothing here yet" rather than "@X has done
                // nothing". Until 20260816090000 is applied the server sends
                // these counts only to friends, so on a stranger's profile a
                // zero means "not disclosed", not "none" — and asserting the
                // second would be a false statement about a real person.
                Text(
                  "@$pseudonym's replies, reactions and badges will show up "
                  'here. Say hi.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: context.ink.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One stat. The only card design in this panel — see [ProfileStatsPanel] for
/// why there used to be two.
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.kind,
    required this.value,
    required this.onTap,
    this.suffix,
  });

  final ProfileStatKind kind;
  final int value;
  final VoidCallback onTap;
  final String? suffix;

  /// Keyed off [ProfileStatKind.iconName] rather than the enum so the mapping
  /// stays in one place if the domain layer ever grows a kind this widget has
  /// not been taught about — it falls through to a neutral glyph instead of
  /// failing to compile a switch.
  IconData get _icon => switch (kind.iconName) {
    'people' => Icons.people_outline_rounded,
    'edit_note' => Icons.edit_note_rounded,
    'diversity_3' => Icons.diversity_3_rounded,
    'chat_bubble' => Icons.chat_bubble_outline_rounded,
    'favorite' => Icons.favorite_outline_rounded,
    'military_tech' => Icons.military_tech_outlined,
    'local_fire_department' => Icons.local_fire_department_outlined,
    _ => Icons.insights_outlined,
  };

  @override
  Widget build(BuildContext context) {
    // A single zero among real numbers is honest, but it should not shout as
    // loudly as them — full-weight ink on a 0 reads as the loudest thing in the
    // row precisely when it is the least informative.
    final zero = value == 0;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _icon,
                  size: 17,
                  color: VentlyColors.berryMagenta.withOpacity(zero ? 0.4 : 1),
                ),
                const SizedBox(height: 7),
                Text(
                  PostCard.compactNumber(value),
                  maxLines: 1,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 19,
                    height: 1,
                    letterSpacing: -0.4,
                    color: context.ink.withOpacity(zero ? 0.38 : 1),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  kind.title,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                    height: 1.2,
                    color: context.ink.withOpacity(0.58),
                  ),
                ),
                if (suffix != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      suffix!,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: VentlyColors.berryMagenta.withOpacity(0.85),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
