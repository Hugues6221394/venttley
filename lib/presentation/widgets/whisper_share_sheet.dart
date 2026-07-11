import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'glass_card.dart';

/// Deep link + native share sheet for a Whisper.
Future<void> showWhisperShareSheet(
  BuildContext context,
  Whisper whisper,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _WhisperShareSheet(whisper: whisper),
  );
}

class _WhisperShareSheet extends StatelessWidget {
  const _WhisperShareSheet({required this.whisper});
  final Whisper whisper;

  String get _link => 'https://venttly.app/whisper/${whisper.whisperId}';

  String get _shareText {
    final title = whisper.title?.trim();
    if (title != null && title.isNotEmpty) {
      return 'Listen to "$title" on Venttly — anonymous voice stories.\n$_link';
    }
    return 'Listen to this Whisper on Venttly — anonymous voice stories.\n$_link';
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom + 12),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const Text(
              'Share Whisper',
              style: TextStyle(
                color: VentlyColors.deepBurgundy,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              whisper.title?.isNotEmpty == true
                  ? whisper.title!
                  : 'Anonymous voice story',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: VentlyColors.deepBurgundy.withOpacity(0.65),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            _ShareAction(
              icon: Icons.link_rounded,
              label: 'Copy link',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: _link));
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            _ShareAction(
              icon: Icons.ios_share,
              label: 'Share via…',
              onTap: () async {
                Navigator.pop(context);
                await Share.share(_shareText, subject: 'Venttly Whisper');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareAction extends StatelessWidget {
  const _ShareAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            color: VentlyColors.berryMagenta.withOpacity(0.08),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: VentlyColors.berryMagenta, size: 22),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(
                    color: VentlyColors.deepBurgundy,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
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
