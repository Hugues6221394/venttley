import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/entities.dart';
import '../../domain/profile/profile_stat_kind.dart';
import '../theme/colors.dart';
import 'glass_card.dart';
import 'post_card.dart' show PostCard;

/// Professional KPI layout for public profiles — tappable glass cards.
class ProfileStatsPanel extends StatelessWidget {
  const ProfileStatsPanel({super.key, required this.profile});
  final UserProfileView profile;

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

  @override
  Widget build(BuildContext context) {
    const primary = [
      ProfileStatKind.connections,
      ProfileStatKind.vents,
      ProfileStatKind.tribes,
    ];
    const secondary = [
      ProfileStatKind.comments,
      ProfileStatKind.reactions,
      ProfileStatKind.badges,
      ProfileStatKind.streak,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Overview',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 13,
              letterSpacing: 0.6,
              color: context.ink.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < primary.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: _PrimaryStatCard(
                    kind: primary[i],
                    value: _value(primary[i]),
                    suffix: primary[i] == ProfileStatKind.streak &&
                            (profile.bestStreak ?? 0) >
                                (profile.currentStreak ?? 0)
                        ? 'best ${profile.bestStreak}'
                        : null,
                    onTap: () => _open(context, primary[i]),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < secondary.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _SecondaryStatChip(
                    kind: secondary[i],
                    value: _value(secondary[i]),
                    onTap: () => _open(context, secondary[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _PrimaryStatCard extends StatelessWidget {
  const _PrimaryStatCard({
    required this.kind,
    required this.value,
    required this.onTap,
    this.suffix,
  });

  final ProfileStatKind kind;
  final int value;
  final VoidCallback onTap;
  final String? suffix;

  IconData get _icon => switch (kind.iconName) {
        'people' => Icons.people_outline_rounded,
        'edit_note' => Icons.edit_note_rounded,
        'diversity_3' => Icons.diversity_3_rounded,
        _ => Icons.insights_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(12, 14, 10, 12),
          borderRadius: 18,
          elevated: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon, size: 16, color: VentlyColors.berryMagenta),
                  const Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: context.ink.withOpacity(0.35),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                PostCard.compactNumber(value),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                  height: 1,
                  color: context.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                kind.title,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  color: context.ink.withOpacity(0.62),
                ),
              ),
              if (suffix != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    suffix!,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: VentlyColors.berryMagenta.withOpacity(0.8),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryStatChip extends StatelessWidget {
  const _SecondaryStatChip({
    required this.kind,
    required this.value,
    required this.onTap,
  });

  final ProfileStatKind kind;
  final int value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          borderRadius: 14,
          child: Column(
            children: [
              Text(
                PostCard.compactNumber(value),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: context.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                kind.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 9,
                  color: context.ink.withOpacity(0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
