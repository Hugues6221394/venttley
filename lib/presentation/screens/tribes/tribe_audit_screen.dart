import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/vently_premium_background.dart';

class TribeAuditScreen extends ConsumerStatefulWidget {
  const TribeAuditScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<TribeAuditScreen> createState() => _TribeAuditScreenState();
}

class _TribeAuditScreenState extends ConsumerState<TribeAuditScreen> {
  String filter = 'all';

  @override
  Widget build(BuildContext context) {
    final tribe = ref.watch(tribeBySlugProvider(widget.slug)).valueOrNull;
    final me = ref.watch(sessionProvider);
    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Audit history')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'Only the current Keeper can view Tribe audit history.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }
    final events = ref.watch(tribeAuditLogProvider(tribe.tribeId));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'Audit history',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: VentlyPremiumBackground(
        child: RefreshIndicator(
          color: VentlyColors.berryMagenta,
          onRefresh: () async {
            ref.invalidate(tribeAuditLogProvider(tribe.tribeId));
            await ref.read(tribeAuditLogProvider(tribe.tribeId).future);
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              const SliverToBoxAdapter(child: _AuditIntro()),
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  child: Row(
                    children: [
                      for (final option in const [
                        ('all', 'All'),
                        ('member', 'Members'),
                        ('space', 'Spaces'),
                        ('post', 'Content'),
                        ('tribe', 'Settings'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            selected: filter == option.$1,
                            label: Text(option.$2),
                            onSelected: (_) =>
                                setState(() => filter = option.$1),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              events.when(
                loading: () => const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => SliverFillRemaining(
                  child: Center(child: Text('Could not load history: $error')),
                ),
                data: (items) {
                  final visible = items
                      .where(
                        (event) =>
                            filter == 'all' || event.targetType == filter,
                      )
                      .toList(growable: false);
                  if (visible.isEmpty) {
                    return const SliverFillRemaining(
                      child: Center(
                        child: Text('No management actions in this view yet.'),
                      ),
                    );
                  }
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 48),
                    sliver: SliverList.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) => _AuditEventCard(
                        event: visible[index],
                        showLine: index < visible.length - 1,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditIntro extends StatelessWidget {
  const _AuditIntro();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: GlassCard(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: VentlyColors.berryMagenta.withOpacity(.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.verified_user_outlined,
                color: VentlyColors.berryMagenta,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Accountable by design',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    'Sensitive owner and moderator actions are recorded with actor, time, target, and reason.',
                    style: TextStyle(
                      color: context.ink.withOpacity(.58),
                      fontSize: 11,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
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

class _AuditEventCard extends StatelessWidget {
  const _AuditEventCard({required this.event, required this.showLine});

  final TribeAuditEvent event;
  final bool showLine;

  @override
  Widget build(BuildContext context) {
    final presentation = _presentation(event.action);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: presentation.color.withOpacity(.11),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    presentation.icon,
                    size: 16,
                    color: presentation.color,
                  ),
                ),
                if (showLine)
                  Expanded(
                    child: Container(width: 1, color: context.glassBorder),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassCard(
                padding: const EdgeInsets.all(13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      presentation.label,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '@${event.actorPseudonym ?? 'system'} · ${_formatUtc(event.createdAt)}',
                      style: TextStyle(
                        color: context.ink.withOpacity(.55),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (event.reason?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 7),
                      Text(
                        event.reason!,
                        style: TextStyle(
                          color: context.ink.withOpacity(.72),
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (event.targetType != null) ...[
                      const SizedBox(height: 7),
                      Text(
                        '${event.targetType!.toUpperCase()}${event.targetId == null ? '' : ' · ${event.targetId}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: VentlyColors.berryMagenta,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

({String label, IconData icon, Color color}) _presentation(String action) {
  final normalized = action.replaceAll('_', ' ').toLowerCase();
  final label = normalized
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
  if (action.startsWith('MEMBER_') || action.startsWith('JOIN_REQUEST_')) {
    return (
      label: label,
      icon: Icons.group_outlined,
      color: const Color(0xFF2D7D6E),
    );
  }
  if (action.startsWith('SPACE_')) {
    return (
      label: label,
      icon: Icons.view_quilt_outlined,
      color: const Color(0xFF3D6BD8),
    );
  }
  if (action.startsWith('POST_')) {
    return (
      label: label,
      icon: Icons.forum_outlined,
      color: const Color(0xFF8A5BCE),
    );
  }
  if (action.contains('DELETE') || action.contains('BAN')) {
    return (
      label: label,
      icon: Icons.warning_amber_rounded,
      color: VentlyColors.dangerRed,
    );
  }
  return (
    label: label,
    icon: Icons.settings_outlined,
    color: VentlyColors.berryMagenta,
  );
}

String _formatUtc(DateTime date) {
  final utc = date.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)} UTC';
}
