import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';

/// The first frame of every launch, held until the app knows who you are.
///
/// Restoring a session is a network call that runs after the first frame, so
/// there is a moment where the app genuinely does not know. It used to spend
/// that moment on the welcome screen — which meant everybody who was already
/// signed in was shown a sign-up page on the way into their own account, and
/// then thrown to the feed when the answer arrived.
///
/// A waiting room rather than a brand moment: no spinner racing a 40ms answer
/// into existence, and nothing to read or tap. On a warm start it is gone
/// before it can be perceived, which is the point — the screen you remember
/// should be the feed.
class LaunchingScreen extends StatelessWidget {
  const LaunchingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: VentlyTokens.canvas,
      body: Center(
        child: Text(
          'Venttly',
          key: const ValueKey('launching'),
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            // The wordmark, in the one colour it is ever drawn in.
            color: scheme.brightness == Brightness.dark
                ? VentlyColors.berryDesat
                : VentlyColors.berryMagenta,
          ),
        ),
      ),
    );
  }
}
