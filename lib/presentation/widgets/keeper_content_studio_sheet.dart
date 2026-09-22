import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';
import '../theme/motion.dart';
import '../navigation/compose_navigation.dart';
import 'keeper_prompt_composer_sheet.dart';
import 'studio_tribe_selector.dart';

enum KeeperContentStudioAction {
  prompt,
  poll,
  announcement,
  pinPost,
  schedule,
  welcomeMessage,
  newSpace,
  rules,
}

/// Keeper Content Studio — operational create menu (prompts, polls, etc.).
Future<void> showKeeperContentStudioSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final action = await showModalBottomSheet<KeeperContentStudioAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: VentlyMotion.sheetSpring,
    builder: (ctx) => const _KeeperContentStudioSheet(),
  );
  if (action == null || !context.mounted) return;
  // Resolved, not defaulted. This used to read the keeper's *largest*
  // tribe, so a keeper of three could pick "Announcement" and have it
  // published to a community they had not chosen and were not looking at.
  // Under a set scope that scope wins; when it is ambiguous the keeper is
  // asked, and dismissing the picker cancels rather than falling back.
  final tribe = await resolveStudioTargetTribe(context, ref);
  if (tribe == null || !context.mounted) return;

  switch (action) {
    case KeeperContentStudioAction.prompt:
      await showKeeperPromptComposer(context, tribeId: tribe.tribeId);
      return;
    case KeeperContentStudioAction.poll:
      ref.read(composeTargetTribeProvider.notifier).state = tribe;
      ref.read(composeTargetSpaceProvider.notifier).state = null;
      openCompose(context, ref, format: 'poll');
      return;
    case KeeperContentStudioAction.announcement:
      ref.read(composeTargetTribeProvider.notifier).state = tribe;
      ref.read(composeTargetSpaceProvider.notifier).state = null;
      openCompose(
        context,
        ref,
        category: tribe.category,
        draft: 'Announcement: ',
      );
      return;
    case KeeperContentStudioAction.pinPost:
      context.push('/tribe/${tribe.slug}/manage/settings/content?action=pin');
      return;
    case KeeperContentStudioAction.schedule:
      await showKeeperPromptComposer(
        context,
        tribeId: tribe.tribeId,
        scheduleRequired: true,
      );
      return;
    case KeeperContentStudioAction.welcomeMessage:
      context.push(
        '/tribe/${tribe.slug}/manage/settings/identity?focus=welcome',
      );
      return;
    case KeeperContentStudioAction.newSpace:
      context.push('/tribe/${tribe.slug}/manage/settings/spaces?create=true');
      return;
    case KeeperContentStudioAction.rules:
      context.push('/tribe/${tribe.slug}/manage/settings/rules');
      return;
  }
}

class _KeeperContentStudioSheet extends ConsumerWidget {
  const _KeeperContentStudioSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // What this sheet needs to know is whether the keeper has anywhere to
    // publish — not whether they have picked a scope.
    //
    // It asked studioSelectedTribeProvider, which is null until somebody
    // explicitly chooses a tribe from the rail. A keeper of one tribe never
    // sees that rail, so the scope was always null and every action here was
    // disabled under the words "Create a tribe first to publish community
    // content" — said to somebody who was, at that moment, looking at their
    // own tribe's name three rows above. A keeper of three on All Tribes got
    // the same dead sheet.
    //
    // Every action already resolves its own target through
    // resolveStudioTargetTribe, which picks the scoped tribe, or the only one,
    // or asks. So the sheet is enabled whenever a tribe exists, and the
    // subtitle names the destination only when it is already unambiguous.
    final tribe = ref.watch(studioFocusTribeProvider);
    final canPublish = ref.watch(studioScopedTribesProvider).isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      maxChildSize: 0.88,
      minChildSize: 0.45,
      expand: false,
      builder: (_, scroll) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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
                !canPublish
                    ? 'Create a tribe first to publish community content.'
                    : tribe != null
                    ? 'Publishing to ${tribe.name}'
                    : 'You will be asked which tribe to publish to.',
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
                    enabled: canPublish,
                    onTap: () => Navigator.pop(
                      context,
                      KeeperContentStudioAction.prompt,
                    ),
                  ),
                  _StudioChip(
                    icon: Icons.poll_rounded,
                    label: 'Poll',
                    enabled: canPublish,
                    onTap: () =>
                        Navigator.pop(context, KeeperContentStudioAction.poll),
                  ),
                  _StudioChip(
                    icon: Icons.campaign_outlined,
                    label: 'Announcement',
                    enabled: canPublish,
                    onTap: () => Navigator.pop(
                      context,
                      KeeperContentStudioAction.announcement,
                    ),
                  ),
                  _StudioChip(
                    icon: Icons.push_pin_outlined,
                    label: 'Pin post',
                    enabled: canPublish,
                    onTap: () => Navigator.pop(
                      context,
                      KeeperContentStudioAction.pinPost,
                    ),
                  ),
                  _StudioChip(
                    icon: Icons.schedule_rounded,
                    label: 'Schedule',
                    enabled: canPublish,
                    onTap: () => Navigator.pop(
                      context,
                      KeeperContentStudioAction.schedule,
                    ),
                  ),
                  _StudioChip(
                    icon: Icons.waving_hand_outlined,
                    label: 'Welcome msg',
                    enabled: canPublish,
                    onTap: () => Navigator.pop(
                      context,
                      KeeperContentStudioAction.welcomeMessage,
                    ),
                  ),
                  _StudioChip(
                    icon: Icons.add_box_outlined,
                    label: 'New space',
                    enabled: canPublish,
                    onTap: () => Navigator.pop(
                      context,
                      KeeperContentStudioAction.newSpace,
                    ),
                  ),
                  _StudioChip(
                    icon: Icons.rule_rounded,
                    label: 'Rules',
                    enabled: canPublish,
                    onTap: () =>
                        Navigator.pop(context, KeeperContentStudioAction.rules),
                  ),
                ],
              ),
              if (!canPublish) ...[
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
