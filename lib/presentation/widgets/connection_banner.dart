import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../theme/colors.dart';

/// Slim status strip under the system bar: "You're offline" while the
/// network is down, "Reconnecting…" while we resync, plus a queued-sends
/// note whenever the outbox is holding anything. Hidden when all is well.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionStatusProvider);
    final queued = ref.watch(outboxPendingCountProvider);
    final failed = ref.watch(outboxFailedCountProvider);

    final visible =
        status != ConnectionStatus.online || queued > 0 || failed > 0;
    final String text;
    final IconData icon;
    if (failed > 0) {
      text = '$failed send${failed == 1 ? '' : 's'} need attention';
      icon = Icons.error_outline_rounded;
    } else if (status == ConnectionStatus.offline) {
      text = queued > 0
          ? "You're offline — $queued send${queued == 1 ? '' : 's'} queued"
          : "You're offline — drafts are saved";
      icon = Icons.cloud_off_rounded;
    } else if (status == ConnectionStatus.reconnecting) {
      text = 'Reconnecting…';
      icon = Icons.sync_rounded;
    } else {
      text = 'Sending $queued queued item${queued == 1 ? '' : 's'}…';
      icon = Icons.schedule_send_rounded;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, anim) => SizeTransition(
        sizeFactor: anim,
        axisAlignment: -1,
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: !visible
          ? const SizedBox.shrink()
          : SafeArea(
              bottom: false,
              child: Container(
                key: ValueKey('$status-$queued-$failed'),
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: VentlyColors.berryMagenta.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 14, color: Colors.white),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (failed > 0) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Retry failed sends',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        padding: EdgeInsets.zero,
                        color: Colors.white,
                        onPressed: status == ConnectionStatus.offline
                            ? null
                            : () async {
                                final outbox = ref
                                    .read(outboxProvider)
                                    .valueOrNull;
                                if (outbox == null) return;
                                await outbox.retryFailed();
                                await outbox.flush();
                              },
                        icon: const Icon(Icons.refresh_rounded, size: 17),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
