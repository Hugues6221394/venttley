import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/keeper/keeper_studio_v2.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import 'keeper_studio_scaffold.dart';

/// Moderation Center — unified reports queue + safety shortcuts.
class KeeperModerationCenterScreen extends ConsumerWidget {
  const KeeperModerationCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);
    final tribeId = tribe?.tribeId;
    final queueAsync = tribeId == null
        ? const AsyncValue<KeeperModerationQueue>.loading()
        : ref.watch(keeperModerationQueueProvider(tribeId));

    return KeeperStudioScaffold(
      title: 'Moderation Center',
      subtitle: 'Reports, filters, and member safety',
      onRefresh: () async {
        if (tribeId != null) {
          ref.invalidate(keeperModerationQueueProvider(tribeId));
        }
      },
      child: queueAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
          ),
        ),
        error: (e, _) => Text('Could not load queue: $e'),
        data: (queue) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _StatChip(
                    icon: Icons.flag_rounded,
                    label: 'Open reports',
                    value: '${queue.items.length}',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatChip(
                    icon: Icons.filter_alt_rounded,
                    label: 'Keyword filters',
                    value: '${queue.keywordFilterCount}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _StatChip(
              icon: Icons.warning_amber_rounded,
              label: 'Warnings (30d)',
              value: '${queue.warnings30d}',
            ),
            const SizedBox(height: 16),
            if (tribe != null) ...[
              FilledButton.icon(
                onPressed: () =>
                    context.push('/tribe/${tribe.slug}/manage/moderation'),
                icon: const Icon(Icons.rule_rounded, size: 18),
                label: const Text('Rules & keyword filters',
                    style: TextStyle(fontWeight: FontWeight.w900)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    context.push('/tribe/${tribe.slug}/manage/reports'),
                icon: const Icon(Icons.inbox_rounded, size: 18),
                label: const Text('Full reports queue',
                    style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              'Priority queue',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 10),
            if (queue.items.isEmpty)
              GlassCard(
                child: Text(
                  'No open reports — your tribe looks calm right now.',
                  style: TextStyle(
                    color: context.ink.withOpacity(0.7),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              ...queue.items.map((item) => _ReportTile(item: item)),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: VentlyColors.berryMagenta, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    color: context.ink,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: context.ink.withOpacity(0.55),
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

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.item});
  final KeeperModerationItem item;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat.MMMd().add_jm();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: VentlyColors.dangerRed.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    item.reason.replaceAll('_', ' '),
                    style: const TextStyle(
                      color: VentlyColors.dangerRed,
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  fmt.format(item.createdAt.toLocal()),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: context.ink.withOpacity(0.5),
                  ),
                ),
              ],
            ),
            if (item.postSnippet != null) ...[
              const SizedBox(height: 8),
              Text(
                item.postSnippet!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: context.ink,
                ),
              ),
            ],
            if (item.reporterPseudonym != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Flagged by @${item.reporterPseudonym}',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.ink.withOpacity(0.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
