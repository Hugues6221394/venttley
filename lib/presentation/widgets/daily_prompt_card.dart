import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';
import '../theme/vently_tokens.dart';

/// Compact once-per-day nudge — not a full-screen hero.
class DailyPromptCard extends ConsumerStatefulWidget {
  const DailyPromptCard({super.key});

  @override
  ConsumerState<DailyPromptCard> createState() => _DailyPromptCardState();
}

class _DailyPromptCardState extends ConsumerState<DailyPromptCard> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key =
          'daily_prompt_dismissed_${DateTime.now().toIso8601String().substring(0, 10)}';
      if (mounted) setState(() => _dismissed = prefs.getBool(key) ?? false);
    } catch (_) {}
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final key =
          'daily_prompt_dismissed_${DateTime.now().toIso8601String().substring(0, 10)}';
      await prefs.setBool(key, true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.9),
          borderRadius: BorderRadius.circular(VentlyTokens.radiusCard),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: VentlyTokens.growthTeal.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: VentlyTokens.growthTeal,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Drop a vent today',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                      color: context.ink,
                    ),
                  ),
                  Text(
                    'Anonymous. 24h stories for friends. Your feed stays alive.',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: context.ink.withOpacity(0.58),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () {
                ref.read(composeStoryModeProvider.notifier).state = false;
                context.go('/compose');
              },
              child: const Text(
                'Vent',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: context.ink.withOpacity(0.45),
              onPressed: _dismiss,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }
}
