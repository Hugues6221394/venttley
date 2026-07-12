import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';
import '../navigation/compose_navigation.dart';

/// Keeper Content Studio — operational create menu (prompts, polls, etc.).
Future<void> showKeeperContentStudioSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _KeeperContentStudioSheet(),
  );
}

class _KeeperContentStudioSheet extends ConsumerWidget {
  const _KeeperContentStudioSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);
    final slug = tribe?.slug;

    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      maxChildSize: 0.88,
      minChildSize: 0.45,
      expand: false,
      builder: (_, scroll) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: VentlyColors.softMauve.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Text(
                'Content Studio',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
              Text(
                tribe == null
                    ? 'Create a tribe first to publish community content.'
                    : 'Publishing to ${tribe.name}',
                style: TextStyle(
                  color: context.ink.withOpacity(0.62),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _StudioChip(
                    icon: Icons.lightbulb_outline_rounded,
                    label: 'Prompt',
                    enabled: slug != null,
                    onTap: () => _goManage(context, slug, tab: 'prompts'),
                  ),
                  _StudioChip(
                    icon: Icons.poll_rounded,
                    label: 'Poll',
                    enabled: slug != null,
                    onTap: () {
                      Navigator.pop(context);
                      openCompose(context, ref, format: 'poll');
                    },
                  ),
                  _StudioChip(
                    icon: Icons.campaign_outlined,
                    label: 'Announcement',
                    enabled: slug != null,
                    onTap: () {
                      Navigator.pop(context);
                      openCompose(context, ref, category: 'healing_corner');
                    },
                  ),
                  _StudioChip(
                    icon: Icons.push_pin_outlined,
                    label: 'Pin post',
                    enabled: slug != null,
                    onTap: () => _goManage(context, slug, tab: 'pins'),
                  ),
                  _StudioChip(
                    icon: Icons.schedule_rounded,
                    label: 'Schedule',
                    enabled: slug != null,
                    onTap: () => _goManage(context, slug, tab: 'prompts'),
                  ),
                  _StudioChip(
                    icon: Icons.waving_hand_outlined,
                    label: 'Welcome msg',
                    enabled: slug != null,
                    onTap: () => context.push('/tribe/$slug/edit'),
                  ),
                  _StudioChip(
                    icon: Icons.add_box_outlined,
                    label: 'New space',
                    enabled: slug != null,
                    onTap: () => _goManage(context, slug, tab: 'spaces'),
                  ),
                  _StudioChip(
                    icon: Icons.rule_rounded,
                    label: 'Rules',
                    enabled: slug != null,
                    onTap: () => context.push('/tribe/$slug/edit'),
                  ),
                ],
              ),
              if (slug == null) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    context.push('/tribes/new');
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create your first tribe'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _goManage(BuildContext context, String? slug, {String? tab}) {
    if (slug == null) return;
    Navigator.pop(context);
    final q = tab != null ? '?tab=$tab' : '';
    context.push('/tribe/$slug/manage$q');
  }
}

class _StudioChip extends StatelessWidget {
  const _StudioChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: (MediaQuery.of(context).size.width - 60) / 2,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: VentlyColors.berryMagenta.withOpacity(0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: VentlyColors.berryMagenta.withOpacity(0.18),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: VentlyColors.berryMagenta, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
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
