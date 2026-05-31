import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/friend_action_button.dart';

/// The Friend Profile — section 6 of the social spec. A friend-gated
/// "safe stalking" view: pseudonym + avatar at the top, an emotional
/// stats grid, mood distribution ring, mutual friends + tribes,
/// badges, recent vents, and the friend-action chip in context.
///
/// Strangers see a stripped view that pushes them toward sending a
/// friend request. Self redirects to /profile.
class FriendProfileScreen extends ConsumerWidget {
  const FriendProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    if (me != null && me.userId == userId) {
      // Self → bounce to the dedicated /profile screen. Use a
      // post-frame callback so we don't navigate during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/profile');
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final async = ref.watch(userProfileProvider(userId));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _NotAvailable(message: 'Could not load profile.\n$e'),
        data: (profile) {
          if (profile == null) {
            return const _NotAvailable(
              message: "This profile isn't available.",
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(userProfileProvider(userId));
              await ref.read(userProfileProvider(userId).future);
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Hero(profile: profile),
                  if (profile.relation == FriendStatus.blockedByMe)
                    const _BlockedNotice(),
                  if (profile.isFriend) ...[
                    _StatsGrid(profile: profile),
                    if (profile.topMoods.isNotEmpty)
                      _MoodRing(moods: profile.topMoods),
                    if (profile.badges.isNotEmpty)
                      _BadgesRow(badges: profile.badges),
                    if (profile.mostLiked != null ||
                        profile.mostCommented != null)
                      _Highlights(profile: profile),
                    if (profile.recentPosts.isNotEmpty)
                      _RecentVents(posts: profile.recentPosts),
                  ] else
                    _StrangerCallout(profile: profile),
                  if (profile.mutualTribes.isNotEmpty ||
                      profile.mutualFriendsCount > 0)
                    _MutualsSection(profile: profile),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────── Hero ───────────────────────

class _Hero extends StatelessWidget {
  const _Hero({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final daysSince =
        DateTime.now().difference(profile.joinedAt).inDays.clamp(0, 999999);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withOpacity(0.10),
            scheme.secondary.withOpacity(0.10),
          ],
        ),
      ),
      child: Column(
        children: [
          AnonymousAvatar(
            seed: profile.avatarSeed,
            label: profile.pseudonym,
            size: 96,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '@${profile.pseudonym}',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              if (profile.isVerified) ...[
                const SizedBox(width: 6),
                Icon(Icons.verified, size: 18, color: scheme.primary),
              ],
            ],
          ),
          if (profile.currentMood != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${Moods.emoji(profile.currentMood!)}  feeling ${Moods.label(profile.currentMood!).toLowerCase()}',
                style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            daysSince < 7
                ? 'Just joined'
                : daysSince < 365
                    ? 'Joined ${daysSince ~/ 7} weeks ago'
                    : 'Joined ${(daysSince / 365).toStringAsFixed(1)} years ago',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withOpacity(0.55),
            ),
          ),
          const SizedBox(height: 14),
          FriendActionButton(
            otherUserId: profile.userId,
            otherPseudonym: profile.pseudonym,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Stats grid ───────────────────────

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.05,
        children: [
          _StatCell(label: 'Vents', value: profile.vents),
          _StatCell(label: 'Comments', value: profile.comments ?? 0),
          _StatCell(
            label: 'Reactions',
            value: profile.reactionsReceived ?? 0,
          ),
          _StatCell(label: 'Tribes', value: profile.activeTribes),
          _StatCell(label: 'Badges', value: profile.badgesCount ?? 0),
          _StatCell(
            label: 'Streak',
            value: profile.currentStreak ?? 0,
            suffix: (profile.bestStreak ?? 0) > (profile.currentStreak ?? 0)
                ? 'best ${profile.bestStreak}'
                : null,
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.value,
    this.suffix,
  });
  final String label;
  final int value;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withOpacity(0.25)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value.toString(),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.4,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface.withOpacity(0.55),
            ),
          ),
          if (suffix != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                suffix!,
                style: TextStyle(
                  fontSize: 9.5,
                  color: scheme.onSurface.withOpacity(0.45),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────── Mood ring ───────────────────────

class _MoodRing extends StatelessWidget {
  const _MoodRing({required this.moods});
  final List<MoodCount> moods;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = moods.fold<int>(0, (s, m) => s + m.count);
    final top = moods.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outline.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 86,
              height: 86,
              child: CustomPaint(
                painter: _MoodRingPainter(
                  moods: moods,
                  base: scheme.surfaceContainerHighest,
                ),
                child: Center(
                  child: Text(
                    Moods.emoji(top.mood),
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mood distribution',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'Top: ${Moods.label(top.mood)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final m in moods.take(4))
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _moodColor(m.mood, scheme).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${Moods.emoji(m.mood)} ${Moods.label(m.mood)} · ${total > 0 ? (m.count * 100 / total).round() : 0}%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _moodColor(m.mood, scheme),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Color _moodColor(String mood, ColorScheme scheme) {
  switch (mood) {
    case 'happy':
    case 'grateful':
    case 'hopeful':
      return Colors.amber.shade700;
    case 'healing':
      return Colors.teal.shade600;
    case 'sad':
    case 'lonely':
    case 'broken':
      return Colors.indigo.shade400;
    case 'angry':
      return Colors.redAccent;
    case 'anxious':
    case 'overthinking':
      return Colors.deepPurple.shade400;
    case 'exhausted':
      return Colors.brown.shade400;
    case 'confused':
      return Colors.blueGrey.shade400;
    default:
      return scheme.primary;
  }
}

class _MoodRingPainter extends CustomPainter {
  _MoodRingPainter({required this.moods, required this.base});
  final List<MoodCount> moods;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final rect =
        Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = base.withOpacity(0.35);
    canvas.drawArc(rect, 0, math.pi * 2, false, ring);

    final total = moods.fold<int>(0, (s, m) => s + m.count);
    if (total == 0) return;

    var start = -math.pi / 2;
    final scheme = ColorScheme.fromSeed(seedColor: Colors.pinkAccent);
    for (final m in moods.take(6)) {
      final sweep = (m.count / total) * math.pi * 2;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.butt
        ..color = _moodColor(m.mood, scheme);
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _MoodRingPainter old) =>
      old.moods != moods || old.base != base;
}

// ─────────────────────── Badges ───────────────────────

class _BadgesRow extends StatelessWidget {
  const _BadgesRow({required this.badges});
  final List<UserBadge> badges;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outline.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                'Badges',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final b in badges)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: scheme.primary.withOpacity(0.30),
                      ),
                    ),
                    child: Text(
                      b.key.replaceAll('_', ' '),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Highlights ───────────────────────

class _Highlights extends StatelessWidget {
  const _Highlights({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Highlights'),
          if (profile.mostLiked != null)
            _HighlightCard(
              icon: Icons.favorite,
              label: 'Most loved',
              post: profile.mostLiked!,
            ),
          if (profile.mostCommented != null &&
              profile.mostCommented!.postId != profile.mostLiked?.postId)
            _HighlightCard(
              icon: Icons.forum,
              label: 'Most talked about',
              post: profile.mostCommented!,
            ),
        ],
      ),
    );
  }
}

class _HighlightCard extends StatelessWidget {
  const _HighlightCard({
    required this.icon,
    required this.label,
    required this.post,
  });
  final IconData icon;
  final String label;
  final ProfileHighlightPost post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/post/${post.postId}'),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outline.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 14, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${post.likes} · ${post.comments} comments',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  post.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Recent vents ───────────────────────

class _RecentVents extends StatelessWidget {
  const _RecentVents({required this.posts});
  final List<ProfileHighlightPost> posts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Recent vents'),
          for (final p in posts)
            _RecentPostTile(post: p),
        ],
      ),
    );
  }
}

class _RecentPostTile extends StatelessWidget {
  const _RecentPostTile({required this.post});
  final ProfileHighlightPost post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push('/post/${post.postId}'),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outline.withOpacity(0.20)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (post.mood != null) ...[
                      Text(Moods.emoji(post.mood!),
                          style: const TextStyle(fontSize: 13)),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      post.category,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withOpacity(0.55),
                      ),
                    ),
                    const Spacer(),
                    if (post.crisisLevel != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.error.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '💗 ${post.crisisLevel}',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  post.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 4),
                Text(
                  '♡ ${post.likes} · 💬 ${post.comments} · ${_rel(post.createdAt)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.55),
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

// ─────────────────────── Mutuals + Stranger ───────────────────────

class _MutualsSection extends StatelessWidget {
  const _MutualsSection({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('You both'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outline.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (profile.mutualFriendsCount > 0) ...[
                  Text(
                    profile.mutualFriendsCount == 1
                        ? '1 mutual friend'
                        : '${profile.mutualFriendsCount} mutual friends',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (profile.mutualFriendSample.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 36,
                      child: Stack(
                        children: [
                          for (var i = 0; i < profile.mutualFriendSample.length; i++)
                            Positioned(
                              left: i * 24.0,
                              child: GestureDetector(
                                onTap: () => context.push(
                                  '/user/${profile.mutualFriendSample[i].userId}',
                                ),
                                child: AnonymousAvatar(
                                  seed: profile.mutualFriendSample[i].avatarSeed,
                                  label: profile.mutualFriendSample[i].pseudonym,
                                  size: 32,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (profile.mutualTribes.isNotEmpty)
                    const SizedBox(height: 10),
                ],
                if (profile.mutualTribes.isNotEmpty) ...[
                  Text(
                    profile.mutualTribes.length == 1
                        ? '1 tribe in common'
                        : '${profile.mutualTribes.length} tribes in common',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in profile.mutualTribes)
                        ActionChip(
                          label: Text(t.name),
                          onPressed: () => context.push('/tribe/${t.slug}'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StrangerCallout extends StatelessWidget {
  const _StrangerCallout({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = profile.vents;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.primary.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.primary.withOpacity(0.20)),
        ),
        child: Column(
          children: [
            Icon(Icons.lock_outline, color: scheme.primary),
            const SizedBox(height: 6),
            Text(
              hidden == 0
                  ? 'No vents to show yet.'
                  : '$hidden vents · ${profile.activeTribes} tribes',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Send a friend request to see streaks, badges, mood distribution, and recent vents.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withOpacity(0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.error.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.error.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.block, color: scheme.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "You blocked this user. They can't send you requests.",
                style: TextStyle(color: scheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Bits ───────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
        ),
      ),
    );
  }
}

class _NotAvailable extends StatelessWidget {
  const _NotAvailable({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_person, size: 36,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

String _rel(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}
