import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';

/// Plug-only dashboard. Each plug keeps one or more tribes; this is
/// the landing they hit instead of the public profile when they
/// open "my space". It surfaces the things a tribe manager actually
/// needs in one tap: tribe roster, rules, premium toggle, and the
/// pencil for name + avatar + question-of-the-day.
class PlugDashboardScreen extends ConsumerWidget {
  const PlugDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final tribesAsync = ref.watch(tribesIKeepProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Keeper dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(tribesIKeepProvider),
          ),
        ],
      ),
      body: tribesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load tribes: $e')),
        data: (tribes) {
          if (tribes.isEmpty) {
            return const _EmptyState();
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _PlugGreeting(me: me),
              const SizedBox(height: 14),
              _SummaryStrip(tribes: tribes),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Tribes you manage',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: context.ink,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              for (final t in tribes) _TribeManageCard(tribe: t),
            ],
          );
        },
      ),
    );
  }
}

class _PlugGreeting extends StatelessWidget {
  const _PlugGreeting({required this.me});
  final dynamic me;

  @override
  Widget build(BuildContext context) {
    final name = me?.anonymousPseudonym ?? 'Keeper';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [VentlyColors.berryMagenta, VentlyColors.deepBurgundy],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hey @$name',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Take care of your tribe today.',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.tribes});
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    final totalMembers = tribes.fold<int>(0, (s, t) => s + t.memberCount);
    final premiumCount = tribes.where((t) => t.isPremium).length;
    return Row(
      children: [
        _SummaryTile(
          label: 'Tribes',
          value: tribes.length.toString(),
          icon: Icons.diversity_3_rounded,
        ),
        const SizedBox(width: 10),
        _SummaryTile(
          label: 'Members',
          value: PostCard.compactNumber(totalMembers),
          icon: Icons.groups_rounded,
        ),
        const SizedBox(width: 10),
        _SummaryTile(
          label: 'Premium',
          value: premiumCount.toString(),
          icon: Icons.workspace_premium_rounded,
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: VentlyColors.berryMagenta, size: 18),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 20,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                color: context.ink.withOpacity(0.55),
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TribeManageCard extends ConsumerWidget {
  const _TribeManageCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: VentlyColors.berryMagenta.withOpacity(0.12),
                backgroundImage: tribe.avatarUrl != null
                    ? NetworkImage(tribe.avatarUrl!)
                    : null,
                child: tribe.avatarUrl == null
                    ? const Icon(
                        Icons.diversity_3,
                        color: VentlyColors.berryMagenta,
                        size: 22,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            tribe.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (tribe.isPremium) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.workspace_premium_rounded,
                            size: 14,
                            color: VentlyColors.berryMagenta,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${PostCard.compactNumber(tribe.memberCount)} members · ${tribe.category}',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.55),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ManageChip(
                icon: Icons.gavel_rounded,
                label: tribe.rules == null || tribe.rules!.isEmpty
                    ? 'Add rules'
                    : 'Edit rules',
                onTap: () => _openRulesEditor(context, ref),
              ),
              _ManageChip(
                icon: tribe.isPremium
                    ? Icons.workspace_premium_rounded
                    : Icons.workspace_premium_outlined,
                label: tribe.isPremium ? 'Premium · ON' : 'Make premium',
                onTap: () => _togglePremium(context, ref),
              ),
              _ManageChip(
                icon: Icons.edit_outlined,
                label: 'Name & avatar',
                onTap: () => _openBrandingSheet(context, ref),
              ),
              _ManageChip(
                icon: Icons.help_outline_rounded,
                label: 'Question of the day',
                onTap: () => context.push('/tribe/${tribe.slug}/manage'),
              ),
              _ManageChip(
                icon: Icons.settings_outlined,
                label: 'Open full manage',
                onTap: () => context.push('/tribe/${tribe.slug}/manage'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openRulesEditor(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: tribe.rules ?? '');
    final saved = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rules for ${tribe.name}'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 8,
            maxLength: 1200,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
                  '1. Be kind.\n2. No outing identities.\n3. Crisis → ping a mod.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save rules'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .updateTribeManagement(tribeId: tribe.tribeId, rules: saved);
      if (ok) {
        ref.invalidate(tribesIKeepProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Rules saved')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
      }
    }
  }

  Future<void> _togglePremium(BuildContext context, WidgetRef ref) async {
    final next = !tribe.isPremium;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(next ? 'Turn premium ON?' : 'Turn premium OFF?'),
        content: Text(
          next
              ? 'Premium tribes can gate access. Billing wiring will follow — for now this just flips the badge and unlocks the keeper-only features list.'
              : 'Members keep their access. The premium badge disappears.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(next ? 'Turn ON' : 'Turn OFF'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .updateTribeManagement(tribeId: tribe.tribeId, isPremium: next);
      if (ok) {
        ref.invalidate(tribesIKeepProvider);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t toggle: $e')));
      }
    }
  }

  Future<void> _openBrandingSheet(BuildContext context, WidgetRef ref) async {
    final nameCtl = TextEditingController(text: tribe.name);
    final avatarCtl = TextEditingController(text: tribe.avatarUrl ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tribe branding'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                maxLength: 60,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Tribe name',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: avatarCtl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Avatar image URL',
                  hintText: 'https://…',
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Direct upload from device is coming next; paste a hosted URL for now.',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .updateTribeManagement(
            tribeId: tribe.tribeId,
            name: nameCtl.text.trim().isEmpty ? null : nameCtl.text.trim(),
            avatarUrl: avatarCtl.text.trim().isEmpty
                ? null
                : avatarCtl.text.trim(),
          );
      if (ok) {
        ref.invalidate(tribesIKeepProvider);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
      }
    }
  }
}

class _ManageChip extends StatelessWidget {
  const _ManageChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: VentlyColors.berryMagenta),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.diversity_3,
              size: 48,
              color: VentlyColors.berryMagenta,
            ),
            const SizedBox(height: 12),
            Text(
              'No tribes to manage yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Once you create or are assigned a tribe, it\'ll appear here with the management tools.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink.withOpacity(0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
