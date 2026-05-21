import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';

/// Per-tribe report queue. Keeper-only — RLS on `reports` (migration 0008)
/// rejects reads from anyone else.
class TribeReportsScreen extends ConsumerWidget {
  const TribeReportsScreen({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribeAsync = ref.watch(tribeBySlugProvider(slug));
    final tribe = tribeAsync.valueOrNull;
    final me = ref.watch(sessionProvider);
    if (tribe == null) {
      return Scaffold(
        appBar: AppBar(),
        body: tribeAsync.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const Center(child: Text('Tribe not found')),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        appBar: AppBar(title: Text(tribe.name)),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Reports for this Tribe are visible to its Keeper only.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
    }
    final reportsAsync = ref.watch(tribeReportsProvider(tribe.tribeId));
    final reports = reportsAsync.valueOrNull ?? const <TribeReport>[];
    final pending = reports.where((r) => !r.isResolved).toList();
    final resolved = reports.where((r) => r.isResolved).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Reports · ${tribe.name}', overflow: TextOverflow.ellipsis),
      ),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.invalidate(tribeReportsProvider(tribe.tribeId)),
        child: reportsAsync.isLoading && reports.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _SectionHeader(
                    label: 'Pending',
                    count: pending.length,
                    danger: pending.isNotEmpty,
                  ),
                  if (pending.isEmpty)
                    const _SoftEmpty(
                      icon: Icons.check_circle_outline,
                      text: 'Nothing pending. Your Tribe is calm right now.',
                    )
                  else
                    for (final r in pending)
                      _ReportCard(
                        report: r,
                        tribeId: tribe.tribeId,
                      ),
                  if (resolved.isNotEmpty) ...[
                    _SectionHeader(label: 'Resolved', count: resolved.length),
                    for (final r in resolved)
                      _ReportCard(
                        report: r,
                        tribeId: tribe.tribeId,
                      ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.count,
    this.danger = false,
  });
  final String label;
  final int count;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: danger
                  ? scheme.primary.withOpacity(0.16)
                  : scheme.onSurface.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: danger ? scheme.primary : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportCard extends ConsumerWidget {
  const _ReportCard({required this.report, required this.tribeId});
  final TribeReport report;
  final String tribeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: report.isResolved
              ? scheme.onSurface.withOpacity(0.08)
              : scheme.primary.withOpacity(isDark ? 0.30 : 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  report.reasonLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                DateFormat.MMMd().add_jm().format(report.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
              const Spacer(),
              if (report.isResolved)
                const Row(
                  children: [
                    Icon(Icons.check_circle,
                        size: 14, color: VentlyColors.successGreen),
                    SizedBox(width: 4),
                    Text(
                      'Resolved',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: VentlyColors.successGreen,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (report.postDeleted)
            Text(
              'Post already deleted.',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: scheme.onSurface.withOpacity(0.55),
              ),
            )
          else
            Text(
              report.postPreview.isEmpty ? '(empty post)' : report.postPreview,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, height: 1.35),
            ),
          if (report.note != null && report.note!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Reporter note: ${report.note}',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurface.withOpacity(0.65),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () =>
                    context.push('/post/${report.postId}'),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Open post'),
              ),
              const Spacer(),
              if (!report.isResolved)
                ElevatedButton.icon(
                  icon: const Icon(Icons.check, size: 16),
                  onPressed: () async {
                    try {
                      await ref
                          .read(repositoryProvider)
                          .resolveReport(report.reportId);
                      ref.invalidate(tribeReportsProvider(tribeId));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Marked resolved.')),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not resolve: $e')),
                      );
                    }
                  },
                  label: const Text('Mark resolved'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SoftEmpty extends StatelessWidget {
  const _SoftEmpty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          children: [
            Icon(icon, size: 36, color: scheme.primary.withOpacity(0.6)),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
