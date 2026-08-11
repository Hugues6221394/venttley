import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';
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

/// Compact transport shown over the shell while a user-chosen whisper plays and
/// the user is somewhere other than the Whispers tab.
///
/// Renders nothing unless there is something to show, so it is safe to mount
/// unconditionally in [HomeShell].
class WhisperMiniPlayer extends ConsumerWidget {
  const WhisperMiniPlayer({super.key, required this.onOpen});

  /// Returns to the Whispers tab. Kept as a callback because only the shell can
  /// switch branches without pushing a second copy of the screen.
  final VoidCallback onOpen;

  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
                    final playing = snap.data?.playing ?? controller.isPlaying;
                    return IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: playing ? 'Pause whisper' : 'Play whisper',
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: VentlyColors.berryMagenta,
                      ),
                      onPressed: () => unawaited(controller.togglePause()),
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
    );
  }
}

/// Returns to the Whispers branch without pushing a duplicate screen.
void openWhispersTab(BuildContext context) => context.go('/whispers');
