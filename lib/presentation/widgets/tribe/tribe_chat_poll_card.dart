import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/tribe/tribe_chat_poll.dart';
import '../../theme/colors.dart';
import '../glass_card.dart';

/// Rich in-chat poll card — vote inline without leaving tribe chat.
class TribeChatPollCard extends ConsumerWidget {
  const TribeChatPollCard({
    super.key,
    required this.poll,
    required this.tribeId,
    this.compact = false,
    this.lightOnDark = false,
    this.canManage = false,
  });

  final TribeChatPoll poll;
  final String tribeId;
  final bool compact;
  final bool lightOnDark;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final showResults = poll.showResults;

    return GlassCard(
      padding: EdgeInsets.all(compact ? 12 : 14),
      borderRadius: compact ? 18 : 20,
      tint: lightOnDark ? Colors.white.withOpacity(0.14) : null,
      borderColor: lightOnDark
          ? Colors.white.withOpacity(0.28)
          : scheme.primary.withOpacity(0.22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.poll_outlined,
                size: 14,
                color: lightOnDark ? Colors.white : scheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                poll.isClosed ? 'POLL · CLOSED' : 'POLL',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                  color: lightOnDark ? Colors.white : scheme.primary,
                ),
              ),
              const Spacer(),
              Text(
                poll.isClosed
                    ? '${poll.totalVotes} votes · final'
                    : '${poll.totalVotes} ${poll.totalVotes == 1 ? "vote" : "votes"}',
                style: TextStyle(
                  fontSize: 11,
                  color: lightOnDark
                      ? Colors.white.withOpacity(0.75)
                      : scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            poll.question,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: compact ? 13 : 14,
              height: 1.3,
              color: lightOnDark ? Colors.white : null,
            ),
          ),
          if (poll.anonymousVotes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Anonymous votes',
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: lightOnDark
                      ? Colors.white.withOpacity(0.7)
                      : scheme.onSurface.withOpacity(0.5),
                ),
              ),
            ),
          const SizedBox(height: 10),
          for (final o in poll.options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _OptionRow(
                option: o,
                isMine: poll.myVoteOptionId == o.id,
                showResults: showResults,
                pct: poll.fractionFor(o.id),
                lightOnDark: lightOnDark,
                onTap: showResults
                    ? null
                    : () async {
                        await ref
                            .read(repositoryProvider)
                            .voteTribeChatPoll(
                              messageId: poll.messageId,
                              optionId: o.id,
                            );
                        unawaited(
                          ref
                              .read(repositoryProvider)
                              .refreshTribeMessages(tribeId),
                        );
                      },
              ),
            ),
          if (canManage && !poll.isClosed)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await ref
                      .read(repositoryProvider)
                      .closeTribeChatPoll(poll.messageId);
                  unawaited(
                    ref.read(repositoryProvider).refreshTribeMessages(tribeId),
                  );
                },
                child: Text(
                  'Close poll',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: lightOnDark ? Colors.white : scheme.primary,
                  ),
                ),
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
    required this.lightOnDark,
    required this.onTap,
  });

  final TribeChatPollOption option;
  final bool isMine;
  final bool showResults;
  final double pct;
  final bool lightOnDark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = lightOnDark ? Colors.white : scheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            if (showResults)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: pct.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (ctx, widthFactor, child) => FractionallySizedBox(
                  widthFactor: widthFactor.isFinite ? widthFactor : 0,
                  child: Container(
                    height: 36,
                    color: isMine
                        ? accent.withOpacity(0.55)
                        : accent.withOpacity(0.20),
                  ),
                ),
              ),
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: accent.withOpacity(0.28)),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  if (isMine)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.check_circle, size: 14, color: accent),
                    ),
                  Expanded(
                    child: Text(
                      option.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: isMine
                            ? accent
                            : (lightOnDark ? Colors.white : null),
                      ),
                    ),
                  ),
                  if (showResults)
                    Text(
                      '${(pct * 100).round()}%',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: accent,
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

/// Keeper question / prompt card in tribe chat.
class TribeChatQuestionCard extends StatelessWidget {
  const TribeChatQuestionCard({
    super.key,
    required this.question,
    this.lightOnDark = false,
    this.answerCount = 0,
    this.onTap,
    this.showTapHint = true,
  });

  final TribeChatQuestion question;
  final bool lightOnDark;
  final int answerCount;
  final VoidCallback? onTap;
  final bool showTapHint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: GlassCard(
          padding: const EdgeInsets.all(14),
          borderRadius: 20,
          tint: lightOnDark ? Colors.white.withOpacity(0.14) : null,
          borderColor: lightOnDark
              ? Colors.white.withOpacity(0.28)
              : VentlyColors.berryMagenta.withOpacity(0.25),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.help_outline_rounded,
                    size: 14,
                    color: lightOnDark ? Colors.white : scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    question.autoCheckin ? 'DAILY CHECK-IN' : 'QUESTION',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w800,
                      color: lightOnDark ? Colors.white : scheme.primary,
                    ),
                  ),
                  const Spacer(),
                  if (answerCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$answerCount ${answerCount == 1 ? "answer" : "answers"}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                question.prompt,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  height: 1.35,
                  color: lightOnDark ? Colors.white : context.ink,
                ),
              ),
              if (showTapHint) ...[
                const SizedBox(height: 6),
                Text(
                  answerCount > 0
                      ? 'Tap to read answers or add yours.'
                      : 'Tap to be the first to answer.',
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: lightOnDark
                        ? Colors.white.withOpacity(0.72)
                        : scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
