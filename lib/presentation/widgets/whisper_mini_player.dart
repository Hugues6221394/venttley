import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';
import '../screens/home/home_shell.dart';
import '../theme/colors.dart';

/// The whisper that may follow the user off the Whispers tab.
///
/// [startedByUser] is the whole point of this type. Whispers autoplay as pages
/// settle, so "something is playing" is not consent to keep playing elsewhere —
/// that was the reported bug (audio from a screen nobody opened). Only a whisper
/// the user deliberately moved to survives leaving the tab; the one that
/// autoplayed on entry is paused, exactly as before this existed.
@immutable
class ActiveWhisper {
  const ActiveWhisper({
    required this.whisperId,
    required this.title,
    required this.author,
    required this.startedByUser,
  });

  final String whisperId;
  final String title;
  final String author;
  final bool startedByUser;

  ActiveWhisper copyWith({bool? startedByUser}) => ActiveWhisper(
    whisperId: whisperId,
    title: title,
    author: author,
    startedByUser: startedByUser ?? this.startedByUser,
  );
}

/// Null whenever nothing should follow the user. Cleared on dismiss, on stop,
/// and when an autoplayed whisper is paused by leaving the tab.
final activeWhisperProvider = StateProvider<ActiveWhisper?>((ref) => null);

/// Where the user last dragged the player. Null means "not placed yet", which
/// resolves to just above the nav pill.
///
/// Session-scoped on purpose: a position that survives a restart would be a
/// setting, and this is a transient control.
final miniPlayerOffsetProvider = StateProvider<Offset?>((ref) => null);

/// Draggable transport shown over the shell while a user-chosen whisper plays
/// and the user is somewhere other than the Whispers tab.
///
/// Free-floating rather than docked. A docked player occupies layout space and
/// can never cover content, which is why it started that way — but it also
/// forces itself into one spot. Letting the user place it hands them that
/// tradeoff: they can move it off whatever it is covering, and dismiss it
/// outright.
///
/// Renders nothing unless there is something to show, so it is safe to mount
/// unconditionally in [HomeShell]'s Stack.
class WhisperMiniPlayer extends ConsumerWidget {
  const WhisperMiniPlayer({
    super.key,
    required this.onOpen,
    required this.onWhispersTab,
  });

  /// Returns to the Whispers tab. Kept as a callback because only the shell can
  /// switch branches without pushing a second copy of the screen.
  final VoidCallback onOpen;

  /// True while the Whispers branch is the visible one. The player is redundant
  /// there — the full transport is already on screen — and worse, it floats over
  /// it and steals drags meant for the page.
  final bool onWhispersTab;

  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (onWhispersTab) return const SizedBox.shrink();
    final active = ref.watch(activeWhisperProvider);
    if (active == null || !active.startedByUser) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final controllerAsync = ref.watch(whisperPlayerProvider);
    final controller = controllerAsync.valueOrNull;
    if (controller == null) return const SizedBox.shrink();

    // If playback moved to a different whisper (or stopped entirely), this
    // handle is stale — drop it rather than offering a transport for nothing.
    if (controller.activeWhisperId != active.whisperId) {
      return const SizedBox.shrink();
    }

    Future<void> dismiss() async {
      // Cancel, not minimise: stop the audio, then clear the handle. Hiding the
      // widget while playback continued would be the original complaint again.
      await controller.stop();
      ref.read(activeWhisperProvider.notifier).state = null;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const width = 288.0;
        const margin = 10.0;
        // Default sits above the nav pill, where a docked player would have
        // been — so the first appearance is never a surprise.
        final fallback = Offset(
          (constraints.maxWidth - width) / 2,
          constraints.maxHeight - height - HomeShell.navClearance,
        );
        final desired = ref.watch(miniPlayerOffsetProvider) ?? fallback;
        // Clamp every frame, not just on drag: a rotation or keyboard can shrink
        // the box under a position that was legal when it was chosen.
        final maxX = (constraints.maxWidth - width - margin).clamp(
          margin,
          double.infinity,
        );
        final maxY = (constraints.maxHeight - height - margin).clamp(
          margin,
          double.infinity,
        );
        final at = Offset(
          desired.dx.clamp(margin, maxX),
          desired.dy.clamp(margin, maxY),
        );

        return Positioned(
          left: at.dx,
          top: at.dy,
          width: width,
          child: GestureDetector(
            onPanUpdate: (details) =>
                ref.read(miniPlayerOffsetProvider.notifier).state =
                    at + details.delta,
            child: Material(
              color: scheme.surface,
              elevation: 8,
              shadowColor: Colors.black.withOpacity(0.18),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: onOpen,
                child: SizedBox(
                  height: height,
                  child: Row(
                    children: [
                      const SizedBox(width: 10),
                      StreamBuilder<PlayerState>(
                        stream: controller.stateStream,
                        builder: (context, snap) {
                          final playing =
                              snap.data?.playing ?? controller.isPlaying;
                          return IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: playing ? 'Pause whisper' : 'Play whisper',
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: VentlyColors.berryMagenta,
                            ),
                            onPressed: () =>
                                unawaited(controller.togglePause()),
                          );
                        },
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              active.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '@${active.author}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurface.withOpacity(0.58),
                                fontWeight: FontWeight.w600,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Stop and dismiss',
                        icon: Icon(
                          Icons.close_rounded,
                          color: scheme.onSurface.withOpacity(0.6),
                        ),
                        onPressed: () => unawaited(dismiss()),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Returns to the Whispers branch without pushing a duplicate screen.
void openWhispersTab(BuildContext context) => context.go('/whispers');
