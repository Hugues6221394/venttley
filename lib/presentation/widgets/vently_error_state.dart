import 'package:flutter/material.dart';

import '../../core/user_friendly_errors.dart';
import '../theme/colors.dart';
import '../theme/vently_tokens.dart';

class VentlyErrorState extends StatelessWidget {
  const VentlyErrorState({
    super.key,
    required this.error,
    this.onRetry,
    this.title = 'Couldn\'t load this',
  });

  final Object error;
  final VoidCallback? onRetry;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VentlyTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded,
                size: 40, color: VentlyColors.berryMagenta),
            const SizedBox(height: VentlyTokens.s12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: context.ink,
                )),
            const SizedBox(height: 8),
            Text(
              UserFriendlyErrors.message(error),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink.withOpacity(0.65),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: VentlyTokens.s16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again',
                    style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
