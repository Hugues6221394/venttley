import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/services/vently_audio_session.dart';
import '../theme/colors.dart';

/// Local playback for whisper audio bytes before upload/publish.
class WhisperAudioPreview extends StatefulWidget {
  const WhisperAudioPreview({
    super.key,
    required this.bytes,
    required this.durationSeconds,
  });

  final Uint8List bytes;
  final int durationSeconds;

  @override
  State<WhisperAudioPreview> createState() => _WhisperAudioPreviewState();
}

class _WhisperAudioPreviewState extends State<WhisperAudioPreview> {
  final _player = AudioPlayer();
  String? _tempPath;
  bool _ready = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await VentlyAudioSession.instance.ensurePlayback();
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/whisper-preview-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await File(path).writeAsBytes(widget.bytes, flush: true);
      await _player.setFilePath(path);
      await _player.setVolume(1.0);
      _tempPath = path;
      if (mounted) {
        setState(() {
          _ready = true;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('WhisperAudioPreview init failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    final path = _tempPath;
    if (path != null) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_ready) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await VentlyAudioSession.instance.ensurePlayback();
      if (_player.position >= (_player.duration ?? Duration.zero)) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 72,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_ready) {
      return const Text(
        'Could not load preview.',
        style: TextStyle(fontWeight: FontWeight.w700),
      );
    }

    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        final total = _player.duration ??
            Duration(seconds: widget.durationSeconds);
        final progress = total.inMilliseconds == 0
            ? 0.0
            : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

        return Row(
          children: [
            Material(
              color: VentlyColors.berryMagenta,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(
                    _player.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: progress,
                      activeColor: VentlyColors.berryMagenta,
                      inactiveColor: VentlyColors.softMauve.withOpacity(0.35),
                      onChanged: (v) async {
                        final ms = (total.inMilliseconds * v).round();
                        await _player.seek(Duration(milliseconds: ms));
                      },
                    ),
                  ),
                  Text(
                    '${_fmt(pos)} / ${_fmt(total)}',
                    style: TextStyle(
                      color: VentlyColors.deepBurgundy.withOpacity(0.65),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
