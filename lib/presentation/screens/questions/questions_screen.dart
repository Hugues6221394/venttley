import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/vently_logo.dart';

/// The Questions tab — Question of the Day plus a feed of all open
/// prompts. Each prompt opens an answer thread (rendered as a sheet).
class QuestionsScreen extends ConsumerWidget {
  const QuestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(promptsProvider);
    final prompts = async.valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const VentlyLogo(size: 26),
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
                          'No questions today.',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Check back later — Plugz post fresh questions daily.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.6),
                          ),
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
                        onSubmit: (answer) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Your answer was added anonymously.',
                              ),
                            ),
                          );
                        },
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
                                  color:
                                      scheme.onSurface.withOpacity(0.65),
                                ),
                              ),
                              onTap: () => _openAnswers(context, p.promptText,
                                  p.plugDisplayName),
                            ),
                          ),
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
    );
  }

  void _openAnswers(BuildContext context, String prompt, String plug) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => DraggableScrollableSheet(
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
                Text(plug,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('"$prompt"',
                    style: const TextStyle(
                      fontSize: 16,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: const [
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            'Anonymous answers will appear here as members reply.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
