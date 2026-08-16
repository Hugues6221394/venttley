import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/services/whisper_recorder.dart';
import '../../../data/services/whisper_voice_processor.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/whisper_audio_preview.dart';
import '../../widgets/music_track_card.dart';
import '../../widgets/whisper_preview_sheet.dart';

/// Create Whisper — record audio + tag category + pick background +
/// choose voice filter + publish.
///
/// Voice effects are rendered locally before preview and upload so the raw
/// recording stays on-device.
class CreateWhisperScreen extends ConsumerStatefulWidget {
  const CreateWhisperScreen({super.key});
  @override
  ConsumerState<CreateWhisperScreen> createState() =>
      _CreateWhisperScreenState();
}

class _CreateWhisperScreenState extends ConsumerState<CreateWhisperScreen> {
  static const _maximumDuration = Duration(minutes: 10);
  final String _publishMutationId = const Uuid().v4();

  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _recording = false;
  bool _paused = false;
  bool _busy = false;
  bool _processingVoice = false;
  bool _autoStopping = false;
  int _voiceProcessingGeneration = 0;

  // Capture results
  Uint8List? _originalRecordedBytes;
  Uint8List? _previewBytes;
  int _recordedSeconds = 0;

  // Composition
  String _category = 'confessions';
  String _voiceFilter = 'none';

  /// Optional music bed. Not mixed into the recording — stored as a reference
  /// and streamed under the voice at playback.
  MusicTrack? _musicBed;

