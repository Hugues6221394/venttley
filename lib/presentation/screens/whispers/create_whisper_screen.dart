import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/services/whisper_recorder.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/whisper_audio_preview.dart';
import '../../widgets/whisper_preview_sheet.dart';

/// Create Whisper — record audio + tag category + pick background +
/// choose voice filter + publish.
///
/// Voice filters are tagged (not yet DSP-processed) so the audio is
/// uploaded as-is and the `voice_filter` column captures the user's
/// intent. Real-time filtering ships separately — when it does, only
/// this screen + the recorder service change.
class CreateWhisperScreen extends ConsumerStatefulWidget {
  const CreateWhisperScreen({super.key});
  @override
  ConsumerState<CreateWhisperScreen> createState() =>
      _CreateWhisperScreenState();
}

class _CreateWhisperScreenState extends ConsumerState<CreateWhisperScreen> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _recording = false;
  bool _busy = false;

  // Capture results
  Uint8List? _recordedBytes;
  int _recordedSeconds = 0;

  // Composition
  String _category = 'confessions';
  String _voiceFilter = 'none';
  Uint8List? _backgroundBytes;
  String? _backgroundUploadedUrl;
  final _titleCtl = TextEditingController();
  final _descCtl = TextEditingController();

  @override
  void dispose() {
    _ticker?.cancel();
    _titleCtl.dispose();
    _descCtl.dispose();
    // Drop any in-flight recording without uploading
    unawaited(WhisperRecorder.instance.cancel());
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      final result = await WhisperRecorder.instance.stop();
      _ticker?.cancel();
      if (!mounted) return;
      if (result != null) {
        setState(() {
          _recording = false;
          _recordedBytes = result.bytes;
          _recordedSeconds = result.duration.inSeconds.clamp(3, 180);
        });
      } else {
        setState(() {
          _recording = false;
          _elapsed = Duration.zero;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No audio captured. Try again.')),
        );
      }
      return;
    }

    final ok = await WhisperRecorder.instance.start();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission required.')),
      );
      return;
    }
    setState(() {
      _recording = true;
      _elapsed = Duration.zero;
      _recordedBytes = null;
      _recordedSeconds = 0;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _elapsed = Duration(seconds: t.tick);
      });
      if (_elapsed.inSeconds >= 180) {
        _toggleRecord();
      }
    });
  }

  Future<void> _pickBackground() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 88,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _backgroundBytes = bytes);
  }

  Future<void> _confirmPublish() async {
    if (_recordedBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Record your whisper first.')),
      );
      return;
    }
    if (_recordedSeconds < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Whispers need at least 3 seconds of audio.'),
        ),
      );
      return;
    }
    final confirmed = await showWhisperPreviewSheet(
      context: context,
      audioBytes: _recordedBytes!,
      durationSeconds: _recordedSeconds,
      category: _category,
      voiceFilter: _voiceFilter,
      backgroundBytes: _backgroundBytes,
      title: _titleCtl.text.trim().isEmpty ? null : _titleCtl.text.trim(),
      description: _descCtl.text.trim().isEmpty ? null : _descCtl.text.trim(),
    );
    if (confirmed && mounted) {
      await _publish();
    }
  }

  Future<void> _publish() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      // 1. Upload audio
      final upload = await repo.uploadWhisperAudio(
        bytes: _recordedBytes!,
        extension: 'm4a',
        contentType: 'audio/mp4',
      );
      // 2. Optional background image — reuse whisper-media bucket via
      //    a second upload so we don't need a separate one.
      String? bgUrl = _backgroundUploadedUrl;
      if (_backgroundBytes != null && bgUrl == null) {
        final bg = await repo.uploadWhisperAudio(
          bytes: _backgroundBytes!,
          extension: 'jpg',
          contentType: 'image/jpeg',
        );
        bgUrl = bg.url;
        _backgroundUploadedUrl = bgUrl;
      }
      // 3. Publish
      final whisperId = await repo.createWhisper(
        audioPath: upload.path,
        audioUrl: upload.url,
        audioDurationSeconds: _recordedSeconds,
        category: _category,
        backgroundImageUrl: bgUrl,
        voiceFilter: _voiceFilter,
        title: _titleCtl.text.trim().isEmpty ? null : _titleCtl.text.trim(),
        description: _descCtl.text.trim().isEmpty ? null : _descCtl.text.trim(),
      );
      ref.invalidate(whispersFeedProvider);
      ref.invalidate(myWhispersProvider);
      ref.invalidate(popularWhispersProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Whisper published.')),
      );
      context.go('/whispers?whisper=$whisperId');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(e,
                fallback: 'Could not publish whisper.'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Record a Whisper',
            style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.transparent,
        foregroundColor: context.ink,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _busy ? null : _confirmPublish,
            style: TextButton.styleFrom(
              foregroundColor: VentlyColors.berryMagenta,
            ),
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Publish',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
          ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _BackgroundPreview(
                  bytes: _backgroundBytes,
                  onPick: _pickBackground,
                  onClear: _backgroundBytes == null
                      ? null
                      : () => setState(() => _backgroundBytes = null),
                ),
                const SizedBox(height: 18),
                _RecordButton(
                  recording: _recording,
                  elapsed: _elapsed,
                  hasRecording: _recordedBytes != null,
                  recordedSeconds: _recordedSeconds,
                  onTap: _toggleRecord,
                  onRetake: _recordedBytes == null
                      ? null
                      : () => setState(() {
                            _recordedBytes = null;
                            _recordedSeconds = 0;
                            _elapsed = Duration.zero;
                          }),
                ),
                if (_recordedBytes != null) ...[
                  const SizedBox(height: 14),
                  WhisperAudioPreview(
                    bytes: _recordedBytes!,
                    durationSeconds: _recordedSeconds,
                  ),
                ],
                const SizedBox(height: 18),
                const _SectionLabel(label: 'Category'),
                const SizedBox(height: 8),
                _CategoryPicker(
                  active: _category,
                  onPick: (c) => setState(() => _category = c),
                ),
                const SizedBox(height: 18),
                const _SectionLabel(label: 'Voice filter'),
                const SizedBox(height: 8),
                _VoiceFilterPicker(
                  active: _voiceFilter,
                  onPick: (v) => setState(() => _voiceFilter = v),
                ),
                const SizedBox(height: 18),
                const _SectionLabel(label: 'Title (optional)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _titleCtl,
                  maxLength: 80,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    hintText: 'A tiny headline for your story…',
                    hintStyle: TextStyle(
                      color: context.ink.withOpacity(0.42),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: VentlyColors.softMauve.withOpacity(0.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const _SectionLabel(label: 'Description (optional)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _descCtl,
                  maxLength: 280,
                  maxLines: 3,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'Add context, advice, or a question for listeners…',
                    hintStyle: TextStyle(
                      color: context.ink.withOpacity(0.42),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: VentlyColors.softMauve.withOpacity(0.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        color: context.ink.withOpacity(0.6),
        fontWeight: FontWeight.w900,
        fontSize: 11,
        letterSpacing: 1.0,
      ),
    );
  }
}

class _BackgroundPreview extends StatelessWidget {
  const _BackgroundPreview({
    required this.bytes,
    required this.onPick,
    required this.onClear,
  });
  final Uint8List? bytes;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bytes != null)
              Image.memory(bytes!, fit: BoxFit.cover)
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      VentlyColors.berryMagenta.withOpacity(0.9),
                      context.ink,
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 12,
              bottom: 12,
              child: FilledButton.icon(
                onPressed: onPick,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black.withOpacity(0.55),
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                icon: const Icon(Icons.image_outlined, size: 14),
                label: Text(bytes == null ? 'Pick a background' : 'Replace'),
              ),
            ),
            if (onClear != null)
              Positioned(
                right: 12,
                top: 12,
                child: InkWell(
                  onTap: onClear,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.recording,
    required this.elapsed,
    required this.hasRecording,
    required this.recordedSeconds,
    required this.onTap,
    required this.onRetake,
  });
  final bool recording;
  final Duration elapsed;
  final bool hasRecording;
  final int recordedSeconds;
  final VoidCallback onTap;
  final VoidCallback? onRetake;
  @override
  Widget build(BuildContext context) {
    final mm = elapsed.inMinutes.toString().padLeft(1, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final recordedMm = (recordedSeconds ~/ 60).toString().padLeft(1, '0');
    final recordedSs = (recordedSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: recording
                    ? const Color(0xFFD93D5C)
                    : VentlyColors.berryMagenta,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: VentlyColors.berryMagenta.withOpacity(0.32),
                    blurRadius: recording ? 22 : 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(
                recording ? Icons.stop_rounded : Icons.mic_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  recording
                      ? 'Recording…  $mm:$ss'
                      : hasRecording
                          ? 'Captured  $recordedMm:$recordedSs'
                          : 'Tap to record',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  recording
                      ? 'Up to 3 minutes — auto-stops at the limit.'
                      : hasRecording
                          ? 'Preview below, then tap Publish to review.'
                          : 'Share a thought in your own voice.',
                  style: TextStyle(
                    color: context.ink.withOpacity(0.62),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (onRetake != null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  color: VentlyColors.berryMagenta),
              onPressed: onRetake,
              tooltip: 'Retake',
            ),
        ],
      ),
    );
  }
}

class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({required this.active, required this.onPick});
  final String active;
  final ValueChanged<String> onPick;
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in FeedCategories.all)
          InkWell(
            onTap: () => onPick(c),
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: c == active ? VentlyColors.berryMagenta : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: c == active
                    ? null
                    : Border.all(
                        color: VentlyColors.softMauve.withOpacity(0.4)),
              ),
              child: Text(
                FeedCategories.label(c),
                style: TextStyle(
                  color: c == active
                      ? Colors.white
                      : context.ink.withOpacity(0.78),
                  fontWeight: FontWeight.w900,
                  fontSize: 11.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _VoiceFilterPicker extends StatelessWidget {
  const _VoiceFilterPicker({required this.active, required this.onPick});
  final String active;
  final ValueChanged<String> onPick;
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final f in WhisperVoiceFilters.all)
          InkWell(
            onTap: () => onPick(f),
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: f == active
                    ? VentlyColors.berryMagenta
                    : const Color(0xFFFFE3EC),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq_rounded,
                      color: f == active
                          ? Colors.white
                          : VentlyColors.berryMagenta,
                      size: 13),
                  const SizedBox(width: 4),
                  Text(
                    WhisperVoiceFilters.label(f),
                    style: TextStyle(
                      color: f == active
                          ? Colors.white
                          : VentlyColors.berryMagenta,
                      fontWeight: FontWeight.w900,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
