import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';

/// Plugz V2 — Moderation Center for one tribe.
///
/// Four sections:
///   1. Quick links → Reports queue (existing /tribe/:slug/manage/reports)
///   2. Rules editor (writes tribes.rules JSONB via set_tribe_rules)
///   3. Keyword filters (add / remove)
///   4. Member warnings log + Warn-a-member action
class TribeModerationScreen extends ConsumerStatefulWidget {
  const TribeModerationScreen({super.key, required this.slug});
  final String slug;
  @override
  ConsumerState<TribeModerationScreen> createState() =>
      _TribeModerationScreenState();
}

class _TribeModerationScreenState
    extends ConsumerState<TribeModerationScreen> {
  final TextEditingController _keywordCtl = TextEditingController();
  final TextEditingController _rulesCtl = TextEditingController();
  String _kwSeverity = 'soft';
  bool _rulesDirty = false;
  bool _savingRules = false;

  @override
  void dispose() {
    _keywordCtl.dispose();
    _rulesCtl.dispose();
    super.dispose();
  }

  Future<void> _addKeyword(String tribeId) async {
    final kw = _keywordCtl.text.trim();
    if (kw.length < 2) return;
    try {
      await ref.read(repositoryProvider).addKeywordFilter(
            tribeId: tribeId,
            keyword: kw,
            severity: _kwSeverity,
          );
      _keywordCtl.clear();
      ref.invalidate(_keywordFiltersProvider(tribeId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add: $e')),
      );
    }
  }

  Future<void> _saveRules(String tribeId) async {
    setState(() => _savingRules = true);
    try {
      await ref.read(repositoryProvider).setTribeRules(
            tribeId: tribeId,
            rules: {'text': _rulesCtl.text},
          );
      ref.invalidate(tribeBySlugProvider(widget.slug));
      setState(() => _rulesDirty = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rules saved.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingRules = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tribeAsync = ref.watch(tribeBySlugProvider(widget.slug));
    return tribeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('$e')),
      ),
      data: (tribe) {
        if (tribe == null) {
          return const Scaffold(body: Center(child: Text('Tribe not found')));
        }
        final me = ref.watch(sessionProvider);
        if (me == null || tribe.keeperId != me.userId) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(title: const Text('Moderation')),
            body: const Center(
              child: Text('Only the tribe Plug can open moderation.',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          );
        }

        // Seed the rules editor once from the loaded tribe.
        final loadedRules =
            (tribe.toString().contains('rules') ? null : null);
        // (rules aren't on the entity — we stash them via JSONB on the
        // server; the textarea defaults to empty and writes through.)
        if (_rulesCtl.text.isEmpty && !_rulesDirty) {
          // leave empty until the user starts editing
        }
        loadedRules; // suppress unused warning

        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(tribe.name,
                style: const TextStyle(fontWeight: FontWeight.w900)),
            backgroundColor: Colors.transparent,
            foregroundColor: VentlyColors.deepBurgundy,
            elevation: 0,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _ReportsQuickLink(tribeSlug: tribe.slug),
              const SizedBox(height: 14),
              _SectionCard(
                title: 'Tribe rules',
                subtitle:
                    'Shown to every member on tribe detail + on first post.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _rulesCtl,
                      onChanged: (_) =>
                          setState(() => _rulesDirty = true),
                      maxLines: 6,
                      maxLength: 1200,
                      decoration: const InputDecoration(
                        hintText:
                            'Be kind. Vent honestly. No doxxing. No spam. Listen first…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_rulesDirty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: _savingRules
                              ? null
                              : () => _saveRules(tribe.tribeId),
                          style: FilledButton.styleFrom(
                            backgroundColor: VentlyColors.berryMagenta,
                          ),
                          child: _savingRules
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Save rules',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w900),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _SectionCard(
                title: 'Keyword filters',
                subtitle:
                    '"Soft" flags for review · "Hard" blocks the message at send.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _keywordCtl,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _addKeyword(tribe.tribeId),
                            decoration: const InputDecoration(
                              hintText: 'Add a keyword to filter…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _kwSeverity,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                                value: 'soft',
                                child: Text('Soft',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800))),
                            DropdownMenuItem(
                                value: 'hard',
                                child: Text('Hard',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800))),
                          ],
                          onChanged: (v) =>
                              setState(() => _kwSeverity = v ?? 'soft'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => _addKeyword(tribe.tribeId),
                          style: FilledButton.styleFrom(
                            backgroundColor: VentlyColors.berryMagenta,
                          ),
                          child: const Text('Add',
                              style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Consumer(
                      builder: (ctx, ref, _) {
                        final async = ref.watch(
                            _keywordFiltersProvider(tribe.tribeId));
                        return async.when(
                          loading: () => const Padding(
                            padding: EdgeInsets.all(12),
                            child: Center(
                                child: CircularProgressIndicator()),
                          ),
                          error: (e, _) => Text('Could not load: $e'),
                          data: (list) {
                            if (list.isEmpty) {
                              return const _Hint(
                                  text:
                                      'No filters yet — start with the obvious slurs + scam words.');
                            }
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final f in list)
                                  _KeywordChip(
                                    filter: f,
                                    onRemove: () async {
                                      await ref
                                          .read(repositoryProvider)
                                          .removeKeywordFilter(f.filterId);
                                      ref.invalidate(
                                          _keywordFiltersProvider(
                                              tribe.tribeId));
                                    },
                                  ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _SectionCard(
                title: 'Member warnings',
                subtitle:
                    'Issue gentle, formal, or final warnings before kicking.',
                child: Consumer(
                  builder: (ctx, ref, _) {
                    final async = ref
                        .watch(_memberWarningsProvider(tribe.tribeId));
                    return async.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.all(12),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Text('Could not load: $e'),
                      data: (list) {
                        if (list.isEmpty) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const _Hint(
                                  text:
                                      'No warnings issued. Use the Members tab to warn someone.'),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () => context.push(
                                    '/tribe/${tribe.slug}/manage'),
                                icon:
                                    const Icon(Icons.group_outlined, size: 16),
                                label: const Text('Open members'),
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            for (final w in list) _WarningRow(warning: w),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =========================================================================
// SECTION CARD + HELPERS
// =========================================================================

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: VentlyColors.deepBurgundy,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              color: VentlyColors.deepBurgundy.withOpacity(0.6),
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ReportsQuickLink extends StatelessWidget {
  const _ReportsQuickLink({required this.tribeSlug});
  final String tribeSlug;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/tribe/$tribeSlug/manage/reports'),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFFFE3EC),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.flag_rounded,
                    color: VentlyColors.berryMagenta, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reports queue',
                      style: TextStyle(
                        color: VentlyColors.deepBurgundy,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'Open posts / comments flagged by members.',
                      style: TextStyle(
                        color: VentlyColors.deepBurgundy,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: VentlyColors.deepBurgundy),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeywordChip extends StatelessWidget {
  const _KeywordChip({required this.filter, required this.onRemove});
  final TribeKeywordFilter filter;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final hard = filter.severity == 'hard';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: hard
            ? VentlyColors.berryMagenta.withOpacity(0.12)
            : VentlyColors.softMauve.withOpacity(0.22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hard
              ? VentlyColors.berryMagenta.withOpacity(0.4)
              : VentlyColors.softMauve.withOpacity(0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hard ? Icons.block : Icons.flag_outlined,
            size: 12,
            color: hard
                ? VentlyColors.berryMagenta
                : VentlyColors.deepBurgundy,
          ),
          const SizedBox(width: 6),
          Text(
            filter.keyword,
            style: const TextStyle(
              color: VentlyColors.deepBurgundy,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close_rounded, size: 14),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.warning});
  final TribeMemberWarning warning;
  @override
  Widget build(BuildContext context) {
    final color = switch (warning.severity) {
      'final' => const Color(0xFFD93D5C),
      'warning' => VentlyColors.berryMagenta,
      _ => VentlyColors.deepBurgundy.withOpacity(0.6),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnonymousAvatar(
            seed: warning.memberAvatarSeed,
            label: warning.memberPseudonym,
            size: 32,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '@${warning.memberPseudonym}',
                      style: const TextStyle(
                        color: VentlyColors.deepBurgundy,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        warning.severity.toUpperCase(),
                        style: TextStyle(
                          color: color,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  warning.reason,
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy.withOpacity(0.75),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
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

class _Hint extends StatelessWidget {
  const _Hint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VentlyColors.softMauve.withOpacity(0.18),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: VentlyColors.deepBurgundy.withOpacity(0.72),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

// =========================================================================
// PROVIDERS
// =========================================================================

final _keywordFiltersProvider =
    FutureProvider.autoDispose.family<List<TribeKeywordFilter>, String>(
  (ref, tribeId) =>
      ref.watch(repositoryProvider).tribeKeywordFilters(tribeId),
);

final _memberWarningsProvider =
    FutureProvider.autoDispose.family<List<TribeMemberWarning>, String>(
  (ref, tribeId) =>
      ref.watch(repositoryProvider).tribeMemberWarnings(tribeId),
);
