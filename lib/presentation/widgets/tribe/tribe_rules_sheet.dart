import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../glass_surfaces.dart';

/// Tribe rules — visible to every member from the chat header.
/// The keeper can edit rules inline and manage the ban list; everyone else
/// sees the rules plus the "breaking them gets you removed" contract.
Future<void> showTribeRulesSheet(BuildContext context, Tribe tribe) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => GlassSheet(
      child: SafeArea(
        top: false,
        child: _RulesSheetBody(tribe: tribe),
      ),
    ),
  );
}

class _RulesSheetBody extends ConsumerStatefulWidget {
  const _RulesSheetBody({required this.tribe});
  final Tribe tribe;

  @override
  ConsumerState<_RulesSheetBody> createState() => _RulesSheetBodyState();
}

class _RulesSheetBodyState extends ConsumerState<_RulesSheetBody> {
  late String? _rules = widget.tribe.rules;

  List<String> get _ruleLines => (_rules ?? '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider);
    final isKeeper = me != null && me.userId == widget.tribe.keeperId;
    final lines = _ruleLines;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: VentlyColors.softMauve.withOpacity(0.6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Row(
          children: [
            const Icon(Icons.menu_book_outlined,
                size: 18, color: VentlyColors.berryMagenta),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.tribe.name} — Rules',
                style: const TextStyle(
                    fontWeight: FontWeight.w900, fontSize: 16),
              ),
            ),
            if (isKeeper)
              TextButton.icon(
                onPressed: _editRules,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (lines.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              isKeeper
                  ? 'No rules yet. Tap Edit to set them — every member will see them here.'
                  : 'The keeper hasn\'t written rules yet. Be kind, keep it safe.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.ink.withOpacity(0.6),
              ),
            ),
          )
        else
          ...List.generate(lines.length, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: VentlyColors.berryMagenta.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: VentlyColors.berryMagenta,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      lines[i],
                      style: const TextStyle(
                          fontSize: 13.5, height: 1.4,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: VentlyColors.dangerRed.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: VentlyColors.dangerRed.withOpacity(0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.gavel_rounded,
                  size: 15, color: VentlyColors.dangerRed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Breaking these rules can get you removed and banned by the keeper.',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: VentlyColors.dangerRed.withOpacity(0.9),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (isKeeper) _BanList(tribeId: widget.tribe.tribeId),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _editRules() async {
    final controller = TextEditingController(text: _rules ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tribe rules'),
        content: TextField(
          controller: controller,
          minLines: 4,
          maxLines: 10,
          maxLength: 2000,
          decoration: const InputDecoration(
            hintText: 'One rule per line, e.g.\nBe kind — no harassment.\nNo screenshots. What stays here, stays safe.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == null) return;
    try {
      await ref.read(repositoryProvider).updateTribeManagement(
          tribeId: widget.tribe.tribeId, rules: saved);
      ref.invalidate(tribeBySlugProvider(widget.tribe.slug));
      if (mounted) setState(() => _rules = saved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save rules: $e')));
    }
  }
}

/// Keeper-only: who is banned, with one-tap unban.
class _BanList extends ConsumerStatefulWidget {
  const _BanList({required this.tribeId});
  final String tribeId;

  @override
  ConsumerState<_BanList> createState() => _BanListState();
}

class _BanListState extends ConsumerState<_BanList> {
  late Future<List<Map<String, dynamic>>> _future =
      ref.read(repositoryProvider).tribeBans(widget.tribeId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final bans = snap.data ?? const [];
        if (bans.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 14),
            Text(
              'BANNED MEMBERS',
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w900,
                color: context.ink.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 6),
            for (final b in bans)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('@${b['pseudonym']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13)),
                          if ((b['reason'] as String?)?.isNotEmpty == true)
                            Text(
                              b['reason'] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: context.ink
                                    .withOpacity(0.55),
                              ),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await ref.read(repositoryProvider).unbanMember(
                            tribeId: widget.tribeId,
                            userId: b['userId'] as String);
                        if (mounted) {
                          setState(() => _future = ref
                              .read(repositoryProvider)
                              .tribeBans(widget.tribeId));
                        }
                      },
                      child: const Text('Unban',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