  /// Deliberately low, and capped low. `WhisperPlayerController.maxBedVolume`
  /// and a database CHECK both hold the same 0.35 ceiling; this slider simply
  /// cannot ask for more. A whisper is someone's voice — the bed is allowed to
  /// colour it, never to compete with it.
  double _musicVolume = 0.18;
  static const double _musicVolumeMin = 0.05;
  static const double _musicVolumeMax = 0.35;
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
      await _finishRecording();
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
      _paused = false;
      _elapsed = Duration.zero;
      _originalRecordedBytes = null;
      _previewBytes = null;
      _recordedSeconds = 0;
      _voiceFilter = 'none';
      _processingVoice = false;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final elapsed = WhisperRecorder.instance.elapsed;
      setState(() {
        _elapsed = elapsed;
      });
      if (elapsed >= _maximumDuration && !_autoStopping) {
        _autoStopping = true;
        unawaited(_finishRecording());
      }
    });
  }

  Future<void> _finishRecording() async {
    final result = await WhisperRecorder.instance.stop();
    _ticker?.cancel();
    _autoStopping = false;
    if (!mounted) return;
    if (result != null) {
      final seconds = result.duration.inSeconds.clamp(
        0,
        _maximumDuration.inSeconds,
      );
      setState(() {
        _recording = false;
        _paused = false;
        _originalRecordedBytes = result.bytes;
        _previewBytes = result.bytes;
        _recordedSeconds = seconds;
        _elapsed = result.duration;
      });
    } else {
      setState(() {
        _recording = false;
        _paused = false;
        _elapsed = Duration.zero;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio captured. Try again.')),
      );
    }
  }

  Future<void> _togglePause() async {
    if (!_recording) return;
    final changed = _paused
        ? await WhisperRecorder.instance.resume()
        : await WhisperRecorder.instance.pause();
    if (!mounted) return;
    if (!changed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _paused
                ? 'Could not resume recording.'
                : 'Could not pause recording.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _paused = !_paused;
      _elapsed = WhisperRecorder.instance.elapsed;
    });
  }

  Future<void> _selectVoiceFilter(String filter) async {
    if (_voiceFilter == filter && !_processingVoice) return;
    final original = _originalRecordedBytes;
    final generation = ++_voiceProcessingGeneration;
    setState(() {
      _voiceFilter = filter;
      _processingVoice = original != null && filter != 'none';
      if (filter == 'none') _previewBytes = original;
    });
    if (original == null || filter == 'none') return;

    try {
      final processed = await WhisperVoiceProcessor.instance.process(
        sourceBytes: original,
        filter: filter,
      );
      if (!mounted || generation != _voiceProcessingGeneration) return;
      setState(() {
        _previewBytes = processed;
        _processingVoice = false;
      });
    } catch (error) {
      if (!mounted || generation != _voiceProcessingGeneration) return;
      setState(() {
        _voiceFilter = 'none';
        _previewBytes = original;
        _processingVoice = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That voice effect could not be prepared. Your original is safe.',
          ),
        ),
      );
    }
  }

  void _retake() {
    _voiceProcessingGeneration++;
    setState(() {
      _originalRecordedBytes = null;
      _previewBytes = null;
      _recordedSeconds = 0;
      _elapsed = Duration.zero;
      _voiceFilter = 'none';
      _processingVoice = false;
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
    final audioBytes = _previewBytes;
    if (audioBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Record your whisper first.')),
      );
      return;
    }
    if (_processingVoice) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Finishing your voice effect…')),
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
      audioBytes: audioBytes,
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
        bytes: _previewBytes!,
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
        idempotencyKey: _publishMutationId,
      );
      // After the whisper exists, not as part of creating it:
      // create_whisper_idempotent is a hardened trust-boundary RPC and adding
      // an optional field to it is not worth the risk. A failure here loses the
      // bed, not the whisper — so it is caught separately and reported without
      // failing the publish.
      final bed = _musicBed;
      if (bed != null) {
        try {
          await repo.setWhisperMusic(
            whisperId: whisperId,
            trackId: bed.trackId,
            volume: _musicVolume,
          );
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Whisper published, but the background music could not be '
                  'attached.',
                ),
              ),
            );
          }
        }
      }
      ref.invalidate(whispersFeedProvider);
      ref.invalidate(myWhispersProvider);
      ref.invalidate(popularWhispersProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Whisper published.')));
      context.go('/whispers?whisper=$whisperId');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(
              e,
              fallback: 'Could not publish whisper.',
            ),
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
        title: const Text(
          'Record a Whisper',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
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
                  paused: _paused,
                  elapsed: _elapsed,
                  hasRecording: _previewBytes != null,
                  recordedSeconds: _recordedSeconds,
                  onTap: _toggleRecord,
                  onPauseResume: _recording ? _togglePause : null,
                  onRetake: _previewBytes == null ? null : _retake,
                ),
                if (_previewBytes != null) ...[
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _processingVoice
                        ? const _VoiceProcessingCard()
                        : WhisperAudioPreview(
                            key: ValueKey(_voiceFilter),
                            bytes: _previewBytes!,
                            durationSeconds: _recordedSeconds,
                          ),
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
                  enabled: !_recording && !_processingVoice,
                  onPick: _selectVoiceFilter,
                ),
                if (flagEnabled(ref, 'vent_music', fallback: false)) ...[
                  const SizedBox(height: 18),
                  const _SectionLabel(label: 'Background music (optional)'),
                  const SizedBox(height: 8),
                  _MusicBedPicker(
                    track: _musicBed,
                    volume: _musicVolume,
                    minVolume: _musicVolumeMin,
                    maxVolume: _musicVolumeMax,
                    enabled: !_recording && !_processingVoice && !_busy,
                    onPick: () async {
                      final picked = await showMusicPicker(
                        context,
                        selected: _musicBed,
                      );
                      if (!mounted || picked == null) return;
                      setState(() => _musicBed = picked);
                    },
                    onRemove: () => setState(() => _musicBed = null),
                    onVolume: (v) => setState(() => _musicVolume = v),
                  ),
                ],
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
                    hintStyle: TextStyle(color: context.ink.withOpacity(0.42)),
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
                    hintStyle: TextStyle(color: context.ink.withOpacity(0.42)),
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
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
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
    required this.paused,
    required this.elapsed,
    required this.hasRecording,
    required this.recordedSeconds,
    required this.onTap,
    required this.onPauseResume,
    required this.onRetake,
  });
  final bool recording;
  final bool paused;
  final Duration elapsed;
  final bool hasRecording;
  final int recordedSeconds;
  final VoidCallback onTap;
  final VoidCallback? onPauseResume;
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
                      ? paused
                            ? 'Paused  $mm:$ss'
                            : 'Recording…  $mm:$ss'
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
                      ? paused
                            ? 'Take your time. Resume when you are ready.'
                            : 'Up to 10 minutes — pause whenever you need.'
                      : hasRecording
                      ? 'Try a voice effect and listen before publishing.'
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
          if (onPauseResume != null)
            IconButton(
              icon: Icon(
                paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: VentlyColors.berryMagenta,
              ),
              onPressed: onPauseResume,
              tooltip: paused ? 'Resume recording' : 'Pause recording',
            ),
          if (onRetake != null)
            IconButton(
              icon: const Icon(
                Icons.refresh_rounded,
                color: VentlyColors.berryMagenta,
              ),
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
                        color: VentlyColors.softMauve.withOpacity(0.4),
                      ),
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
  const _VoiceFilterPicker({
    required this.active,
    required this.enabled,
    required this.onPick,
  });
  final String active;
  final bool enabled;
  final ValueChanged<String> onPick;
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final f in WhisperVoiceFilters.all)
          InkWell(
            onTap: enabled ? () => onPick(f) : null,
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: !enabled
                    ? VentlyColors.softMauve.withOpacity(0.2)
                    : f == active
                    ? VentlyColors.berryMagenta
                    : const Color(0xFFFFE3EC),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    color: !enabled
                        ? context.ink.withOpacity(0.28)
                        : f == active
                        ? Colors.white
                        : VentlyColors.berryMagenta,
                    size: 13,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    WhisperVoiceFilters.label(f),
                    style: TextStyle(
                      color: !enabled
                          ? context.ink.withOpacity(0.28)
                          : f == active
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

class _VoiceProcessingCard extends StatelessWidget {
  const _VoiceProcessingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('voice-processing'),
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Preparing a private on-device preview…',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pick a background bed and set how far under the voice it sits.
///
/// The slider's range is 5%–35%, not 0%–100%. That is the whole point of the
/// control: on a platform where the recording is often the hardest thing
/// someone has said out loud, a bed loud enough to compete with it is not a
/// preference worth offering. The ceiling is enforced three times — here, in
/// [WhisperPlayerController], and by a database CHECK — so no path can raise it.
class _MusicBedPicker extends StatelessWidget {
  const _MusicBedPicker({
    required this.track,
    required this.volume,
    required this.minVolume,
    required this.maxVolume,
    required this.enabled,
    required this.onPick,
    required this.onRemove,
    required this.onVolume,
  });

  final MusicTrack? track;
  final double volume;
  final double minVolume;
  final double maxVolume;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  final ValueChanged<double> onVolume;

  @override
  Widget build(BuildContext context) {
    final selected = track;
    if (selected == null) {
      return OutlinedButton.icon(
        onPressed: enabled ? onPick : null,
        icon: const Icon(Icons.library_music_outlined, size: 18),
        label: const Text(
          'Add background music',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          foregroundColor: VentlyColors.berryMagenta,
          side: BorderSide(
            color: VentlyColors.berryMagenta.withOpacity(0.35),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      );
    }

    // Percent of the *allowed* range, not of full volume — "60%" here would be
    // a lie about how loud the bed actually is.
    final pct = ((volume / maxVolume) * 100).round();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
      decoration: BoxDecoration(
        color: VentlyColors.berryMagenta.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: VentlyColors.berryMagenta.withOpacity(0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.music_note_rounded,
                size: 18,
                color: VentlyColors.berryMagenta,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                        color: context.ink,
                      ),
                    ),
                    Text(
                      selected.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 11.5,
                        color: context.ink.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: enabled ? onPick : null,
                child: const Text(
                  'Change',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Remove background music',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onRemove : null,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: context.ink.withOpacity(0.6),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Icon(
                Icons.volume_down_rounded,
                size: 17,
                color: context.ink.withOpacity(0.55),
              ),
              Expanded(
                child: Slider(
                  value: volume.clamp(minVolume, maxVolume),
                  min: minVolume,
                  max: maxVolume,
                  activeColor: VentlyColors.berryMagenta,
                  onChanged: enabled ? onVolume : null,
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '$pct%',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                    color: context.ink.withOpacity(0.7),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              'Kept quiet on purpose so your voice stays clear.',
              style: TextStyle(
                fontSize: 11,
                color: context.ink.withOpacity(0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
