import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import '../theme/glass_tokens.dart';

/// What happened in the tribes you keep.
///
/// Separate from the ordinary notification bell on purpose. A keeper running
/// four tribes has a different job from a person catching up on likes, and
/// mixing them means the thing with a clock on it — a report — sits between
/// two reactions.
///
/// Opening it marks it read. A badge that needs a second gesture to clear is a
/// badge people stop believing.
Future<void> showKeeperNotificationCentre(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const _KeeperNotificationCentre(),
  );
}

class _KeeperNotificationCentre extends ConsumerStatefulWidget {
  const _KeeperNotificationCentre();

  @override
  ConsumerState<_KeeperNotificationCentre> createState() =>
      _KeeperNotificationCentreState();
}

class _KeeperNotificationCentreState
    extends ConsumerState<_KeeperNotificationCentre> {
  @override
  void initState() {
    super.initState();
    // Marked read on open, not on close: somebody who reads two lines and
    // swipes away has still seen them, and leaving the badge up would teach
    // them to ignore it.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(repositoryProvider).markKeeperNotificationsRead();
      if (!mounted) return;
      ref.invalidate(keeperUnreadCountProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(keeperNotificationsProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: GlassTokens.onCardMuted(context).withOpacity(0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Your tribes',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          Expanded(
            child: switch (async) {
              AsyncValue(hasValue: true, :final value?) when value.isNotEmpty =>
                ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                  itemCount: value.length,
                  itemBuilder: (context, i) => _Row(item: value[i]),
                ),
              AsyncValue(hasValue: true) => _Empty(),
              AsyncValue(hasError: true) => const _Message(
                'Could not load this just now.',
              ),
              _ => const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item});
  final KeeperNotification item;

  /// Where this lands. A request and a report are decisions, so they open the
  /// screen where the decision is made rather than the tribe's front page.
  String? _destination() {
    final slug = item.tribeSlug;
    if (slug == null) return null;
    return switch (item.kind) {
      'tribe_join_request' => '/tribe/$slug/manage/settings/members',
      'tribe_report_filed' => '/tribe/$slug/manage/reports',
      'tribe_member_joined' => '/tribe/$slug/manage/settings/members',
      _ => '/tribe/$slug',
    };
  }

  (IconData, Color) _glyph(BuildContext context) => switch (item.kind) {
    'tribe_report_filed' => (Icons.flag_rounded, VentlyColors.dangerRed),
    'tribe_join_request' => (
      Icons.how_to_reg_rounded,
      VentlyColors.berryMagenta,
    ),
    'tribe_member_joined' => (
      Icons.waving_hand_rounded,
      VentlyColors.successGreen,
    ),
    'tribe_ownership_transfer' => (
      Icons.swap_horiz_rounded,
      VentlyColors.berryMagenta,
    ),
    _ => (Icons.campaign_outlined, GlassTokens.onCardMuted(context)),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, colour) = _glyph(context);
    final to = _destination();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: colour.withOpacity(0.14),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 19, color: colour),
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.w700 : FontWeight.w900,
        ),
      ),
      subtitle: Text(
        item.body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          color: GlassTokens.onCardMuted(context),
        ),
      ),
      trailing: item.isUrgent && !item.isRead
          ? const Icon(Icons.circle, size: 8, color: VentlyColors.dangerRed)
          : null,
      onTap: to == null
          ? null
          : () {
              Navigator.of(context).pop();
              context.push(to);
            },
    );
  }
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const _Message(
    'Nothing needs you right now.\nJoin requests and reports land here.',
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.onCardMuted(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_rounded, size: 30, color: muted),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
