import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/keeper/keeper_studio_v2.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/keeper_prompt_composer_sheet.dart';
import 'keeper_studio_scaffold.dart';

/// Engagement calendar — scheduled prompts + cadence suggestions.
class KeeperEngagementCalendarScreen extends ConsumerWidget {
  const KeeperEngagementCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);
    final tribeId = tribe?.tribeId;
    final calAsync = tribeId == null
        ? const AsyncValue<KeeperEngagementCalendar>.loading()
        : ref.watch(keeperEngagementCalendarProvider(tribeId));

    return KeeperStudioScaffold(
      title: 'Engagement Calendar',
      subtitle: 'Schedule prompts that keep your tribe talking',
      onRefresh: () async {
        if (tribeId != null) {
          ref.invalidate(keeperEngagementCalendarProvider(tribeId));
        }
      },
      child: calAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
          ),
        ),
        error: (e, _) => Text('Could not load calendar: $e'),
        data: (cal) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tribe != null)
              FilledButton.icon(
                onPressed: () => showKeeperPromptComposer(
                  context,
                  tribeId: tribe.tribeId,
                  scheduleRequired: true,
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  'Schedule new prompt',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            const SizedBox(height: 18),
            _SectionTitle('Upcoming', count: cal.scheduled.length),
            const SizedBox(height: 8),
            if (cal.scheduled.isEmpty)
              const _EmptyHint(
                'Nothing scheduled yet — plan your next check-in.',
              )
            else
              ...cal.scheduled.map(
                (p) => _PromptTile(prompt: p, upcoming: true),
              ),
            const SizedBox(height: 18),
            _SectionTitle(
              'Recently published',
              count: cal.recentPublished.length,
            ),
            const SizedBox(height: 8),
            if (cal.recentPublished.isEmpty)
              const _EmptyHint('Published prompts will appear here.')
            else
              ...cal.recentPublished.map(
                (p) => _PromptTile(prompt: p, upcoming: false),
              ),
            const SizedBox(height: 18),
            _SectionTitle('Suggested cadence', count: cal.suggestions.length),
            const SizedBox(height: 8),
            ...cal.suggestions.map(_SuggestionTile.new),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: context.ink,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: TextStyle(
            color: VentlyColors.berryMagenta.withOpacity(0.8),
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Text(
        text,
        style: TextStyle(
          color: context.ink.withOpacity(0.65),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PromptTile extends StatelessWidget {
  const _PromptTile({required this.prompt, required this.upcoming});
  final KeeperCalendarPrompt prompt;
  final bool upcoming;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat.MMMd().add_jm();
    final when = upcoming ? prompt.scheduledFor : prompt.publishedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              upcoming ? Icons.schedule_rounded : Icons.check_circle_rounded,
              color: VentlyColors.berryMagenta,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prompt.promptText,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: context.ink,
                    ),
                  ),
                  if (when != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        upcoming
                            ? 'Goes live ${fmt.format(when.toLocal())}'
                            : 'Published ${fmt.format(when.toLocal())}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: context.ink.withOpacity(0.55),
                        ),
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

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile(this.suggestion);
  final KeeperCalendarSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              suggestion.title,
              style: TextStyle(fontWeight: FontWeight.w900, color: context.ink),
            ),
            const SizedBox(height: 4),
            Text(
              suggestion.hint,
              style: TextStyle(
                color: context.ink.withOpacity(0.65),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
