import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import '../theme/glass_tokens.dart';
import 'premium_motion.dart';
import 'tribe_avatar.dart';

/// The Studio's scope control — `[All Tribes ▼]`.
///
/// Every Studio page reads [studioTribeScopeProvider], so this one pill is
/// what makes a keeper of three tribes able to see all three. Before it, nine
/// screens watched `primaryKeeperTribeProvider` and silently rendered the
/// largest tribe only.
///
/// Renders nothing for a keeper with one tribe. A dropdown with a single
/// option is furniture, and worse, it implies there is something else to pick.
class StudioTribeSelector extends ConsumerWidget {
  const StudioTribeSelector({super.key, this.dense = false});

  /// Tighter type and padding, for a screen's app-bar row rather than a hero.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(studioHasMultipleTribesProvider)) {
      return const SizedBox.shrink();
    }

    final selected = ref.watch(studioSelectedTribeProvider);
    final tribes = ref.watch(tribesIKeepProvider).valueOrNull ?? const <Tribe>[];
    final label = selected?.name ?? 'All Tribes';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      button: true,
      label: 'Studio scope: $label. Tap to change which tribe you are viewing.',
      child: Pressable(
        onTap: () => _open(context, ref, tribes),
        child: Container(
          padding: dense
              ? const EdgeInsets.fromLTRB(10, 6, 8, 6)
              : const EdgeInsets.fromLTRB(12, 8, 10, 8),
          decoration: BoxDecoration(
            // Tinted rather than filled: it sits over the premium background
            // and a solid chip would read as a button to press, not as a
            // statement of what you are looking at.
            color: VentlyColors.berryMagenta.withOpacity(isDark ? 0.18 : 0.09),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: VentlyColors.berryMagenta.withOpacity(0.28),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected == null
                    ? Icons.workspaces_rounded
                    : Icons.diversity_3_rounded,
                size: dense ? 15 : 16,
                color: VentlyColors.berryMagenta,
              ),
              SizedBox(width: dense ? 6 : 7),
              // Capped so a long tribe name cannot push the chevron off the
              // row or force the app-bar title to wrap.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: dense ? 116 : 168),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: dense ? 12.5 : 13.5,
                    fontWeight: FontWeight.w900,
                    color: VentlyColors.berryMagenta,
                  ),
                ),
              ),
              SizedBox(width: dense ? 2 : 3),
              Icon(
                Icons.expand_more_rounded,
                size: dense ? 16 : 18,
                color: VentlyColors.berryMagenta,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    List<Tribe> tribes,
  ) async {
    HapticFeedback.selectionClick();
    final picked = await showModalBottomSheet<_Choice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ScopeSheet(tribes: tribes),
    );
    if (picked == null) return;
    // A no-op re-selection must not invalidate anything — every scoped
    // provider watches this, so writing the same value would refetch the
    // whole Studio for nothing.
    final current = ref.read(studioTribeScopeProvider);
    if (current == picked.tribeId) return;
    ref.read(studioTribeScopeProvider.notifier).state = picked.tribeId;
  }
}

/// Wrapper so "All Tribes" (a null id) is distinguishable from a dismissed
/// sheet (a null result).
class _Choice {
  const _Choice(this.tribeId);
  final String? tribeId;
}

