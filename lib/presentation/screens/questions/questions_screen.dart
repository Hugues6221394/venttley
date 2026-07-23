import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../animation/presets/modal_animations.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/vently_logo.dart';

/// Question of the Day + every open prompt. Anyone can ask — questions go
/// to everyone or just your connections. Tapping a prompt opens its real
/// answer thread, backed by the `prompt_answers` table.
class QuestionsScreen extends ConsumerWidget {
  const QuestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(promptsProvider);
    final prompts = async.valueOrNull ?? const [];

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const VentlyLogo(size: 26),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAskSheet(context, ref),
        backgroundColor: VentlyColors.berryMagenta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.help_outline_rounded),
        label: const Text(
          'Ask',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: async.isLoading && prompts.isEmpty
          ? const QuestionsSkeletonList()
          : prompts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.help_outline,
                            size: 56,
                            color: scheme.primary.withOpacity(0.5)),
                        const SizedBox(height: 12),
                        const Text(
                          'No questions yet.',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Be the first — ask your friends anything.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => _openAskSheet(context, ref),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Ask a question'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(promptsProvider),
                  child: ListView(
                    children: [
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(20, 14, 20, 4),
                        child: Text(
                          'Question of the day',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface.withOpacity(0.7),
                              ),
                        ),
                      ),
                      PromptCard(
                        prompt: prompts.first,
                        onTap: () => _openThread(context, prompts.first),
                        onSubmit: (answer) =>
                            _submitAnswer(context, ref, prompts.first, answer),
                      ),
                      if (prompts.length > 1) ...[
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(20, 14, 20, 4),
                          child: Text(
                            'More open questions',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onSurface.withOpacity(0.7),
                                ),
                          ),
                        ),
                        for (final p in prompts.skip(1))
                          Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            child: ListTile(
                              leading: AnonymousAvatar(
                                seed: p.plugAvatarSeed,
                                label: p.plugDisplayName,
                                size: 42,
                                showVerifiedBadge: true,
                              ),
                              title: Text(
                                '"${p.promptText}"',
                                style: const TextStyle(
                                  fontStyle: FontStyle.italic,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                '${p.plugDisplayName} • ${PostCard.compactNumber(p.answersCount)} answers',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurface.withOpacity(0.65),
                                ),
                              ),
                              onTap: () => _openThread(context, p),
                            ),
                          ),
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
    );
  }

  /// Glass sheet: question text + audience toggle (Everyone / Connections).
  void _openAskSheet(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    var audience = 'everyone';
    var sending = false;
    showGlassSheet(
      context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> submit() async {
            final text = controller.text.trim();
            if (text.isEmpty || sending) return;
            setSheetState(() => sending = true);
            try {
              final moderation =
                  await ref.read(moderationServiceProvider).review(text);
              if (!ctx.mounted) return;
              if (moderation.isBlocked) {
                setSheetState(() => sending = false);
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text(
                      moderation.reasons.isEmpty
                          ? 'Held back by safety AI.'
                          : moderation.reasons.first,
                    ),
                  ),
                );
                return;
              }
              await ref
                  .read(repositoryProvider)
                  .createUserQuestion(text: text, audience: audience);
              ref.invalidate(promptsProvider);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(audience == 'friends'
                      ? 'Question sent to your friends.'
                      : 'Question posted for everyone.'),
                ),
              );
            } catch (e) {
              if (!ctx.mounted) return;
              setSheetState(() => sending = false);
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('Could not ask: $e')),
              );
            }
          }

          Widget audiencePill(String key, IconData icon, String label) {
            final selected = audience == key;
            final scheme = Theme.of(ctx).colorScheme;
            return GestureDetector(
              onTap: () => setSheetState(() => audience = key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary
                      : Colors.white.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected
                        ? scheme.primary
                        : scheme.primary.withOpacity(0.25),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon,
                        size: 14,
                        color: selected ? Colors.white : scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: selected
                            ? Colors.white
                            : scheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetGrabber(),
                const Text(
                  'Ask a question',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  'Answers come in anonymously.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.55),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 280,
                  decoration: const InputDecoration(
                    hintText: 'What do you want to ask?',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    audiencePill('everyone', Icons.public_rounded, 'Everyone'),
                    const SizedBox(width: 8),
                    audiencePill(
                        'friends', Icons.people_alt_outlined, 'Friends'),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: sending ? null : submit,
                    child: sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Ask'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _submitAnswer(
      BuildContext context, WidgetRef ref, PlugPrompt prompt, String text) async {
    final moderation =
        await ref.read(moderationServiceProvider).review(text);
    if (!context.mounted) return;
    if (moderation.isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moderation.reasons.isEmpty
                ? 'Held back by safety AI.'
                : moderation.reasons.first,
          ),
        ),
      );
      return;
    }
    try {
      await ref
          .read(repositoryProvider)
          .addPromptAnswer(promptId: prompt.promptId, text: text);
      ref.invalidate(promptAnswersProvider(prompt.promptId));
      ref.invalidate(promptsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your answer was added anonymously.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not post: $e')),
      );
    }
  }

  void _openThread(BuildContext context, PlugPrompt prompt) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _AnswerThreadSheet(prompt: prompt),
    );
  }
}

class _AnswerThreadSheet extends ConsumerStatefulWidget {
  const _AnswerThreadSheet({required this.prompt});
  final PlugPrompt prompt;

  @override
  ConsumerState<_AnswerThreadSheet> createState() =>
      _AnswerThreadSheetState();
}

class _AnswerThreadSheetState extends ConsumerState<_AnswerThreadSheet> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _controller.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final moderation =
          await ref.read(moderationServiceProvider).review(t);
      if (!mounted) return;
      if (moderation.isBlocked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              moderation.reasons.isEmpty
                  ? 'Held back by safety AI.'
                  : moderation.reasons.first,
            ),
          ),
        );
        return;
      }
      await ref.read(repositoryProvider).addPromptAnswer(
            promptId: widget.prompt.promptId,
            text: t,
          );
      _controller.clear();
      ref.invalidate(promptAnswersProvider(widget.prompt.promptId));
      ref.invalidate(promptsProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not post: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(promptAnswersProvider(widget.prompt.promptId));
    final answers = async.valueOrNull ?? const [];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (ctx, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  AnonymousAvatar(
                    seed: widget.prompt.plugAvatarSeed,
                    label: widget.prompt.plugDisplayName,
                    size: 32,
                    showVerifiedBadge: true,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.prompt.plugDisplayName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '"${widget.prompt.promptText}"',
                style: const TextStyle(
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: async.isLoading && answers.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : answers.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'Be the first to answer.',
                                style: TextStyle(
                                  color: scheme.onSurface.withOpacity(0.55),
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            itemCount: answers.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final a = answers[i];
                              return _AnswerBubble(answer: a);
                            },
                          ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 500,
                      decoration: const InputDecoration(
                        hintText: 'Answer anonymously…',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded,
                              color: Colors.white),
                      onPressed: _sending ? null : _send,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AnswerBubble extends StatelessWidget {
  const _AnswerBubble({required this.answer});
  final PromptAnswer answer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.06),
        border: Border.all(color: scheme.primary.withOpacity(0.20)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnonymousAvatar(
                seed: answer.authorAvatarSeed,
                label: answer.authorPseudonym,
                size: 22,
              ),
              const SizedBox(width: 6),
              Text(
                answer.authorPseudonym,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                DateFormat.MMMd().add_jm().format(answer.createdAt),
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            answer.text,
            style: const TextStyle(fontSize: 14, height: 1.35),
          ),
        ],
      ),
    );
  }
}
