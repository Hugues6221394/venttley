import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/tribe/tribe_chat_poll.dart';
import '../../theme/colors.dart';
import '../glass_surfaces.dart';

enum TribeChatCardKind { poll, question }

/// In-chat composer for polls and keeper questions (no Compose redirect).
Future<void> showTribeChatCardSheet(
  BuildContext context,
  WidgetRef ref, {
  required String tribeId,
  required TribeChatCardKind kind,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _TribeChatCardSheet(tribeId: tribeId, kind: kind),
  );
}

class _TribeChatCardSheet extends ConsumerStatefulWidget {
  const _TribeChatCardSheet({required this.tribeId, required this.kind});
  final String tribeId;
  final TribeChatCardKind kind;

  @override
  ConsumerState<_TribeChatCardSheet> createState() =>
      _TribeChatCardSheetState();
}

class _TribeChatCardSheetState extends ConsumerState<_TribeChatCardSheet> {
  final _primary = TextEditingController();
  final _options = List.generate(4, (_) => TextEditingController());
  bool _busy = false;
  bool _anonymousVotes = false;

  @override
  void dispose() {
    _primary.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isPoll => widget.kind == TribeChatCardKind.poll;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _submit() async {
    final prompt = _primary.text.trim();
    if (prompt.isEmpty) {
      _toast(_isPoll ? 'Add a poll question.' : 'Write your question first.');
      return;
    }

    Map<String, dynamic> metadata;
    if (_isPoll) {
      final texts = _options
          .map((c) => c.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (texts.length < 2) {
        _toast('A poll needs at least two options.');
        return;
      }
      metadata = TribeChatPoll.metadataFor(
        question: prompt,
        anonymousVotes: _anonymousVotes,
        options: [
          for (final t in texts)
            TribeChatPollOption(id: const Uuid().v4(), text: t),
        ],
      );
    } else {
      metadata = TribeChatQuestion.metadataFor(prompt);
    }

    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).sendTribeMessage(
            tribeId: widget.tribeId,
            metadata: metadata,
          );
      ref.invalidate(tribeMessagesProvider(widget.tribeId));
      VentlyHaptics.light();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      // Surface the failure instead of silently doing nothing.
      if (mounted) setState(() => _busy = false);
      _toast(_isPoll
          ? 'Couldn\'t post the poll: ${_friendly(e)}'
          : 'Couldn\'t post the question: ${_friendly(e)}');
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('not a tribe member')) return 'You\'re not a member here.';
    if (s.contains('needs a prompt')) return 'Write your question first.';
    if (s.contains('needs a question')) return 'Add a poll question.';
    if (s.contains('at least 2 options')) return 'Add at least two options.';
    return 'please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: GlassSheet(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    _isPoll ? Icons.poll_outlined : Icons.help_outline_rounded,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isPoll ? 'Post a poll' : 'Ask the tribe',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _primary,
                maxLength: _isPoll ? 120 : 200,
                maxLines: _isPoll ? 2 : 3,
                decoration: InputDecoration(
                  labelText: _isPoll ? 'Poll question' : 'Your question',
                  hintText: _isPoll
                      ? 'e.g. Morning check-in — how are we feeling?'
                      : 'e.g. What helped you most this week?',
                ),
              ),
              if (_isPoll) ...[
                const SizedBox(height: 8),
                for (var i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: TextField(
                      controller: _options[i],
                      maxLength: 60,
                      decoration: InputDecoration(
                        labelText: i < 2 ? 'Option ${i + 1} *' : 'Option ${i + 1}',
                      ),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Anonymous votes',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: const Text('Hide who voted — counts only'),
                  value: _anonymousVotes,
                  onChanged: (v) => setState(() => _anonymousVotes = v),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(_isPoll ? 'Post poll to chat' : 'Post question'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
