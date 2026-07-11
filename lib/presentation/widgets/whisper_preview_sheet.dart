import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'glass_card.dart';
import 'whisper_audio_preview.dart';

/// Pre-publish review — audio is not uploaded until the user confirms.
Future<bool> showWhisperPreviewSheet({
  required BuildContext context,
  required Uint8List audioBytes,
  required int durationSeconds,
  required String category,
  required String voiceFilter,
  Uint8List? backgroundBytes,
  String? title,
  String? description,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _WhisperPreviewSheet(
      audioBytes: audioBytes,
      durationSeconds: durationSeconds,
      category: category,
      voiceFilter: voiceFilter,
      backgroundBytes: backgroundBytes,
      title: title,
      description: description,
    ),
  );
  return result == true;
}

class _WhisperPreviewSheet extends StatelessWidget {
  const _WhisperPreviewSheet({
    required this.audioBytes,
    required this.durationSeconds,
    required this.category,
    required this.voiceFilter,
    this.backgroundBytes,
    this.title,
    this.description,
  });

  final Uint8List audioBytes;
  final int durationSeconds;
  final String category;
  final String voiceFilter;
  final Uint8List? backgroundBytes;
  final String? title;
  final String? description;

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
              'Preview your Whisper',
              style: TextStyle(
                color: VentlyColors.deepBurgundy,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Listen before you publish — nothing uploads until you confirm.',
              style: TextStyle(
                color: VentlyColors.deepBurgundy.withOpacity(0.62),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            if (backgroundBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.memory(
                    backgroundBytes!,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            if (backgroundBytes != null) const SizedBox(height: 16),
            WhisperAudioPreview(
              bytes: audioBytes,
              durationSeconds: durationSeconds,
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(label: category),
                _Chip(label: WhisperVoiceFilters.label(voiceFilter)),
              ],
            ),
            if (title != null && title!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                title!,
                style: const TextStyle(
                  color: VentlyColors.deepBurgundy,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ],
            if (description != null && description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                description!,
                style: TextStyle(
                  color: VentlyColors.deepBurgundy.withOpacity(0.72),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: VentlyColors.deepBurgundy,
                      side: BorderSide(
                        color: VentlyColors.softMauve.withOpacity(0.6),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text(
                      'Edit',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text(
                      'Publish',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: VentlyColors.berryMagenta.withOpacity(0.1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: VentlyColors.berryMagenta,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
