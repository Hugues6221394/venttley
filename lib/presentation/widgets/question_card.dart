import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import 'anonymous_avatar.dart';
import 'post_card.dart' show PostCard;
import 'profile_avatar.dart';

/// Refreshes every surface a question appears on after a mutation.
void _refreshQuestions(WidgetRef ref, PlugPrompt prompt) {
  ref.invalidate(promptsProvider);
  final author = prompt.authorId;
  if (author != null) ref.invalidate(userQuestionsProvider(author));
}

/// Opens the anonymous answer thread for [prompt]. Shared by the Questions
/// screen and the public-profile "Questions asked" section so friends can
/// answer from anywhere the question is shown.
void showQuestionAnswers(BuildContext context, PlugPrompt prompt) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AnswerThreadSheet(prompt: prompt),
  );
}

/// A single question with its actions: like, answer, report, and (for the
/// author) edit / delete. Used in the Questions list and on public profiles.
class QuestionCard extends ConsumerStatefulWidget {
  const QuestionCard({super.key, required this.prompt, this.compact = false});

  final PlugPrompt prompt;

  /// A denser layout for the profile "Questions asked" list.
  final bool compact;

  @override
  ConsumerState<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends ConsumerState<QuestionCard> {
  late bool _liked = widget.prompt.likedByMe;
  late int _likeCount = widget.prompt.likeCount;
  bool _busy = false;

  @override
  void didUpdateWidget(QuestionCard old) {
    super.didUpdateWidget(old);
    if (old.prompt.promptId != widget.prompt.promptId ||
        old.prompt.likeCount != widget.prompt.likeCount ||
        old.prompt.likedByMe != widget.prompt.likedByMe) {
      _liked = widget.prompt.likedByMe;
      _likeCount = widget.prompt.likeCount;
    }
  }

  Future<void> _toggleLike() async {
    if (_busy) return;
    final wasLiked = _liked;
    setState(() {
      _liked = !wasLiked;
      _likeCount = (_likeCount + (wasLiked ? -1 : 1)).clamp(0, 1 << 30);
      _busy = true;
    });
    final repo = ref.read(repositoryProvider);
    try {
      wasLiked
          ? await repo.unlikeQuestion(widget.prompt.promptId)
          : await repo.likeQuestion(widget.prompt.promptId);
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = wasLiked;
          _likeCount = (_likeCount + (wasLiked ? 1 : -1)).clamp(0, 1 << 30);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report() async {
    final reason = await _pickReportReason(context);
    if (reason == null || !mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .reportQuestion(promptId: widget.prompt.promptId, reason: reason);
    } catch (_) {
      /* fail-soft; still thank the user */
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Thanks — our team will review this.')),
    );
  }

  Future<void> _edit() async {
    final controller = TextEditingController(text: widget.prompt.promptText);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit question'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          maxLength: 280,
          decoration: const InputDecoration(hintText: 'Your question'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || !mounted) return;
    if (newText == widget.prompt.promptText) return;
    try {
      final moderation = await ref
          .read(moderationServiceProvider)
          .review(newText);
      if (!mounted) return;
      if (moderation.isBlocked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              moderation.reasons.isEmpty
                  ? 'Held back by safety.'
                  : moderation.reasons.first,
            ),
          ),
        );
        return;
      }
      await ref
          .read(repositoryProvider)
          .updateUserQuestion(promptId: widget.prompt.promptId, text: newText);
      _refreshQuestions(ref, widget.prompt);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Question updated.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update: $e')));
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete question?'),
        content: const Text(
          'This removes your question and its answers for everyone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .deleteUserQuestion(widget.prompt.promptId);
      _refreshQuestions(ref, widget.prompt);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Question deleted.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myId = ref.watch(sessionProvider)?.userId;
    final mine = widget.prompt.isMine(myId);

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: widget.compact ? 0 : 16,
        vertical: 6,
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withOpacity(0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnonymousAvatar(
                seed: widget.prompt.plugAvatarSeed,
                label: widget.prompt.plugDisplayName,
                size: 34,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.prompt.plugDisplayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (mine) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'You',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ],
                        if (widget.prompt.audience == 'friends') ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.people_alt_rounded,
                            size: 12,
                            color: scheme.onSurface.withOpacity(0.45),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '"${widget.prompt.promptText}"',
                      style: const TextStyle(
                        fontSize: 14.5,
                        height: 1.35,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _OverflowMenu(
                mine: mine,
                onReport: _report,
                onEdit: _edit,
                onDelete: _delete,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _ActionChip(
                icon: _liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: PostCard.compactNumber(_likeCount),
                active: _liked,
                onTap: _toggleLike,
              ),
              const SizedBox(width: 6),
              _ActionChip(
                icon: Icons.mode_comment_outlined,
                label:
                    '${PostCard.compactNumber(widget.prompt.answersCount)} answers',
                onTap: () => showQuestionAnswers(context, widget.prompt),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => showQuestionAnswers(context, widget.prompt),
                child: const Text(
                  'Answer',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurface.withOpacity(0.6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.mine,
    required this.onReport,
    required this.onEdit,
    required this.onDelete,
  });

  final bool mine;
  final VoidCallback onReport;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_horiz_rounded,
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
      ),
      onSelected: (v) {
        switch (v) {
          case 'edit':
            onEdit();
          case 'delete':
            onDelete();
          case 'report':
            onReport();
        }
      },
      itemBuilder: (_) => [
        if (mine) ...[
          const PopupMenuItem(
            value: 'edit',
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('Edit'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Delete'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ] else
          const PopupMenuItem(
            value: 'report',
            child: ListTile(
              leading: Icon(Icons.flag_outlined),
              title: Text('Report'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
  }
}

Future<String?> _pickReportReason(BuildContext context) {
  const reasons = <String, String>{
    'spam': 'Spam or scam',
    'harassment': 'Harassment or bullying',
    'hate': 'Hate speech',
    'sexual': 'Sexual content',
    'self_harm': 'Self-harm concern',
    'other': 'Something else',
  };
  return showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Report this question',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          for (final entry in reasons.entries)
            ListTile(
              title: Text(entry.value),
              onTap: () => Navigator.pop(ctx, entry.key),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ─────────────────────── Answer thread ───────────────────────

class _AnswerThreadSheet extends ConsumerStatefulWidget {
  const _AnswerThreadSheet({required this.prompt});
  final PlugPrompt prompt;

  @override
  ConsumerState<_AnswerThreadSheet> createState() => _AnswerThreadSheetState();
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
      final moderation = await ref.read(moderationServiceProvider).review(t);
      if (!mounted) return;
      if (moderation.isBlocked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              moderation.reasons.isEmpty
                  ? 'Held back by safety.'
                  : moderation.reasons.first,
            ),
          ),
        );
        return;
      }
      await ref
          .read(repositoryProvider)
          .addPromptAnswer(promptId: widget.prompt.promptId, text: t);
      _controller.clear();
      ref.invalidate(promptAnswersProvider(widget.prompt.promptId));
      _refreshQuestions(ref, widget.prompt);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not post: $e')));
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
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) =>
                            _AnswerBubble(answer: answers[i]),
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
                          : const Icon(Icons.send_rounded, color: Colors.white),
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
              ProfileAvatar(
                avatarSeed: answer.authorAvatarSeed,
                label: answer.displayName,
                profilePhotoUrl: answer.authorProfilePhotoUrl,
                size: 22,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  answer.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
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
          Text(answer.text, style: const TextStyle(fontSize: 14, height: 1.35)),
        ],
      ),
    );
  }
}
