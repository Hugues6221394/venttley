import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../animation/presets/modal_animations.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../widgets/question_card.dart';
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
                          QuestionCard(prompt: p),
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

  void _openThread(BuildContext context, PlugPrompt prompt) =>
      showQuestionAnswers(context, prompt);
}
