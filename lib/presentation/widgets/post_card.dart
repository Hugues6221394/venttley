import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'anonymous_avatar.dart';
import 'mood_chip.dart';
import 'poll_card.dart';

class PostCard extends ConsumerWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onComment,
    this.onShare,
    this.onMessage,
  });

  final Post post;
  final VoidCallback? onTap;
  final VoidCallback? onComment;
  final VoidCallback? onShare;
  final VoidCallback? onMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withOpacity(0.55);
    final dmDisabled = FeedCategories.dmRestricted.contains(post.categoryName);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnonymousAvatar(
                    seed: post.authorAvatarSeed,
                    label: post.authorPseudonym,
                    size: 36,
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
                                post.authorPseudonym,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (post.authorKarma >= 10) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.auto_awesome,
                                  size: 11, color: scheme.primary),
                              const SizedBox(width: 2),
                              Text(
                                PostCard.compactNumber(post.authorKarma),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.primary,
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            Text(
                              _ago(post.createdAt),
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ],
                        ),
                        if (post.tribeName != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: GestureDetector(
                              onTap: post.tribeSlug == null || onTap == null
                                  ? null
                                  : () {
                                      // Tribe-name tap is handled by the parent
                                      // screen via [onTap]; specific tribe-detail
                                      // routing lives in the home feed/list.
                                      onTap!.call();
                                    },
                              child: Text(
                                'in ${post.tribeName!}',
                                style: TextStyle(
                                  color: scheme.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  MoodChip(mood: post.postMood, dense: true),
                ],
              ),
              const SizedBox(height: 12),
              if (post.isWhisper) ...[
                Row(
                  children: [
                    Icon(Icons.nightlight, size: 12, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      'WHISPER · expires ${_whisperExpiry(post.whisperRemaining)}',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              Text(
                post.content,
                style: const TextStyle(fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 10),
              Consumer(
                builder: (ctx, r, _) {
                  final poll =
                      r.watch(pollForPostProvider(post.postId)).valueOrNull;
                  if (poll == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: PollCard(poll: poll, compact: true),
                  );
                },
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _ReactionButton(post: post),
                  const SizedBox(width: 16),
                  _PillAction(
                    icon: Icons.chat_bubble_outline,
                    label: PostCard.compactNumber(post.commentsCount),
                    onTap: onComment,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      post.savedByMe ? Icons.bookmark : Icons.bookmark_outline,
                      color: post.savedByMe ? scheme.primary : muted,
                    ),
                    onPressed: () =>
                        ref.read(repositoryProvider).toggleSave(post.postId),
                  ),
                  IconButton(
                    icon: Icon(Icons.send_rounded, color: muted),
                    onPressed: onShare,
                  ),
                  if (!dmDisabled)
                    IconButton(
                      icon: Icon(Icons.mail_outline, color: muted),
                      tooltip: 'Request a chat',
                      onPressed: onMessage,
                    ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, color: muted),
                    tooltip: 'More',
                    onSelected: (v) {
                      if (v == 'report') _openReportSheet(context, ref, post.postId);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'report',
                        child: Row(
                          children: [
                            Icon(Icons.flag_outlined, size: 16),
                            SizedBox(width: 8),
                            Text('Report'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (dmDisabled)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 14, color: muted),
                      const SizedBox(width: 6),
                      Text(
                        'DMs disabled for ${FeedCategories.label(post.categoryName)} to protect this space.',
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _whisperExpiry(Duration left) {
    if (left.inMinutes < 1) return 'soon';
    if (left.inHours < 1) return 'in ${left.inMinutes}m';
    return 'in ${left.inHours}h';
  }

  String _ago(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours   < 24) return '${d.inHours}h ago';
    if (d.inDays    < 7)  return '${d.inDays}d ago';
    return DateFormat.MMMd().format(ts);
  }

  static String compactNumber(int n) {
    if (n < 1000) return n.toString();
    if (n < 1000000) {
      final v = n / 1000;
      return v >= 10 ? '${v.toStringAsFixed(0)}k' : '${v.toStringAsFixed(1)}k';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

Future<void> _openReportSheet(
    BuildContext context, WidgetRef ref, String postId) async {
  const reasons = <(String, String)>[
    ('self_harm',       'Self-harm or suicide concern'),
    ('hate',            'Hate speech'),
    ('harassment',      'Harassment or bullying'),
    ('sexual_content',  'Sexual content'),
    ('violence',        'Violence or threats'),
    ('privacy',         'Personal info / doxxing'),
    ('spam',            'Spam or scam'),
    ('other',           'Something else'),
  ];
  final choice = await showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                'Report this post',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                'A moderator reviews every report. Reports are anonymous.',
              ),
            ),
            const SizedBox(height: 8),
            for (final r in reasons)
              ListTile(
                title: Text(r.$2),
                onTap: () => Navigator.of(ctx).pop(r.$1),
              ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  try {
    await ref.read(repositoryProvider).reportPost(
          postId: postId,
          reason: choice,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Thank you — a moderator will review.')),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not send report: $e')),
    );
  }
}

class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.icon,
    required this.label,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withOpacity(0.6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Row(
        children: [
          Icon(icon, size: 18, color: muted),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: muted, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Plug-prompt card — the heart-shaped speech-bubble container used for
/// "Question of the Day" cards.
class PromptCard extends StatelessWidget {
  const PromptCard({
    super.key,
    required this.prompt,
    this.onSubmit,
    this.onTap,
  });
  final PlugPrompt prompt;
  final ValueChanged<String>? onSubmit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnonymousAvatar(
                  seed: prompt.plugAvatarSeed,
                  label: prompt.plugDisplayName,
                  size: 36,
                  showVerifiedBadge: true,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.help_outline,
                              size: 14, color: scheme.primary),
                          const SizedBox(width: 4),
                          Text('QUESTION OF THE DAY',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.primary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              )),
                        ],
                      ),
                      Text(
                        prompt.plugDisplayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: double.infinity,
                child: CustomPaint(
                  painter: _HeartBubbleBgPainter(scheme.primary),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
                    child: Text(
                      '"${prompt.promptText}"',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        fontSize: 16,
                        height: 1.4,
                        color: isDark
                            ? VentlyColors.softOffWhite
                            : VentlyColors.deepBurgundy,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      hintText: 'Answer Anonymously...',
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.white),
                    onPressed: () {
                      final t = controller.text.trim();
                      if (t.isNotEmpty) onSubmit?.call(t);
                      controller.clear();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            InkWell(
              onTap: onTap,
              child: Text(
                '${prompt.answersCount} anonymous answers • tap to read the thread',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  decoration:
                      onTap == null ? null : TextDecoration.underline,
                  color: scheme.onSurface.withOpacity(0.65),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeartBubbleBgPainter extends CustomPainter {
  _HeartBubbleBgPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.13)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = color.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.92)
      ..cubicTo(w * 0.05, h * 0.78, w * 0.05, h * 0.10, w * 0.30, h * 0.10)
      ..cubicTo(w * 0.45, h * 0.10, w * 0.50, h * 0.22, w * 0.50, h * 0.22)
      ..cubicTo(w * 0.50, h * 0.22, w * 0.55, h * 0.10, w * 0.70, h * 0.10)
      ..cubicTo(w * 0.95, h * 0.10, w * 0.95, h * 0.78, w * 0.50, h * 0.92)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(path, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Emotion reaction button. Single tap toggles a default 'like' (clears
/// the current reaction when one is set); long-press opens a picker
/// with the full palette from [PostReactions.all].
class _ReactionButton extends ConsumerWidget {
  const _ReactionButton({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withOpacity(0.6);
    final r = post.myReaction;
    final color = r != null ? scheme.primary : muted;

    Widget glyph;
    if (r == null) {
      glyph = Icon(Icons.favorite_border, size: 18, color: color);
    } else if (r == 'like') {
      glyph = Icon(Icons.favorite, size: 18, color: color);
    } else {
      glyph = Text(PostReactions.emoji(r), style: const TextStyle(fontSize: 16));
    }

    return GestureDetector(
      onLongPress: () => _openPicker(context, ref),
      child: InkWell(
        onTap: () =>
            ref.read(repositoryProvider).react(post.postId, r ?? 'like'),
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            glyph,
            const SizedBox(width: 4),
            Text(
              PostCard.compactNumber(post.likesCount),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: Theme.of(ctx).cardColor,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: scheme.primary.withOpacity(0.22)),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withOpacity(0.10),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final key in PostReactions.all)
                  _ReactionChoice(
                    reactionKey: key,
                    isSelected: post.myReaction == key,
                    onTap: () => Navigator.of(ctx).pop(key),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    await ref.read(repositoryProvider).react(post.postId, picked);
  }
}

class _ReactionChoice extends StatelessWidget {
  const _ReactionChoice({
    required this.reactionKey,
    required this.isSelected,
    required this.onTap,
  });
  final String reactionKey;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: isSelected
              ? scheme.primary.withOpacity(0.14)
              : Colors.transparent,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(PostReactions.emoji(reactionKey),
                style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 4),
            Text(
              PostReactions.label(reactionKey),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: isSelected
                    ? scheme.primary
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
