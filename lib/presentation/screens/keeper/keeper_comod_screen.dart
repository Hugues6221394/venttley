import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/keeper/keeper_studio_v2.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/glass_card.dart';
import 'keeper_studio_scaffold.dart';

/// Co-mod permissions grid — who can warn, kick, pin, and schedule.
class KeeperComodScreen extends ConsumerWidget {
  const KeeperComodScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);
    final tribeId = tribe?.tribeId;
    final matrixAsync = tribeId == null
        ? const AsyncValue<KeeperComodMatrix>.loading()
        : ref.watch(keeperComodMatrixProvider(tribeId));

    return KeeperStudioScaffold(
      title: 'Co-mod permissions',
      subtitle: 'Keeper + moderator capability matrix',
      onRefresh: () async {
        if (tribeId != null) {
          ref.invalidate(keeperComodMatrixProvider(tribeId));
        }
      },
      child: matrixAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
          ),
        ),
        error: (e, _) => Text('Could not load team: $e'),
        data: (matrix) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tribe != null && matrix.callerIsKeeper)
              FilledButton.icon(
                onPressed: () => context.push(
                  '/tribe/${tribe.slug}/manage/settings/members',
                ),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text(
                  'Promote members to mod',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Permission grid',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 10),
            ...matrix.mods.map((row) => _ModCard(row: row)),
            const SizedBox(height: 12),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Legend',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: context.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const _LegendRow(
                    label: 'Keeper',
                    detail: 'Full control — promote, kick mods, transfer',
                  ),
                  const _LegendRow(
                    label: 'Mod',
                    detail: 'Warn, review reports, pin, schedule, kick members',
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

class _ModCard extends StatelessWidget {
  const _ModCard({required this.row});
  final KeeperComodRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnonymousAvatar(
                  seed: row.avatarSeed ?? row.pseudonym,
                  label: row.pseudonym,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@${row.pseudonym}',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: context.ink,
                        ),
                      ),
                      Text(
                        row.role == 'keeper' ? 'Keeper' : 'Co-mod',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: VentlyColors.berryMagenta.withOpacity(0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _PermChip('Warn', row.canWarn),
                _PermChip('Reports', row.canReviewReports),
                _PermChip('Pin', row.canPin),
                _PermChip('Schedule', row.canSchedule),
                _PermChip('Kick members', row.canKickMembers),
                _PermChip('Kick mods', row.canKickMods),
                _PermChip('Promote', row.canPromote),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermChip extends StatelessWidget {
  const _PermChip(this.label, this.enabled);
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: enabled
            ? VentlyColors.berryMagenta.withOpacity(0.12)
            : Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: enabled
              ? VentlyColors.berryMagenta
              : context.ink.withOpacity(0.35),
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.label, required this.detail});
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            color: context.ink.withOpacity(0.7),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
          children: [
            TextSpan(
              text: '$label — ',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            TextSpan(text: detail),
          ],
        ),
      ),
    );
  }
}
