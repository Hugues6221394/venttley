import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../data/services/voice_mask_service.dart';

class VoiceRecordScreen extends ConsumerStatefulWidget {
  const VoiceRecordScreen({super.key});

  @override
  ConsumerState<VoiceRecordScreen> createState() => _VoiceRecordScreenState();
}

class _VoiceRecordScreenState extends ConsumerState<VoiceRecordScreen>
    with SingleTickerProviderStateMixin {
  bool _recording = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  VoiceMask _mask = VoiceMask.whisper;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _toggleRecord() {
    setState(() => _recording = !_recording);
    _timer?.cancel();
    if (_recording) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    } else {
      _elapsed = Duration.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Vent'),
        actions: [
          IconButton(icon: const Icon(Icons.help_outline), onPressed: () {}),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      _WaveformPulse(animation: _pulse, color: scheme.primary),
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: _toggleRecord,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: _recording ? 86 : 76,
                          height: _recording ? 86 : 76,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: scheme.primary.withOpacity(0.4),
                                blurRadius: 26,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            _recording ? Icons.stop : Icons.mic,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _fmtDuration(_elapsed),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                        ),
                      ),
                      Text(
                        _recording ? 'Recording…' : 'Tap to record',
                        style: TextStyle(
                          color: scheme.onSurface.withOpacity(0.65),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Voice Filters',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.shield, size: 12, color: scheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          'Mask active',
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1,
                children: [
                  for (final m in VoiceMask.values)
                    GestureDetector(
                      onTap: () => setState(() => _mask = m),
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: _mask == m
                              ? scheme.primary
                              : Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: scheme.primary.withOpacity(0.35)),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _iconFor(m),
                              color: _mask == m
                                  ? Colors.white
                                  : scheme.primary,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              m.label,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _mask == m
                                    ? Colors.white
                                    : null,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Preview Voice'),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () async {
                  await ref.read(repositoryProvider).createPost(
                        content: 'Voice confession',
                        category: 'vent_zone',
                        mood: 'overthinking',
                        isAudio: true,
                        audioUrl: 'local://demo/voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
                        audioDurationMs: _elapsed.inMilliseconds,
                      );
                  if (!mounted) return;
                  context.go('/feed');
                },
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('Post Confession'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(VoiceMask m) {
    switch (m) {
      case VoiceMask.whisper:    return Icons.cloud_outlined;
      case VoiceMask.brightEcho: return Icons.wb_sunny_outlined;
      case VoiceMask.helium:     return Icons.bubble_chart_outlined;
      case VoiceMask.robot:      return Icons.smart_toy_outlined;
      case VoiceMask.deepPitch:  return Icons.surround_sound;
      case VoiceMask.echo:       return Icons.repeat;
    }
  }

  String _fmtDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

class _WaveformPulse extends AnimatedWidget {
  const _WaveformPulse({required Animation<double> animation, required this.color})
      : super(listenable: animation);
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    final values = List.generate(28, (i) {
      final base = sin((i / 28) * pi * 2 + t * pi * 2).abs();
      return 14 + base * 28;
    });
    return SizedBox(
      height: 60,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final v in values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 3,
                height: v,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
