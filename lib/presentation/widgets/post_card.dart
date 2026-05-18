import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'anonymous_avatar.dart';
import 'mood_chip.dart';

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
                            const SizedBox(width: 6),
                            Text(
                              _ago(post.createdAt),
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ],
                        ),
                        if (post.spaceName != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              post.spaceName!,
                              style: TextStyle(
                                color: scheme.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
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
              if (post.isAudio) _AudioPlayerBlock(post: post)
              else
                Text(
                  post.content,
                  style: const TextStyle(fontSize: 15, height: 1.4),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _PillAction(
                    icon: post.likedByMe ? Icons.favorite : Icons.favorite_border,
                    label: PostCard.compactNumber(post.likesCount),
                    color: post.likedByMe ? scheme.primary : null,
                    onTap: () =>
                        ref.read(repositoryProvider).toggleLike(post.postId),
                  ),
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

class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withOpacity(0.6);
    final c = color ?? muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _AudioPlayerBlock extends StatelessWidget {
  const _AudioPlayerBlock({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = Duration(milliseconds: post.audioDurationMs);
    final mm = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(post.content,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 4),
                _WaveformBars(color: scheme.primary),
              ],
            ),
          ),
          Text(
            '0:00 / $mm:$ss',
            style: TextStyle(
              color: scheme.onSurface.withOpacity(0.6),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformBars extends StatelessWidget {
  const _WaveformBars({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final values = [
      0.3, 0.6, 0.4, 0.8, 0.5, 0.9, 0.4, 0.7, 0.3, 0.5,
      0.7, 0.4, 0.6, 0.3, 0.7, 0.5, 0.8, 0.4, 0.6, 0.3,
    ];
    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: values
            .map((v) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Container(
                    width: 3,
                    height: 22 * v,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

/// Plug-prompt card — the heart-shaped speech-bubble container used for
/// "Question of the Day" cards.
class PromptCard extends StatelessWidget {
  const PromptCard({super.key, required this.prompt, this.onSubmit});
  final PlugPrompt prompt;
  final ValueChanged<String>? onSubmit;

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
            Text(
              '${prompt.answersCount} anonymous answers • tap to read the thread',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withOpacity(0.55),
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
