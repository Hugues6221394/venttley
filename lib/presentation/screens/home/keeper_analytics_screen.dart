import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/keeper/keeper_overview.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/vently_premium_background.dart';
import 'home_shell.dart';

/// Keeper tab — SaaS-style analytics for tribe operators.
class KeeperAnalyticsScreen extends ConsumerWidget {
  const KeeperAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overviewAsync = ref.watch(keeperOverviewProvider);
    final tribe = ref.watch(primaryKeeperTribeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: overviewAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load: $e')),
            data: (overview) {
              final stats = tribe != null
                  ? overview.statsFor(tribe.tribeId)
                  : null;
              final health = _healthScore(overview, stats);
              final growth = _growthRate(stats);
              final retention = _retention(stats);

              return RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: () async {
                  ref.invalidate(keeperOverviewProvider);
                  ref.invalidate(tribesIKeepProvider);
                },
                child: ListView(
                  // Bottom was 32, leaving the last chart under the nav pill.
                  padding: const EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    HomeShell.navClearance,
                  ),
                  children: [
                    Text(
                      'Analytics',
                      style: TextStyle(
                        color: context.ink,
                        fontWeight: FontWeight.w900,
                        fontSize: 24,
                      ),
                    ),
                    if (tribe != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 16),
                        child: Text(
                          tribe.name,
                          style: TextStyle(
                            color: VentlyColors.berryMagenta.withOpacity(0.85),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    _HeroMetric(
                      label: 'Community Health',
                      value: '$health%',
                      subtitle: health >= 80
                          ? 'Your tribe is thriving'
                          : health >= 50
                              ? 'Room to grow engagement'
                              : 'Needs attention today',
                      color: health >= 80
                          ? const Color(0xFF3D9B6A)
                          : health >= 50
                              ? const Color(0xFFD97706)
                              : VentlyColors.berryMagenta,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            label: 'Growth · 7d',
                            value: growth,
                            icon: Icons.trending_up_rounded,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MetricCard(
                            label: 'Retention',
                            value: retention,
                            icon: Icons.autorenew_rounded,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            label: 'Vents · 24h',
                            value: '${stats?.posts24h ?? overview.totalPosts24h}',
                            icon: Icons.forum_outlined,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MetricCard(
                            label: 'Replies · 7d',
                            value: '${stats?.comments7d ?? 0}',
                            icon: Icons.chat_bubble_outline,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            label: 'Active posters',
                            value: '${stats?.activePosters7d ?? overview.totalActivePosters7d}',
                            icon: Icons.person_outline,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MetricCard(
                            label: 'Engagement',
                            value:
                                '${overview.engagementScoreFor(stats)}',
                            icon: Icons.bolt_rounded,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Insights',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _InsightRow(
                            text: overview.totalOpenReports > 0
                                ? '${overview.totalOpenReports} reports need review — open Safety Center.'
                                : 'No open reports. Safety looks clear.',
                            urgent: overview.totalOpenReports > 0,
                          ),
                          _InsightRow(
                            text: (stats?.members7d ?? 0) > 0
                                ? '+${stats?.members7d ?? overview.totalNewMembers7d} new members joined this week.'
                                : 'No new members this week — try a welcome prompt.',
                          ),
                          _InsightRow(
                            text: (stats?.scheduledPrompts ?? 0) > 0
                                ? '${stats?.scheduledPrompts} prompts scheduled — keep the rhythm going.'
                                : 'Schedule a prompt to boost daily conversation.',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (tribe != null)
                      FilledButton.icon(
                        onPressed: () =>
                            context.push('/tribe/${tribe.slug}/manage'),
                        icon: const Icon(Icons.insights_outlined),
                        label: const Text('Open tribe studio'),
                      ),
                    // This used to clear member view and go('/profile'),
                    // which for a keeper resolves right back to this screen —
                    // a button that navigated to where you already were.
                    TextButton(
                      onPressed: () => context.push('/profile/me'),
                      child: const Text('Personal profile & settings'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  int _healthScore(KeeperOverview overview, TribeStudioStats? stats) {
    final engagement = overview.engagementScoreFor(stats);
    final reportsPenalty = (overview.totalOpenReports * 8).clamp(0, 40);
    return (engagement + 20 - reportsPenalty).clamp(0, 100);
  }

  String _growthRate(TribeStudioStats? stats) {
    if (stats == null) return '—';
    final base = stats.memberCount - stats.members7d;
    if (base <= 0) return stats.members7d > 0 ? '+100%' : '0%';
    final pct = (stats.members7d / base * 100).round();
    return '+$pct%';
  }

  String _retention(TribeStudioStats? stats) {
    if (stats == null || stats.memberCount == 0) return '—';
    final pct =
        (stats.activePosters7d / stats.memberCount * 100).round().clamp(0, 100);
    return '$pct%';
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.color,
  });
  final String label;
  final String value;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, color.withOpacity(0.75)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w900,
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 36,
            ),
          ),
          Text(
            subtitle,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: VentlyColors.berryMagenta, size: 20),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 22,
              color: context.ink,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 11,
              color: context.ink.withOpacity(0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.text, this.urgent = false});
  final String text;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            urgent ? Icons.warning_amber_rounded : Icons.auto_awesome_outlined,
            size: 16,
            color: urgent
                ? VentlyColors.berryMagenta
                : context.ink.withOpacity(0.55),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: context.ink.withOpacity(0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
