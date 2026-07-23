import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';

/// Creates or schedules a Tribe prompt through the canonical repository RPC.
Future<bool> showKeeperPromptComposer(
  BuildContext context, {
  required String tribeId,
  bool scheduleRequired = false,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _KeeperPromptComposerSheet(
      tribeId: tribeId,
      scheduleRequired: scheduleRequired,
    ),
  );
  return result == true;
}

class _KeeperPromptComposerSheet extends ConsumerStatefulWidget {
  const _KeeperPromptComposerSheet({
    required this.tribeId,
    required this.scheduleRequired,
  });

  final String tribeId;
  final bool scheduleRequired;

  @override
  ConsumerState<_KeeperPromptComposerSheet> createState() =>
      _KeeperPromptComposerSheetState();
}

class _KeeperPromptComposerSheetState
    extends ConsumerState<_KeeperPromptComposerSheet> {
  final _text = TextEditingController();
  DateTime? _scheduledFor;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.scheduleRequired) {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      _scheduledFor = DateTime(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        9,
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final initial = _scheduledFor ?? now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 180)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!value.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a future publishing time.')),
      );
      return;
    }
    setState(() => _scheduledFor = value);
  }

  Future<void> _submit() async {
    final prompt = _text.text.trim();
    if (prompt.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write at least 4 characters.')),
      );
      return;
    }
    if (widget.scheduleRequired && _scheduledFor == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose when the prompt should publish.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).schedulePrompt(
            tribeId: widget.tribeId,
            text: prompt,
            scheduledFor: _scheduledFor,
          );
      ref.invalidate(tribePromptsProvider(widget.tribeId));
      ref.invalidate(keeperEngagementCalendarProvider(widget.tribeId));
      ref.invalidate(keeperOverviewProvider);
      ref.invalidate(tribeManagementProvider(widget.tribeId));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not publish this prompt: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final scheduledLabel = _scheduledFor == null
        ? 'Choose a publishing time'
        : DateFormat('MMM d, y - HH:mm').format(_scheduledFor!);
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .84,
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + bottom),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(.16),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              widget.scheduleRequired ? 'Schedule prompt' : 'New prompt',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            Text(
              widget.scheduleRequired
                  ? 'It will publish automatically at the selected time.'
                  : 'Post now or choose a time for later.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(.62),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              autofocus: true,
              maxLength: 240,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                hintText: 'What should members reflect on today?',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickSchedule,
              icon: const Icon(Icons.schedule_rounded),
              label: Text(scheduledLabel),
            ),
            if (!widget.scheduleRequired && _scheduledFor != null)
              TextButton(
                onPressed:
                    _busy ? null : () => setState(() => _scheduledFor = null),
                child: const Text('Post immediately instead'),
              ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _scheduledFor == null
                          ? Icons.send_rounded
                          : Icons.schedule_send_rounded,
                    ),
              label: Text(
                _scheduledFor == null ? 'Post prompt' : 'Schedule prompt',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
