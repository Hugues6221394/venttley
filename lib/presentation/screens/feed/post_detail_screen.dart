import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});
  final String postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _replyController = TextEditingController();
  String? _replyingToId;
  String? _replyingToName;

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final postAsync = ref.watch(postByIdProvider(widget.postId));
    final post = postAsync.valueOrNull;
    if (postAsync.isLoading && post == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (post == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Post not found')),
      );
    }
    final comments =
        ref.watch(commentsProvider(widget.postId)).valueOrNull ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread'),
        actions: [
          IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: () => _openReportSheet(context)),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                PostCard(post: post),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: Text(
                    'Thread',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                if (comments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                    child: Text(
                      'No comments yet. Be the first kind voice in this thread.',
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                else
                  for (final c in comments) _CommentNode(
                    comment: c,
                    onReply: (cm) => _setReplyTarget(cm),
                  ),
              ],
            ),
          ),
          _ReplyComposer(
            controller: _replyController,
            replyingToName: _replyingToName,
            onClear: () => setState(() {
              _replyingToId = null;
              _replyingToName = null;
            }),
            onSend: () async {
              final text = _replyController.text.trim();
              if (text.isEmpty) return;
              await repo.addComment(
                postId: widget.postId,
                parentId: _replyingToId,
                content: text,
              );
              ref.invalidate(commentsProvider(widget.postId));
              ref.invalidate(postByIdProvider(widget.postId));
              _replyController.clear();
              setState(() {
                _replyingToId = null;
                _replyingToName = null;
              });
            },
          ),
        ],
      ),
    );
  }

  void _setReplyTarget(ThreadedComment c) {
    setState(() {
      _replyingToId = c.commentId;
      _replyingToName = c.authorPseudonym;
    });
  }

  void _openReportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => const _ReportSheet(targetLabel: 'this post'),
    );
  }
}

class _CommentNode extends StatelessWidget {
  const _CommentNode({required this.comment, required this.onReply});
  final ThreadedComment comment;
  final ValueChanged<ThreadedComment> onReply;

  /// Adaptive indentation: min(d * 12, 36px). Beyond depth 4 we collapse.
  double _indent(int depth) {
    final px = (depth * 12).clamp(0, 36).toDouble();
    return px;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final depth = comment.depth;
    return Padding(
      padding: EdgeInsets.fromLTRB(16 + _indent(depth), 6, 16, 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnonymousAvatar(
                  seed: comment.authorAvatarSeed,
                  label: comment.authorPseudonym,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    comment.authorPseudonym,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
                Text(
                  _ago(comment.createdAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(comment.content, style: const TextStyle(fontSize: 14, height: 1.35)),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.favorite_border, size: 14, color: scheme.onSurface.withOpacity(0.55)),
                const SizedBox(width: 4),
                Text(
                  PostCard.compactNumber(comment.likesCount),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
                const SizedBox(width: 14),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => onReply(comment),
                  child: const Text('Reply',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      )),
                ),
              ],
            ),
            if (comment.children.isNotEmpty)
              comment.depth >= 3
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: TextButton.icon(
                        onPressed: () => _openDeeperReplies(context, comment),
                        icon: const Icon(Icons.arrow_forward, size: 14),
                        label: Text(
                            'View deeper replies (${_countAll(comment.children)})'),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final child in comment.children)
                          _CommentNode(comment: child, onReply: onReply),
                      ],
                    ),
          ],
        ),
      ),
    );
  }

  int _countAll(List<ThreadedComment> nodes) {
    var n = nodes.length;
    for (final c in nodes) {
      n += _countAll(c.children);
    }
    return n;
  }

  String _ago(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24)   return '${d.inHours}h';
    if (d.inDays < 7)     return '${d.inDays}d';
    return DateFormat.MMMd().format(ts);
  }

  void _openDeeperReplies(BuildContext context, ThreadedComment root) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, controller) => Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: VentlyColors.softMauve,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Deeper replies',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                children: [
                  for (final c in root.children)
                    _CommentNode(comment: c, onReply: onReply),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyComposer extends StatelessWidget {
  const _ReplyComposer({
    required this.controller,
    required this.replyingToName,
    required this.onClear,
    required this.onSend,
  });
  final TextEditingController controller;
  final String? replyingToName;
  final VoidCallback onClear;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: Border(
            top: BorderSide(
              color: VentlyColors.softMauve.withOpacity(0.35),
              width: 0.6,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingToName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.reply,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Replying to $replyingToName',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: onClear,
                      child: const Icon(Icons.close, size: 14),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Add a supportive comment...',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.send_rounded),
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportSheet extends StatelessWidget {
  const _ReportSheet({required this.targetLabel});
  final String targetLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const categories = [
      ('harassment',  'Harassment or bullying'),
      ('hate_speech', 'Hate speech or slurs'),
      ('self_harm',   'Self-harm or suicide'),
      ('doxxing',     'Doxxing or personal info'),
      ('spam',        'Spam or scam'),
      ('explicit',    'Explicit adult content'),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Report $targetLabel',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Vently moderators review reports anonymously, usually within minutes.',
              style: TextStyle(
                color: scheme.onSurface.withOpacity(0.65),
              ),
            ),
            const SizedBox(height: 16),
            for (final c in categories)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.$2),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Report submitted: ${c.$2}')),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
