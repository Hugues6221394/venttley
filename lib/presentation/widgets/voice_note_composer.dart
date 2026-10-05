import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/services/whisper_voice_processor.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';

/// What came back from the composer: the audio to send, and nothing about how
/// it was made.
class ComposedVoiceNote {
  const ComposedVoiceNote({required this.bytes, required this.seconds});

  final Uint8List bytes;
  final int seconds;
}

/// Listen to a voice note, change the voice, then send it.
///
/// Why a chat needs this at all, when whispers already had it: a voice note is
/// the one thing somebody sends here that cannot be pseudonymous. A handle can
/// be anything, a face can be drawn — and then thirty seconds of audio hands
/// over gender, age, accent and region, to somebody they may have met an hour
/// ago in a space built for saying hard things. Either they do not send it, or
/// they send it and have given up more than they meant to.
///
/// The filter is applied here, on the device, before a single byte is
/// uploaded. The recording that leaves is the disguised one; the original
/// never exists anywhere but in memory, for as long as this sheet is open.
/// That is the difference between a disguise and a label — a flag on a message
/// row saying "play this one deeper" would ship the real voice and ask the
/// other end nicely.
///
/// Nothing records which filter was used, either. The sender's own handwriting
/// is not the recipient's business, and "this one is disguised" narrows a
/// guess all on its own.
Future<ComposedVoiceNote?> showVoiceNoteComposer(
  BuildContext context, {
  required Uint8List recorded,
  required int seconds,
}) {
  return showModalBottomSheet<ComposedVoiceNote>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _VoiceNoteComposer(recorded: recorded, seconds: seconds),
  );
}

class _VoiceNoteComposer extends StatefulWidget {
  const _VoiceNoteComposer({required this.recorded, required this.seconds});

  final Uint8List recorded;
  final int seconds;

  @override
  State<_VoiceNoteComposer> createState() => _VoiceNoteComposerState();
}

class _VoiceNoteComposerState extends State<_VoiceNoteComposer> {
  final _player = AudioPlayer();

  /// Rendered audio per filter. Processing a ten-second clip is not instant,
  /// and somebody comparing Deep against Robot against Deep again should pay
  /// for each one once.
  final _rendered = <String, Uint8List>{};
  final _tempFiles = <File>[];

  String _filter = 'none';
  bool _working = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rendered['none'] = widget.recorded;
  }

  @override
  void dispose() {
    _player.dispose();
    for (final file in _tempFiles) {
      file.delete().ignore();
    }
    super.dispose();
  }

  Future<Uint8List?> _render(String filter) async {
    final cached = _rendered[filter];
    if (cached != null) return cached;
    try {
      final bytes = await WhisperVoiceProcessor.instance.process(
        sourceBytes: widget.recorded,
        filter: filter,
      );
      _rendered[filter] = bytes;
      return bytes;
    } catch (_) {
      // One filter failing is not a reason to lose the recording. Say so, and
      // leave them on whatever was working.
      if (mounted) {
        setState(() => _error = 'That voice could not be applied. Try another.');
      }
      return null;
    }
  }

  Future<void> _preview(String filter) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
      _filter = filter;
    });
    try {
      await _player.stop();
      final bytes = await _render(filter);
      if (bytes == null || !mounted) return;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/vn-preview-$filter-${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      await file.writeAsBytes(bytes, flush: true);
      _tempFiles.add(file);
      await _player.setFilePath(file.path);
      await _player.play();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final bytes = await _render(_filter);
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _sending = false);
      return;
    }
    await _player.stop();
    if (!mounted) return;
    Navigator.pop(
      context,
      ComposedVoiceNote(bytes: bytes, seconds: widget.seconds),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: context.ink.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.graphic_eq_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Voice note · ${widget.seconds}s',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Change how you sound before you send it. Whoever gets this only '
              'ever hears the version you pick.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: context.ink.withValues(alpha: 0.62),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final filter in WhisperVoiceFilters.all)
                  ChoiceChip(
                    key: ValueKey('vn-filter-$filter'),
                    selected: _filter == filter,
                    onSelected: _working || _sending
                        ? null
                        : (_) => _preview(filter),
                    label: Text(WhisperVoiceFilters.label(filter)),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                      color: _filter == filter ? Colors.white : context.ink,
                    ),
                    selectedColor: VentlyColors.berryMagenta,
                    backgroundColor: scheme.primary.withValues(alpha: 0.06),
                    showCheckmark: false,
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12.5, color: Colors.redAccent),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('vn-preview'),
                    onPressed: _working || _sending
                        ? null
                        : () => _preview(_filter),
                    icon: _working
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 20),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                    label: Text(_working ? 'Applying…' : 'Listen'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('vn-send'),
                    onPressed: _working || _sending ? null : _send,
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text(_sending ? 'Sending…' : 'Send'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
