import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/vently_premium_background.dart';

/// Shared chrome for Creator Studio V2 push screens.
class KeeperStudioScaffold extends ConsumerWidget {
  const KeeperStudioScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onRefresh,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: VentlyPremiumBackground(
        child: tribe == null
            ? const _NoTribeState()
            : RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: onRefresh ?? () async {},
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text(
                          subtitle!,
                          style: TextStyle(
                            color: VentlyColors.berryMagenta.withOpacity(0.9),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      )
                    else if (tribe.name.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text(
                          tribe.name,
                          style: TextStyle(
                            color: VentlyColors.berryMagenta.withOpacity(0.9),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    child,
                  ],
                ),
              ),
      ),
    );
  }
}

class _NoTribeState extends StatelessWidget {
  const _NoTribeState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.diversity_3,
              size: 48,
              color: VentlyColors.berryMagenta,
            ),
            const SizedBox(height: 12),
            Text(
              'Create a tribe first',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Creator Studio tools unlock once you keep at least one tribe.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.ink.withOpacity(0.65)),
            ),
          ],
        ),
      ),
    );
  }
}

String keeperTribeSlug(Tribe? tribe) => tribe?.slug ?? '';
