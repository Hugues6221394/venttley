import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/user_friendly_errors.dart';
import '../../domain/tribe/tribe_management.dart';
import '../theme/colors.dart';

/// Where the signed-in member stands relative to a Tribe's rules.
///
/// Declared here rather than in the shared providers file so that a change to
/// this feature does not collide with unrelated work in a file half the app
/// imports.
final tribeRulesStatusProvider =
    FutureProvider.family<TribeRulesStatus, String>((ref, tribeId) async {
      return ref.read(repositoryProvider).myTribeRulesStatus(tribeId);
    });

/// Shown to a member when the Keeper has published rules since they joined.
///
/// Renders nothing at all in every other case — including while loading and on
/// error. A rules notice is only meaningful when the server has confirmed
/// there is one, and a bar that flickers in on every screen build would train
/// people to dismiss it without reading, which is the opposite of the point.
class TribeRulesUpdatedBanner extends ConsumerWidget {
  const TribeRulesUpdatedBanner({super.key, required this.tribeId});

  final String tribeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(tribeRulesStatusProvider(tribeId)).valueOrNull;
    if (status == null || !status.needsAcknowledgement) {
      return const SizedBox.shrink();
    }

    final note = status.changeNote?.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: VentlyColors.roseTint,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _open(context, ref, status),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.gavel_rounded,
                  size: 18,
                  color: VentlyColors.berryMagenta,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'The rules changed',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        note == null || note.isEmpty
                            ? 'Have a read — it takes a minute.'
                            : note,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: context.ink.withOpacity(.72),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: VentlyColors.berryMagenta,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    TribeRulesStatus status,
  ) async {
    final acknowledged = await showModalBottomSheet<bool>(
      context: context,
      // The Tribe screen sits inside the shell, whose floating nav paints over
      // anything the branch puts near the bottom of the screen.
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _RulesSheet(tribeId: tribeId, status: status),
    );
    if (acknowledged == true) {
      ref.invalidate(tribeRulesStatusProvider(tribeId));
    }
  }
}

class _RulesSheet extends ConsumerStatefulWidget {
  const _RulesSheet({required this.tribeId, required this.status});

  final String tribeId;
  final TribeRulesStatus status;

  @override
  ConsumerState<_RulesSheet> createState() => _RulesSheetState();
}

class _RulesSheetState extends ConsumerState<_RulesSheet> {
  bool _saving = false;
  String? _error;

  Future<void> _acknowledge() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Confirms the version that was actually rendered above, not whatever is
      // current by the time the button is pressed — a Keeper publishing while
      // this sheet is open should produce another notice, not a silent pass.
      await ref
          .read(repositoryProvider)
          .acknowledgeTribeRules(widget.tribeId, widget.status.version);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = UserFriendlyErrors.message(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = widget.status;
    final note = status.changeNote?.trim();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * .8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withOpacity(.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'The rules changed',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    // Naming the version is not decoration. If a member is
                    // ever removed for breaking a rule, both sides need to be
                    // able to point at the same numbered text.
                    'Version ${status.version}'
                    '${status.publishedAt == null ? '' : ' • ${_shortDate(status.publishedAt!)}'}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface.withOpacity(.6),
                    ),
                  ),
                  if (note != null && note.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: VentlyColors.roseTint,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        note,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
                itemCount: status.rules.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, index) {
                  final rule = status.rules[index];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          '${index + 1}.',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: VentlyColors.berryMagenta,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rule.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                            if ((rule.description ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                rule.description!.trim(),
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.35,
                                  color: scheme.onSurface.withOpacity(.72),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: VentlyColors.berryMagenta,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _acknowledge,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          "Got it, I've read these",
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortDate(DateTime when) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[when.month - 1]} ${when.day}, ${when.year}';
  }
}
