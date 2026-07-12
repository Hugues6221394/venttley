import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'glass_card.dart';
import 'profile_avatar.dart';
import 'user_profile_link.dart';

/// Opens comments for a Whisper with optimistic send + retry feedback.
Future<void> showWhisperCommentsSheet(
  BuildContext context,
  WidgetRef ref,
  Whisper whisper,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _WhisperCommentsSheet(whisper: whisper),
  );
}

class _WhisperCommentsSheet extends ConsumerStatefulWidget {
  const _WhisperCommentsSheet({required this.whisper});
  final Whisper whisper;

  @override
  ConsumerState<_WhisperCommentsSheet> createState() =>
      _WhisperCommentsSheetState();
}

class _WhisperCommentsSheetState extends ConsumerState<_WhisperCommentsSheet> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final moderation = await ref.read(moderationServiceProvider).review(text);
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

    setState(() => _sending = true);
    try {
      final persona = ref.read(activePersonaProvider);
      await ref.read(repositoryProvider).addWhisperComment(
            widget.whisper.whisperId,
            text,
            personaId: persona?.personaId,
          );
      ref.invalidate(whisperCommentsProvider(widget.whisper.whisperId));
      ref.invalidate(whispersFeedProvider);
      _controller.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not post comment: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final commentsAsync =
        ref.watch(whisperCommentsProvider(widget.whisper.whisperId));
    final bottom = MediaQuery.paddingOf(context).bottom;
    final maxH = MediaQuery.sizeOf(context).height * 0.78;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, bottom + 8),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: maxH,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VentlyColors.softMauve.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.whisper.title?.isNotEmpty == true
                                ? widget.whisper.title!
                                : 'Whisper comments',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                            ),
                          ),
                        ),
                        Text(
                          '${widget.whisper.commentsCount}',
                          style: TextStyle(
                            color: context.ink.withOpacity(0.55),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: commentsAsync.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (e, _) => Center(
                    child: Text(
                      'Could not load comments',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  data: (comments) {
                    if (comments.isEmpty) {
                      return Center(
                        child: Text(
                          'Be the first to leave support.',
                          style: TextStyle(
                            color: context.ink.withOpacity(0.55),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      itemCount: comments.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final c = comments[i];
                        return RepaintBoundary(
                          child: _CommentTile(comment: c),
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          maxLength: 500,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: 'Leave supportive words…',
                            counterText: '',
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.65),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: VentlyColors.berryMagenta,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _sending ? null : _send,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _sending
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.send_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});
  final WhisperComment comment;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (comment.authorId != null)
          UserProfileLink(
            userId: comment.authorId!,
            pseudonym: comment.authorPseudonym.replaceFirst('@', ''),
            avatarSeed: comment.authorAvatarSeed,
            size: 36,
          )
        else
          ProfileAvatar(
            avatarSeed: comment.authorAvatarSeed,
            label: comment.authorPseudonym,
            size: 36,
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.55),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (comment.authorId != null)
                  InkWell(
                    onTap: () => context.push('/user/${comment.authorId}'),
                    child: Text(
                      comment.authorPseudonym,
                      style: const TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  )
                else
                  Text(
                    comment.authorPseudonym,
                    style: const TextStyle(
                      color: VentlyColors.berryMagenta,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  comment.content,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
