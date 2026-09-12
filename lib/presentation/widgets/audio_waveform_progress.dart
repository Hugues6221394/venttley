import 'package:flutter/material.dart';

/// Static waveform bars that fill up to [progress] (0–1).
class AudioWaveformProgress extends StatelessWidget {
  const AudioWaveformProgress({
    super.key,
    required this.progress,
    this.activeColor = Colors.white,
    this.inactiveColor,
    this.height = 26,
  });

  final double progress;
  final Color activeColor;
  final Color? inactiveColor;
  final double height;

  static const _heights = <double>[
    10,
    18,
    14,
    24,
    18,
    28,
    16,
    20,
    14,
    24,
    18,
    12,
    22,
    16,
    24,
    18,
    14,
    22,
    16,
    26,
    14,
    18,
    12,
    24,
  ];

  @override
  Widget build(BuildContext context) {
    final muted = inactiveColor ?? activeColor.withOpacity(0.32);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (_, __) {
          final filledBars = (_heights.length * progress).round().clamp(
            0,
            _heights.length,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _heights.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: _heights[i],
                      decoration: BoxDecoration(
                        color: i < filledBars ? activeColor : muted,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

String formatAudioDuration(int secs) {
  final mm = (secs ~/ 60);
  final ss = (secs % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

String formatAudioDurationFromDuration(Duration d) {
  final mm = d.inMinutes.remainder(60);
  final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$mm:$ss';
}
