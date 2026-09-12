import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Reveal the locally cached 12-word recovery phrase after a confirmation
/// gate. Used from Profile and Settings.
Future<void> showRecoveryPhraseDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final phrase = await ref
      .read(repositoryProvider)
      .identity
      .savedRecoveryPhrase();
  if (!context.mounted) return;
  if (phrase == null || phrase.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery phrase not on this device'),
        content: const Text(
          'Your phrase is only stored on the device where you signed up. '
          'If you have it written down, keep it safe — it is the only way '
          'to restore your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  final confirmed =
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Show recovery phrase?'),
          content: const Text(
            'Make sure nobody is looking at your screen. Anyone with this '
            'phrase can restore your account on any device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Show'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed || !context.mounted) return;
  final words = phrase.split(' ');
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Your recovery phrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < words.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(ctx).colorScheme.primary.withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    '${i + 1}. ${words[i]}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Write it on paper. Do not screenshot.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}