/// Which tribe a Studio *write* should go to.
///
/// Reading under All Tribes is fine — a KPI can be a sum. Writing is not:
/// publishing an announcement or a prompt has to land in one community, and
/// picking the largest one on the keeper's behalf is how a message meant for
/// a small support tribe ends up in front of a big one. So:
///
///  * a scoped tribe is the target;
///  * a keeper with exactly one tribe has no ambiguity to resolve;
///  * otherwise ask, and remember the answer as the Studio scope so the next
///    action in the same session does not ask again.
///
/// Returns null when the keeper dismisses the picker, which callers must treat
/// as "cancel", not as "use a default".
Future<Tribe?> resolveStudioTargetTribe(
  BuildContext context,
  WidgetRef ref,
) async {
  // Awaited rather than read as a snapshot. `ref.read(provider).valueOrNull`
  // is null the first time anything asks — the request has only just started —
  // so a snapshot here silently returned "cancel" and the keeper's tap on
  // Announcement or Chat did nothing at all, with no message. Awaiting the
  // future is the difference between "no tribes" and "not loaded yet".
  final List<Tribe> tribes;
  try {
    tribes = await ref.read(tribesIKeepProvider.future);
  } catch (_) {
    return null;
  }
  if (!context.mounted) return null;
  if (tribes.isEmpty) return null;

  // The scope is resolved against the list just fetched, for the same reason.
  final scopedId = ref.read(studioTribeScopeProvider);
  if (scopedId != null) {
    for (final tribe in tribes) {
      if (tribe.tribeId == scopedId) return tribe;
    }
  }
  if (tribes.length == 1) return tribes.first;

  final picked = await showModalBottomSheet<_Choice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // allowAll: false — "All Tribes" is not a destination you can post to.
    builder: (ctx) => _ScopeSheet(tribes: tribes, allowAll: false),
  );
  final id = picked?.tribeId;
  if (id == null) return null;

  ref.read(studioTribeScopeProvider.notifier).state = id;
  for (final tribe in tribes) {
    if (tribe.tribeId == id) return tribe;
  }
  return null;
}

class _ScopeSheet extends ConsumerWidget {
  const _ScopeSheet({required this.tribes, this.allowAll = true});
  final List<Tribe> tribes;

  /// False when the sheet is choosing a write target rather than a
  /// viewing scope — there is no such place as All Tribes to post to.
  final bool allowAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(studioTribeScopeProvider);
    final totalMembers = tribes.fold<int>(0, (sum, t) => sum + t.memberCount);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: isDark ? VentlyColors.cardDark : Colors.white,
          borderRadius: BorderRadius.circular(GlassTokens.radiusCard),
          boxShadow: GlassTokens.elevation(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            // Grabber, so the sheet reads as draggable before it is touched.
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: context.ink.withOpacity(0.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      allowAll ? 'Viewing' : 'Post to',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: context.ink,
                      ),
                    ),
                  ),
                  Text(
                    '${tribes.length} tribes',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: context.ink.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
                children: [
                  if (allowAll) ...[
                    _ScopeRow(
                      icon: Icons.workspaces_rounded,
                      title: 'All Tribes',
                      subtitle:
                          '$totalMembers '
                          '${totalMembers == 1 ? 'member' : 'members'} '
                          'across ${tribes.length}',
                      selected: selectedId == null,
                      onTap: () =>
                          Navigator.pop(context, const _Choice(null)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: Divider(
                        height: 1,
                        color: context.ink.withOpacity(0.07),
                      ),
                    ),
                  ],
                  for (final tribe in tribes)
                    _ScopeRow(
                      avatarUrl: tribe.avatarUrl,
                      title: tribe.name,
                      subtitle:
                          '${tribe.memberCount} '
                          '${tribe.memberCount == 1 ? 'member' : 'members'}',
                      selected: selectedId == tribe.tribeId,
                      onTap: () =>
                          Navigator.pop(context, _Choice(tribe.tribeId)),
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

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.icon,
    this.avatarUrl,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? VentlyColors.berryMagenta.withOpacity(0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              if (icon != null)
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: VentlyColors.berryMagenta,
                  ),
                )
              else
                TribeAvatar(avatarUrl: avatarUrl, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: context.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: context.ink.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
              // A check, not a radio. The scope is a filter you are already
              // looking through, not a form you are filling in.
              AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: selected ? 1 : 0,
                child: const Icon(
                  Icons.check_circle_rounded,
                  size: 21,
                  color: VentlyColors.berryMagenta,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
