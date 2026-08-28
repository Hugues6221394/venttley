import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/vently_premium_background.dart';

class TribeRulesEditorScreen extends ConsumerStatefulWidget {
  const TribeRulesEditorScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<TribeRulesEditorScreen> createState() =>
      _TribeRulesEditorScreenState();
}

class _TribeRulesEditorScreenState
    extends ConsumerState<TribeRulesEditorScreen> {
  List<TribeRuleItem>? rules;
  bool saving = false;

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
        appBar: AppBar(title: const Text('Tribe rules')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'Only the current Plug can edit Tribe rules.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }
    final overview = ref.watch(tribeManagementProvider(tribe.tribeId));
    final loaded = overview.valueOrNull;
    rules ??= loaded?.rules.toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Tribe rules',
            style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          TextButton(
            onPressed:
                saving || loaded == null ? null : () => _save(tribe.tribeId),
            child: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save',
                    style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add rule',
        onPressed: _addRule,
        child: const Icon(Icons.add_rounded),
      ),
      body: VentlyPremiumBackground(
        child: overview.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text('Could not load rules: $error')),
          data: (_) {
            final current = rules ?? const <TribeRuleItem>[];
            if (current.isEmpty) {
              return _EmptyRules(onTemplate: _addTemplates, onAdd: _addRule);
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: VentlyColors.berryMagenta.withOpacity(.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.touch_app_outlined,
                            color: VentlyColors.berryMagenta),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Hold and drag to reorder. Enabled rules are shown before joining.',
                            style: TextStyle(
                              color: context.ink.withOpacity(.68),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 112),
                    itemCount: current.length,
                    onReorder: _reorder,
                    itemBuilder: (_, index) {
                      final rule = current[index];
                      return _RuleCard(
                        key: ValueKey(
                            rule.ruleId ?? 'rule-$index-${rule.title}'),
                        index: index,
                        rule: rule,
                        onToggle: (enabled) => setState(() {
                          rules![index] = rule.copyWith(isEnabled: enabled);
                        }),
                        onEdit: () => _editRule(index),
                        onDelete: () => setState(() => rules!.removeAt(index)),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final rule = rules!.removeAt(oldIndex);
      rules!.insert(newIndex, rule);
      rules = [
        for (var i = 0; i < rules!.length; i++) rules![i].copyWith(position: i),
      ];
    });
  }

  Future<void> _addRule() async {
    final created = await showDialog<TribeRuleItem>(
      context: context,
      builder: (_) => _RuleDialog(position: rules?.length ?? 0),
    );
    if (created != null) setState(() => (rules ??= []).add(created));
  }

  Future<void> _editRule(int index) async {
    final edited = await showDialog<TribeRuleItem>(
      context: context,
      builder: (_) => _RuleDialog(initial: rules![index], position: index),
    );
    if (edited != null) setState(() => rules![index] = edited);
  }

  void _addTemplates() {
    setState(() {
      rules = const [
        TribeRuleItem(
            position: 0,
            title: 'Be respectful',
            description:
                'Disagree without attacking, mocking, or shaming people.'),
        TribeRuleItem(
            position: 1,
            title: 'No hate speech',
            description:
                'Hate, harassment, and dehumanizing language are not allowed.'),
        TribeRuleItem(
            position: 2,
            title: 'Protect personal information',
            description:
                'Do not share names, phone numbers, addresses, or private screenshots.'),
        TribeRuleItem(
            position: 3,
            title: 'Stay on topic',
            description: 'Use the right Space and keep discussions relevant.'),
      ];
    });
  }

  Future<void> _save(String tribeId) async {
    setState(() => saving = true);
    try {
      await ref.read(repositoryProvider).replaceTribeRules(
        tribeId,
        [
          for (var i = 0; i < (rules?.length ?? 0); i++)
            rules![i].copyWith(position: i),
        ],
      );
      ref.invalidate(tribeManagementProvider(tribeId));
      ref.invalidate(tribeBySlugProvider(widget.slug));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rules saved and ready for members.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save rules: $error')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    super.key,
    required this.index,
    required this.rule,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });
  final int index;
  final TribeRuleItem rule;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: context.glass(.9),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta.withOpacity(.10),
                    shape: BoxShape.circle,
                  ),
                  child: Text('${index + 1}',
                      style: const TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontWeight: FontWeight.w900,
                      )),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rule.title,
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      if (rule.description?.isNotEmpty == true)
                        Text(
                          rule.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ink.withOpacity(.55),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                Switch.adaptive(value: rule.isEnabled, onChanged: onToggle),
                PopupMenuButton<String>(
                  tooltip: 'Rule actions',
                  onSelected: (action) {
                    if (action == 'edit') onEdit();
                    if (action == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit rule')),
                    PopupMenuItem(value: 'delete', child: Text('Delete rule')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.initial, required this.position});
  final TribeRuleItem? initial;
  final int position;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final title = TextEditingController(text: widget.initial?.title);
  late final description =
      TextEditingController(text: widget.initial?.description);

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add rule' : 'Edit rule'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            autofocus: true,
            maxLength: 100,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Rule title'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: description,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: title.text.trim().length < 2
              ? null
              : () => Navigator.pop(
                    context,
                    TribeRuleItem(
                      ruleId: widget.initial?.ruleId,
                      position: widget.position,
                      title: title.text.trim(),
                      description: description.text.trim(),
                      isEnabled: widget.initial?.isEnabled ?? true,
                    ),
                  ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules({required this.onTemplate, required this.onAdd});
  final VoidCallback onTemplate;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.rule_rounded,
                size: 48, color: VentlyColors.berryMagenta),
            const SizedBox(height: 12),
            const Text('Set the tone for your Tribe',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text(
              'Rules appear before joining and give moderators a shared standard.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onTemplate,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Use safety template'),
            ),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Write my own'),
            ),
          ],
        ),
      ),
    );
  }
}
