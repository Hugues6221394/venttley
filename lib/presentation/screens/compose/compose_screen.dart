import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../data/services/moderation_service.dart';
import '../../../domain/entities/entities.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/mood_chip.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key});

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  final _pollQ = TextEditingController();
  final _pollA = TextEditingController();
  final _pollB = TextEditingController();
  String _category = 'confessions';
  String _mood = 'healing';
  bool _busy = false;
  bool _includePoll = false;
  bool _isWhisper = false;

  @override
  void dispose() {
    _controller.dispose();
    _pollQ.dispose();
    _pollA.dispose();
    _pollB.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (_includePoll) {
      if (_pollQ.text.trim().length < 4 ||
          _pollA.text.trim().isEmpty ||
          _pollB.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Add a poll question and two options, or untoggle the poll.'),
          ),
        );
        return;
      }
    }
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
    final tribe = ref.read(composeTargetTribeProvider);
    final persona = ref.read(activePersonaProvider);
    final post = await ref.read(repositoryProvider).createPost(
          content: text,
          category: _category,
          mood: _mood,
          tribeId: tribe?.tribeId,
          personaId: persona?.personaId,
          isWhisper: _isWhisper,
        );
    // Crisis tag — readers see the helpline banner if the safety classifier
    // surfaced self-harm signals. 'high' = Tier-1 keyword match (more
    // confident), 'elevated' = Tier-2 LLM-only signal. Best-effort: the post
    // is already saved, we just decorate it.
    if (moderation.surfaceCrisisHelpline) {
      final level =
          moderation.categories.contains(HazardCategory.selfHarm) &&
                  moderation.reasons.any((r) => r.contains('care about you'))
              ? 'high'
              : 'elevated';
      unawaited(
        ref.read(repositoryProvider).setPostCrisis(post.postId, level),
      );
    }
    if (_includePoll) {
      try {
        await ref.read(repositoryProvider).createPoll(
              postId: post.postId,
              question: _pollQ.text.trim(),
              optionTexts: [_pollA.text.trim(), _pollB.text.trim()],
            );
      } catch (e) {
        // Post landed; poll attach failed. Surface a soft error.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Posted, but poll failed: $e')),
          );
        }
      }
    }
    ref.read(composeTargetTribeProvider.notifier).state = null;
    if (!mounted) return;
    setState(() => _busy = false);
    if (tribe != null) {
      context.go('/tribe/${tribe.slug}');
    } else {
      context.go('/feed');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tribe == null
            ? 'Vent posted anonymously.'
            : 'Posted to ${tribe.name}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Tribe? target = ref.watch(composeTargetTribeProvider);
    final personas = ref.watch(myPersonasProvider).valueOrNull ?? const [];
    final activePersona = ref.watch(activePersonaProvider);
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
              if (target != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: scheme.primary.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.diversity_3,
                            size: 16, color: scheme.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Posting in ${target.name}',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: scheme.primary),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => ref
                              .read(composeTargetTribeProvider.notifier)
                              .state = null,
                          tooltip: 'Post to general feed instead',
                        ),
                      ],
                    ),
                  ),
                ),
              if (personas.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: scheme.secondary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: scheme.secondary.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.theater_comedy_outlined,
                            size: 16, color: scheme.secondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            activePersona == null
                                ? 'Posting as your default handle'
                                : 'Posting as @${activePersona.pseudonym}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.secondary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _showPersonaPicker(
                              context, personas, activePersona),
                          child: const Text('Switch'),
                        ),
                      ],
                    ),
                  ),
                ),
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
                    onPressed: () =>
                        setState(() => _includePoll = !_includePoll),
                    icon: Icon(
                      _includePoll ? Icons.poll : Icons.poll_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    label: Text(_includePoll ? 'Poll on' : 'Poll'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _isWhisper = !_isWhisper),
                    icon: Icon(
                      _isWhisper ? Icons.nightlight : Icons.nightlight_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    label: Text(_isWhisper ? 'Whisper · 24h' : 'Whisper'),
                  ),
                  const Spacer(),
                  MoodChip(mood: _mood, dense: true),
                ],
              ),
              if (_includePoll)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.06),
                    border:
                        Border.all(color: scheme.primary.withOpacity(0.25)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _pollQ,
                        maxLength: 120,
                        decoration: const InputDecoration(
                          labelText: 'Poll question',
                          hintText: 'e.g. Should I text them back?',
                          counterText: '',
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _pollA,
                              maxLength: 60,
                              decoration: const InputDecoration(
                                labelText: 'Option A',
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _pollB,
                              maxLength: 60,
                              decoration: const InputDecoration(
                                labelText: 'Option B',
                                counterText: '',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
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

  void _showPersonaPicker(
      BuildContext context, List<Persona> personas, Persona? active) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Post as',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: const Text('Default handle'),
                trailing: active == null ? const Icon(Icons.check) : null,
                onTap: () {
                  ref.read(activePersonaProvider.notifier).state = null;
                  Navigator.pop(ctx);
                },
              ),
              for (final p in personas)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: AnonymousAvatar(
                      seed: p.avatarSeed, label: p.pseudonym, size: 30),
                  title: Text('@${p.pseudonym}'),
                  trailing: active?.personaId == p.personaId
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    ref.read(activePersonaProvider.notifier).state = p;
                    Navigator.pop(ctx);
                  },
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
