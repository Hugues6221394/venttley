import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';

/// Unified create menu — opened from the Post tab and home CTAs.
///
/// Routes each format to the correct screen with the right prefill flags
/// so posting takes one tap after picking a format.
Future<void> showQuickCreateSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _QuickCreateSheet(),
  );
}

class _QuickCreateSheet extends ConsumerWidget {
  const _QuickCreateSheet();

  static const _formats = <_CreateFormat>[
    _CreateFormat(
      id: 'vent',
      label: 'Vent',
      subtitle: 'Share what\'s on your mind',
      icon: Icons.edit_rounded,
      tint: Color(0xFFFFE8EF),
      accent: VentlyColors.berryMagenta,
    ),
    _CreateFormat(
      id: 'voice',
      label: 'Voice Vent',
      subtitle: 'Record an audio whisper',
      icon: Icons.mic_rounded,
      tint: Color(0xFFFFF0F5),
      accent: Color(0xFFE91E8C),
    ),
    _CreateFormat(
      id: 'poll',
      label: 'Poll',
      subtitle: 'Ask the community',
      icon: Icons.poll_rounded,
      tint: Color(0xFFE8F8EE),
      accent: Color(0xFF3D9B6A),
    ),
    _CreateFormat(
      id: 'story',
      label: '24h Story',
      subtitle: 'Disappears in a day',
      icon: Icons.auto_awesome_rounded,
      tint: Color(0xFFF3E8FF),
      accent: Color(0xFF8B5CF6),
    ),
    _CreateFormat(
      id: 'question',
      label: 'Question',
      subtitle: 'Answer today\'s prompt',
      icon: Icons.help_rounded,
      tint: Color(0xFFF0F4F8),
      accent: Color(0xFF64748B),
    ),
    _CreateFormat(
      id: 'testimony',
      label: 'Testimony',
      subtitle: 'Share your comeback story',
      icon: Icons.menu_book_rounded,
      tint: Color(0xFFFFF8E8),
      accent: Color(0xFFD97706),
    ),
    _CreateFormat(
      id: 'goal',
      label: 'Goal',
      subtitle: 'Dreams & what\'s next',
      icon: Icons.flag_rounded,
      tint: Color(0xFFFFECE8),
      accent: Color(0xFFDC2626),
    ),
  ];

  void _pick(BuildContext context, WidgetRef ref, String id) {
    Navigator.of(context).pop();
    if (ref.read(sessionProvider) == null) {
      context.push('/onboarding');
      return;
    }

    switch (id) {
      case 'vent':
        ref.read(composeStoryModeProvider.notifier).state = false;
        ref.read(composeIncludePollProvider.notifier).state = false;
        ref.read(composeInitialCategoryProvider.notifier).state = 'confessions';
        context.go('/compose');
      case 'voice':
        context.push('/whispers/new');
      case 'poll':
        ref.read(composeStoryModeProvider.notifier).state = false;
        ref.read(composeIncludePollProvider.notifier).state = true;
        ref.read(composeInitialCategoryProvider.notifier).state = 'questions';
        context.go('/compose');
      case 'story':
        context.push('/compose/story');
      case 'question':
        context.push('/questions');
      case 'testimony':
        ref.read(composeStoryModeProvider.notifier).state = false;
        ref.read(composeIncludePollProvider.notifier).state = false;
        ref.read(composeInitialCategoryProvider.notifier).state = 'testimonies';
        context.go('/compose');
      case 'goal':
        ref.read(composeStoryModeProvider.notifier).state = false;
        ref.read(composeIncludePollProvider.notifier).state = false;
        ref.read(composeInitialCategoryProvider.notifier).state = 'dreams_goals';
        context.go('/compose');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: VentlyColors.berryMagenta.withOpacity(0.12),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'How are you feeling today?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: VentlyColors.berryMagenta,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Pick a format to share your vibe.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.ink.withOpacity(0.62),
                ),
              ),
              const SizedBox(height: 20),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.92,
                ),
                itemCount: _formats.length,
                itemBuilder: (ctx, i) {
                  final f = _formats[i];
                  return _FormatTile(
                    format: f,
                    onTap: () => _pick(context, ref, f.id),
                  );
                },
              ),
              const SizedBox(height: 8),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(
                  Icons.close_rounded,
                  color: context.ink.withOpacity(0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateFormat {
  const _CreateFormat({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.tint,
    required this.accent,
  });

  final String id;
  final String label;
  final String subtitle;
  final IconData icon;
  final Color tint;
  final Color accent;
}

class _FormatTile extends StatelessWidget {
  const _FormatTile({required this.format, required this.onTap});
  final _CreateFormat format;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            color: format.tint,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: format.accent.withOpacity(0.12),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.85),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(format.icon, color: format.accent, size: 22),
                ),
                const SizedBox(height: 8),
                Text(
                  format.label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: context.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
