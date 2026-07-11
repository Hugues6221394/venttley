import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/moderation_service.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';

/// Runs the safety classifier over a just-sent chat message. If it reads as a
/// self-harm / suicide signal, this (a) tags the message via [tag] so it
/// reaches the admin Safety queue, and (b) gently surfaces crisis resources to
/// the sender — the person who may be at risk. Never blocks the message; help
/// is offered, not forced.
///
/// [tag] receives the crisis level ('high' for a Tier-1 keyword hit, 'elevated'
/// for an LLM-only signal) and should call the appropriate set-crisis RPC.
Future<void> maybeSurfaceChatCrisis({
  required WidgetRef ref,
  required BuildContext context,
  required String text,
  required Future<void> Function(String level) tag,
}) async {
  if (text.trim().isEmpty) return;
  ModerationResult moderation;
  try {
    moderation = await ref.read(moderationServiceProvider).review(text);
  } catch (_) {
    return; // Safety scan is best-effort; never disrupt the send.
  }
  if (!moderation.surfaceCrisisHelpline) return;

  final level = moderation.categories.contains(HazardCategory.selfHarm) &&
          moderation.reasons.any((r) => r.contains('care about you'))
      ? 'high'
      : 'elevated';
  unawaited(tag(level).catchError((_) {}));

  if (context.mounted) {
    await showCrisisSupportSheet(context, ref);
  }
}

/// A warm, non-alarming sheet listing region-aware crisis helplines. Tapping a
/// line copies its number/link (never auto-dials — a misfire shouldn't ring an
/// emergency line).
Future<void> showCrisisSupportSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _CrisisSupportSheet(),
  );
}

class _CrisisSupportSheet extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Region-aware helplines with a hard-coded fallback so we always show
    // something even if the network list hasn't loaded.
    final live = ref.watch(crisisResourcesProvider).valueOrNull;
    final fallback = kCrisisResources
        .map((r) => CrisisHelpline(
              resourceId: r.label,
              region: 'global',
              label: r.label,
              reach: r.reach,
              hours: '24/7',
              sortOrder: 0,
            ))
        .toList();
    final resources = (live == null || live.isEmpty) ? fallback : live;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Row(
              children: [
                Icon(Icons.favorite_rounded,
                    color: VentlyColors.berryMagenta, size: 22),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "You matter. You're not alone.",
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                      color: VentlyColors.deepBurgundy,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "It sounds like you're going through something really heavy. "
              "If you want to talk to someone right now, these lines are free "
              "and confidential.",
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: VentlyColors.deepBurgundy.withOpacity(0.75),
              ),
            ),
            const SizedBox(height: 14),
            for (final r in resources.take(4))
              _HelplineTile(resource: r),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HelplineTile extends StatelessWidget {
  const _HelplineTile({required this.resource});
  final CrisisHelpline resource;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: VentlyColors.softMauve.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            // Copy, never auto-dial.
            Clipboard.setData(
                ClipboardData(text: resource.url ?? resource.reach));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Copied: ${resource.url ?? resource.reach}')),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(resource.url == null ? Icons.phone : Icons.public,
                    size: 18, color: VentlyColors.berryMagenta),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(resource.label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 13.5)),
                      Text(resource.reach,
                          style: TextStyle(
                              fontSize: 12,
                              color: VentlyColors.deepBurgundy
                                  .withOpacity(0.7))),
                    ],
                  ),
                ),
                const Icon(Icons.copy_rounded,
                    size: 15, color: VentlyColors.softMauve),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
