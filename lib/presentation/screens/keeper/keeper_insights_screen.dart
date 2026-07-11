import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/keeper/keeper_studio_v2.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import 'keeper_studio_scaffold.dart';

/// AI Insights — heuristic growth, retention, mood, and safety signals.
class KeeperInsightsScreen extends ConsumerWidget {
  const KeeperInsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);
    final tribeId = tribe?.tribeId;
    final insightsAsync = tribeId == null
        ? const AsyncValue<KeeperAiInsights>.loading()
        : ref.watch(keeperAiInsightsProvider(tribeId));

    return KeeperStudioScaffold(
      title: 'AI Insights',
      subtitle: 'Growth, retention, mood trends, and safety score',
      onRefresh: () async {
        if (tribeId != null) {
          ref.invalidate(keeperAiInsightsProvider(tribeId));
        }
      },
      child: insightsAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
          ),
        ),
        error: (e, _) => Text('Could not load insights: $e'),
        data: (data) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _ScoreCard(
                    label: 'Health',
                    value: data.healthScore,
                    icon: Icons.favorite_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ScoreCard(
                    label: 'Safety',
                    value: data.safetyScore,
                    icon: Icons.shield_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            GlassCard(
              child: Row(
                children: [
                  const Icon(Icons.autorenew_rounded,
                      color: VentlyColors.berryMagenta),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Retention: ${_retentionLabel(data.retentionLabel)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: VentlyColors.deepBurgundy,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (data.moodTrends.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Text(
                'Mood trends (14d)',
                style: TextStyle(
                  color: VentlyColors.deepBurgundy,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              ...data.moodTrends.map(_MoodRow.new),
            ],
            const SizedBox(height: 18),
            const Text(
              'Recommendations',
              style: TextStyle(
                color: VentlyColors.deepBurgundy,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            if (data.insights.isEmpty)
              GlassCard(
                child: Text(
                  'No alerts — keep nurturing your community.',
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy.withOpacity(0.65),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              ...data.insights.map((i) => _InsightTile(insight: i)),
            const SizedBox(height: 16),
            if (tribeId != null)
              _ExportButton(tribeId: tribeId, tribeName: tribe?.name ?? 'Tribe'),
          ],
        ),
      ),
    );
  }

  static String _retentionLabel(String key) {
    switch (key) {
      case 'growing':
        return 'Growing';
      case 'at_risk':
        return 'At risk';
      default:
        return 'Stable';
    }
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = value >= 80
        ? const Color(0xFF3D9B6A)
        : value >= 50
            ? const Color(0xFFD97706)
            : VentlyColors.berryMagenta;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 8),
          Text(
            '$value%',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 26,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: VentlyColors.deepBurgundy.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoodRow extends StatelessWidget {
  const _MoodRow(this.trend);
  final KeeperMoodTrend trend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                trend.mood.replaceAll('_', ' '),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: VentlyColors.deepBurgundy,
                ),
              ),
            ),
            Text(
              '${trend.count} vents',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: VentlyColors.berryMagenta.withOpacity(0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightTile extends ConsumerWidget {
  const _InsightTile({required this.insight});
  final KeeperAiInsight insight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = switch (insight.severity) {
      'high' => VentlyColors.dangerRed,
      'positive' => const Color(0xFF3D9B6A),
      _ => const Color(0xFFD97706),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              insight.title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              insight.body,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: VentlyColors.deepBurgundy.withOpacity(0.75),
              ),
            ),
            if (insight.action != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _openAction(context, insight.action!),
                child: Text(
                  'Open ${_actionLabel(insight.action!)}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openAction(BuildContext context, String action) {
    switch (action) {
      case 'moderation':
        context.push('/keeper/moderation');
      case 'calendar':
        context.push('/keeper/calendar');
      case 'members':
        context.go('/inbox');
      case 'content':
        context.push('/compose');
      default:
        break;
    }
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'moderation':
        return 'moderation';
      case 'calendar':
        return 'calendar';
      case 'members':
        return 'members';
      case 'content':
        return 'content studio';
      default:
        return action;
    }
  }
}

class _ExportButton extends ConsumerStatefulWidget {
  const _ExportButton({required this.tribeId, required this.tribeName});
  final String tribeId;
  final String tribeName;

  @override
  ConsumerState<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends ConsumerState<_ExportButton> {
  bool _loading = false;

  Future<void> _export() async {
    setState(() => _loading = true);
    try {
      final report = await ref
          .read(repositoryProvider)
          .keeperExportReport(widget.tribeId);
      await Clipboard.setData(ClipboardData(text: report.markdown));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.tribeName} report copied to clipboard.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _loading ? null : _export,
      icon: _loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_rounded, size: 18),
      label: const Text('Export studio report',
          style: TextStyle(fontWeight: FontWeight.w900)),
    );
  }
}
