import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_chat_poll.dart';
import '../../theme/colors.dart';
import '../glass_card.dart';
import '../glass_surfaces.dart';
import '../profile_avatar.dart';
import 'tribe_chat_poll_card.dart';

/// Thread of replies to a keeper question card.
Future<void> showTribeQuestionAnswersSheet(
  BuildContext context,
  WidgetRef ref, {
  required TribeMessage questionMessage,
  required String tribeId,
  required String tribeSlug,
  required VoidCallback onReply,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _QuestionAnswersSheet(
      questionMessage: questionMessage,
      tribeId: tribeId,
      tribeSlug: tribeSlug,
      onReply: () {
        Navigator.pop(ctx);
        onReply();
      },
    ),
  );
}

class _QuestionAnswersSheet extends ConsumerWidget {
  const _QuestionAnswersSheet({
    required this.questionMessage,
    required this.tribeId,
    required this.tribeSlug,
    required this.onReply,
  });

  final TribeMessage questionMessage;
  final String tribeId;
  final String tribeSlug;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(tribeMessagesProvider(tribeId));
    final question = TribeChatQuestion.fromMessage(questionMessage);

    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      minChildSize: 0.38,
      maxChildSize: 0.92,
      builder: (ctx, scroll) {
        return GlassSheet(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Answers',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: TribeChatQuestionCard(
                  question: question,
                  answerCount: questionMessage.questionReplyCount,
                  showTapHint: false,
                ),
              ),
              Expanded(
                child: messagesAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Error: $e')),
                  data: (all) {
                    final replies = all
                        .where((m) =>
                            m.replyToMessageId == questionMessage.messageId &&
                            !m.isDeleted)
                        .toList();
                    if (replies.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No answers yet — be the first to share.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.6),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      itemCount: replies.length,
                      itemBuilder: (_, i) {
                        final m = replies[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: GlassCard(
                            padding: const EdgeInsets.all(12),
                            borderRadius: 16,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ProfileAvatar(
                                  avatarSeed: m.senderAvatarSeed,
                                  label: m.senderPseudonym,
                                  profilePhotoUrl: m.senderProfilePhotoUrl,
                                  size: 32,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '@${m.senderPseudonym}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 11,
                                          color: VentlyColors.berryMagenta,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        m.content ?? '(attachment)',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: FilledButton.icon(
                    onPressed: () {
                      VentlyHaptics.light();
                      onReply();
                    },
                    icon: const Icon(Icons.reply_rounded),
                    label: const Text('Add your answer'),
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
