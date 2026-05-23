import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';

/// Interactive two-or-more-option poll attached to a Post.
///
/// Renders three states:
///   * not voted + open → tappable options
///   * voted OR closed → bar chart with percentages + own-vote highlight
class PollCard extends ConsumerWidget {
  const PollCard({super.key, required this.poll, this.compact = false});

  final PostPoll poll;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showResults = poll.hasVoted || poll.isClosed;
    final total = poll.totalVotes.clamp(1, 1 << 30);

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: compact ? 0 : 16,
        vertical: compact ? 6 : 8,
      ),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.30 : 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'POLL',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              Text(
                poll.isClosed
                    ? 'Closed'
                    : '${poll.totalVotes} ${poll.totalVotes == 1 ? "vote" : "votes"}',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            poll.question,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          for (final o in poll.options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _OptionRow(
                option: o,
                isMine: poll.myVoteOptionId == o.optionId,
                showResults: showResults,
                pct: poll.optionCounts[o.optionId] == null
                    ? 0
                    : (poll.optionCounts[o.optionId]! / total),
                onTap: showResults
                    ? null
                    : () async {
                        await ref.read(repositoryProvider).votePoll(
                              pollId: poll.pollId,
                              optionId: o.optionId,
                            );
                        ref.invalidate(pollForPostProvider(poll.postId));
                      },
              ),
            ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.isMine,
    required this.showResults,
    required this.pct,
    required this.onTap,
  });
  final PollOption option;
  final bool isMine;
  final bool showResults;
  final double pct;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            if (showResults)
              FractionallySizedBox(
                widthFactor: pct.isFinite ? pct.clamp(0.0, 1.0) : 0,
                child: Container(
                  height: 36,
                  color: isMine
                      ? scheme.primary.withOpacity(0.55)
                      : scheme.primary.withOpacity(0.20),
                ),
              ),
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: scheme.primary.withOpacity(isDark ? 0.30 : 0.22),
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  if (isMine)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.check_circle,
                          size: 14, color: scheme.primary),
                    ),
                  Expanded(
                    child: Text(
                      option.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: isMine ? scheme.primary : null,
                      ),
                    ),
                  ),
                  if (showResults)
                    Text(
                      '${(pct * 100).round()}%',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: scheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
