import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../data/services/moderation_service.dart';
import '../../widgets/mood_chip.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key});

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  String _category = 'confessions';
  String _mood = 'healing';
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final moderation =
        await ref.read(moderationServiceProvider).review(text);
    if (!mounted) return;
    if (moderation.isBlocked) {
      setState(() => _busy = false);
      _showBlocked(moderation);
      return;
    }
    if (moderation.isWarn) {
      final proceed = await _confirmWarn(moderation);
      if (!proceed) {
        setState(() => _busy = false);
        return;
      }
    }
    await ref.read(repositoryProvider).createPost(
          content: text,
          category: _category,
          mood: _mood,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    context.go('/feed');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Vent posted anonymously.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/feed'),
        ),
        title: const Text('New Vent'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _submit,
            child: const Text('Post'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Category',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final c in FeedCategories.all)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                label: Text(FeedCategories.label(c)),
                                selected: _category == c,
                                onSelected: (_) => setState(() => _category = c),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Mood', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final m in Moods.all)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                avatar: Text(Moods.emoji(m)),
                                label: Text(Moods.label(m)),
                                selected: _mood == m,
                                onSelected: (_) => setState(() => _mood = m),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: _controller,
                      maxLength: 1000,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        hintText: 'What would you like to vent about?\nNo names. No links. Pure feelings.',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => context.push('/voice'),
                    icon: Icon(Icons.mic, color: scheme.primary),
                    label: const Text('Record voice instead'),
                  ),
                  const Spacer(),
                  MoodChip(mood: _mood, dense: true),
                ],
              ),
              SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Text('Post Anonymously'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBlocked(ModerationResult res) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(Icons.shield_outlined,
                color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Held back by safety AI'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in res.reasons) Text('• $r'),
            if (res.surfaceCrisisHelpline) ...[
              const SizedBox(height: 12),
              const Text(
                'If you\'re in crisis right now, you\'re not alone:',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              for (final r in kCrisisResources) Text('• ${r.label} — ${r.reach}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmWarn(ModerationResult res) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: const Text('Heads up'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in res.reasons) Text('• $r'),
                if (res.surfaceCrisisHelpline) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'We care about you. Crisis lines are available 24/7.',
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Edit'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Post anyway'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
