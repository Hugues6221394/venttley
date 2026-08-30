import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../widgets/vently_premium_background.dart';
import '../feed/feed_screen.dart';
import 'keeper_home_screen.dart';

/// Role-aware Home / Studio tab.
class HomeTabScreen extends ConsumerWidget {
  const HomeTabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memberView = ref.watch(keeperMemberViewProvider);
    if (memberView) return const FeedScreen();

    final me = ref.watch(sessionProvider);
    final isKeeperAsync = ref.watch(isKeeperProvider);

    return isKeeperAsync.when(
      loading: () {
        if (me?.isPlug == true) return const _KeeperLoadingShell();
        final mode = ref.watch(keeperModeProvider).valueOrNull;
        if (mode?.isKeeper == true) return const _KeeperLoadingShell();
        return const FeedScreen();
      },
      error: (_, __) {
        if (me?.isPlug == true) return const KeeperHomeScreen();
        return const FeedScreen();
      },
      data: (isKeeper) =>
          isKeeper ? const KeeperHomeScreen() : const FeedScreen(),
    );
  }
}

class _KeeperLoadingShell extends StatelessWidget {
  const _KeeperLoadingShell();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                'Plug Studio',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  letterSpacing: -0.4,
                ),
              ),
              const Spacer(),
              const CircularProgressIndicator(
                color: VentlyColors.berryMagenta,
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}
