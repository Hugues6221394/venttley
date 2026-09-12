import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/services/vently_audio_session.dart';
import 'audio_waveform_progress.dart';

/// Ensures only one tribe-chat voice note plays at a time.
class ChatAudioPlaybackScope {
  ChatAudioPlaybackScope._();

  static AudioPlayer? _activePlayer;
  static String? _activeMessageId;

  static Future<void> claim(String messageId, AudioPlayer player) async {
    if (_activePlayer != null &&
        _activePlayer != player &&
        _activeMessageId != messageId) {
      await _activePlayer!.stop();
    }
    _activePlayer = player;
    _activeMessageId = messageId;
  }

  static void release(String messageId, AudioPlayer player) {
    if (_activeMessageId == messageId && _activePlayer == player) {
      _activePlayer = null;
      _activeMessageId = null;
    }
  }
}

/// Live voice-note bubble for tribe group chat.
class ChatAudioBubble extends StatefulWidget {
  const ChatAudioBubble({
    super.key,
    required this.messageId,
    required this.audioUrl,
    required this.durationSeconds,
    this.caption,
    this.lightOnDark = true,
  });

  final String messageId;
  final String audioUrl;
  final int durationSeconds;
  final String? caption;
  final bool lightOnDark;

  @override
  State<ChatAudioBubble> createState() => _ChatAudioBubbleState();
}

class _ChatAudioBubbleState extends State<ChatAudioBubble> {
  final _player = AudioPlayer();
  bool _ready = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await VentlyAudioSession.instance.ensurePlayback();
      await _player.setUrl(widget.audioUrl);
      await _player.setVolume(1.0);
      if (mounted) {
        setState(() {
          _ready = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load audio';
        });
      }
      debugPrint('ChatAudioBubble init failed: $e');
    }
  }

  @override
  void dispose() {
    ChatAudioPlaybackScope.release(widget.messageId, _player);
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_ready) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await VentlyAudioSession.instance.ensurePlayback();
      await ChatAudioPlaybackScope.claim(widget.messageId, _player);
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _seek(double progress) async {
    if (!_ready) return;
    final total = _player.duration ?? Duration(seconds: widget.durationSeconds);
    final ms = (total.inMilliseconds * progress).round();
    await _player.seek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.lightOnDark ? Colors.white : const Color(0xFF5A1538);
    final playBg = widget.lightOnDark
        ? Colors.white.withOpacity(0.25)
        : const Color(0xFFFFE3EC);

    if (_loading) {
      return SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: fg.withOpacity(0.8),
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Text(
        _error!,
        style: TextStyle(
          color: fg.withOpacity(0.85),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      );
    }

    return StreamBuilder<PlayerState>(
      stream: _player.playerStateStream,
      builder: (context, stateSnap) {
        final playing = stateSnap.data?.playing ?? _player.playing;
        return StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final total =
                _player.duration ?? Duration(seconds: widget.durationSeconds);
            final progress = total.inMilliseconds == 0
                ? 0.0
                : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
            final elapsed = playing || pos > Duration.zero
                ? formatAudioDurationFromDuration(pos)
                : formatAudioDuration(widget.durationSeconds);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Material(
                      color: playBg,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _toggle,
                        child: SizedBox(
                          width: 38,
                          height: 38,
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: fg,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTapDown: (d) {
                          final box = context.findRenderObject() as RenderBox?;
                          if (box == null) return;
                          final w = box.size.width;
                          if (w <= 0) return;
                          _seek((d.localPosition.dx / w).clamp(0.0, 1.0));
                        },
                        child: AudioWaveformProgress(
                          progress: progress,
                          activeColor: fg,
                          inactiveColor: fg.withOpacity(0.32),
                          height: 30,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      elapsed,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                if (widget.caption != null &&
                    widget.caption!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '"${widget.caption}"',
                    style: TextStyle(
                      color: fg,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
