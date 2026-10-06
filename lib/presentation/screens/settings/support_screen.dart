import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/support/support_conversation.dart';
import '../../theme/colors.dart';

/// Conversations with the Venttly team.
///
/// A member reaches this from Settings, or by tapping a message from the team.
/// The team always appears as "Venttly team"; the database never sends a staff
/// name, and this screen must not invent one.
class SupportScreen extends ConsumerWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(supportConversationsProvider);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: _bar(context, 'Contact Venttly'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/settings/support/new'),
        backgroundColor: VentlyColors.berryMagenta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.edit_rounded),
        label: const Text(
          'New message',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: RefreshIndicator(
        color: VentlyColors.berryMagenta,
        onRefresh: () async {
          ref.invalidate(supportConversationsProvider);
          await ref.read(supportConversationsProvider.future);
        },
        child: async.when(
          loading: () => const _Loading(),
          error: (_, __) => const _Message(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load your conversations',
            body: 'Check your connection and pull down to try again.',
          ),
          data: (items) {
            if (items.isEmpty) {
              return const _Message(
                icon: Icons.forum_rounded,
                title: 'Talk to the Venttly team',
                body:
                    'Questions about your account, something not working, or '
                    'a safety worry: write to us and a real person will answer '
                    'here. You will get a notification when they do.',
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _ConversationTile(item: items[i]),
            );
          },
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.item});
  final SupportConversationSummary item;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ref = item.conversationId != null
        ? SupportThreadRef(conversationId: item.conversationId)
        : SupportThreadRef(communicationId: item.communicationId);
    return Material(
      color: dark ? Colors.white10 : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push(ref.route),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: item.unread
                  ? VentlyColors.berryMagenta.withOpacity(0.5)
                  : (dark ? Colors.white12 : VentlyColors.softMauve),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (item.unread) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: VentlyColors.berryMagenta,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      item.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: item.unread
                            ? FontWeight.w900
                            : FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _shortDate(item.lastMessageAt),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: dark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${item.lastFromTeam ? 'Venttly team' : 'You'}: ${item.preview}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: dark ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(height: 10),
              _StatusChip(status: item.status),
            ],
          ),
        ),
      ),
    );
  }
}

/// One conversation, with a reply bar while replies are open.
class SupportThreadScreen extends ConsumerStatefulWidget {
  const SupportThreadScreen({super.key, required this.thread});
  final SupportThreadRef thread;

  @override
  ConsumerState<SupportThreadScreen> createState() =>
      _SupportThreadScreenState();
}

class _SupportThreadScreenState extends ConsumerState<SupportThreadScreen> {
  final _controller = TextEditingController();
  late SupportThreadRef _thread = widget.thread;
  // Stable until a send is confirmed, so a retry is the same message.
  String _operation = const Uuid().v4();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    VentlyHaptics.send();
    try {
      final conversation = await ref
          .read(repositoryProvider)
          .replySupport(operationId: _operation, ref: _thread, body: body);
      _controller.clear();
      _operation = const Uuid().v4();
      // The first answer to a staff message creates the conversation; from
      // here on this screen follows it.
      final next = SupportThreadRef(conversationId: conversation);
      if (next != _thread) setState(() => _thread = next);
      ref.invalidate(supportThreadProvider(_thread));
      ref.invalidate(supportConversationsProvider);
    } catch (error) {
      // Inline rather than a snackbar: a snackbar would cover Send.
      if (mounted) setState(() => _error = supportErrorMessage(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(supportThreadProvider(_thread));
    // Opening the thread marked replies read; the list should say so too.
    ref.listen(supportThreadProvider(_thread), (_, next) {
      if (next.hasValue) ref.invalidate(supportConversationsProvider);
    });
    final title = async.valueOrNull?.subject ?? 'Conversation';
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: _bar(context, title),
      body: async.when(
        loading: () => const _Loading(),
        error: (_, __) => const _Message(
          icon: Icons.cloud_off_rounded,
          title: 'Could not open this conversation',
          body: 'Check your connection and try again.',
        ),
        data: (thread) => Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: () async {
                  ref.invalidate(supportThreadProvider(_thread));
                  await ref.read(supportThreadProvider(_thread).future);
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: [
                    Center(child: _StatusChip(status: thread.status)),
                    const SizedBox(height: 12),
                    for (final m in thread.messages) _Bubble(message: m),
                  ],
                ),
              ),
            ),
            if (thread.canReply)
              _Composer(
                controller: _controller,
                sending: _sending,
                error: _error,
                onSend: _send,
              )
            else
              const _Closed(),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final SupportMessage message;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mine = message.fromMe;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: mine
                ? VentlyColors.berryMagenta
                : (dark ? Colors.white10 : Colors.white),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
            border: mine
                ? null
                : Border.all(
                    color: dark ? Colors.white12 : VentlyColors.softMauve,
                  ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Venttly team',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: VentlyColors.berryMagenta,
                    ),
                  ),
                ),
              SelectableText(
                message.body,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: mine
                      ? Colors.white
                      : (dark ? Colors.white : VentlyColors.deepBurgundy),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _shortDate(message.createdAt, withTime: true),
                style: TextStyle(
                  fontSize: 10,
                  color: mine
                      ? Colors.white70
                      : (dark ? Colors.white54 : Colors.black38),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.error,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final String? error;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 5,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Write a reply',
              counterText: '',
              filled: true,
              fillColor: dark ? Colors.white10 : const Color(0xFFFBF7F9),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, value, __) => IconButton.filled(
            tooltip: 'Send',
            onPressed: sending || value.text.trim().isEmpty ? null : onSend,
            style: IconButton.styleFrom(
              backgroundColor: VentlyColors.berryMagenta,
            ),
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded, color: Colors.white),
          ),
        ),
      ],
    );
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(
              color: dark ? Colors.white12 : VentlyColors.softMauve,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  error!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            row,
          ],
        ),
      ),
    );
  }
}

class _Closed extends StatelessWidget {
  const _Closed();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This conversation is closed. If you still need help, start a '
              'new one.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: dark ? Colors.white70 : Colors.black54,
              ),
            ),
            TextButton(
              onPressed: () => context.push('/settings/support/new'),
              child: const Text(
                'New message',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: VentlyColors.berryMagenta,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Start a conversation: a topic, a subject and the message.
class NewSupportScreen extends ConsumerStatefulWidget {
  const NewSupportScreen({super.key});

  @override
  ConsumerState<NewSupportScreen> createState() => _NewSupportScreenState();
}

class _NewSupportScreenState extends ConsumerState<NewSupportScreen> {
  final _subject = TextEditingController();
  final _body = TextEditingController();
  SupportCategory? _category;
  final String _operation = const Uuid().v4();
  bool _sending = false;

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _ready =>
      _category != null &&
      _subject.text.trim().length >= 3 &&
      _body.text.trim().isNotEmpty;

  Future<void> _send() async {
    if (!_ready || _sending) return;
    setState(() => _sending = true);
    VentlyHaptics.send();
    try {
      final conversation = await ref
          .read(repositoryProvider)
          .startSupportConversation(
            operationId: _operation,
            category: _category!,
            subject: _subject.text.trim(),
            body: _body.text.trim(),
          );
      ref.invalidate(supportConversationsProvider);
      if (!mounted) return;
      context.pushReplacement(
        SupportThreadRef(conversationId: conversation).route,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(supportErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? Colors.white10 : const Color(0xFFFBF7F9);
    InputDecoration field(String hint) => InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: fill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: _bar(context, 'New message'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            'A real person on the Venttly team reads every message. If you are '
            'in danger right now, contact your local emergency services first.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: dark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: 18),
          const _Label('What is it about?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in SupportCategory.values)
                ChoiceChip(
                  label: Text(c.label),
                  selected: _category == c,
                  onSelected: _sending
                      ? null
                      : (_) => setState(() => _category = c),
                  selectedColor: VentlyColors.roseTint,
                  labelStyle: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _category == c ? VentlyColors.roseDeep : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          const _Label('Subject'),
          TextField(
            controller: _subject,
            maxLength: 80,
            enabled: !_sending,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: field('A few words, like “I can’t change my handle”'),
          ),
          const SizedBox(height: 6),
          const _Label('Message'),
          TextField(
            controller: _body,
            minLines: 5,
            maxLines: 10,
            maxLength: 2000,
            enabled: !_sending,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: field('Tell us what happened and what you need.'),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _ready && !_sending ? _send : null,
              style: FilledButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              child: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Send to Venttly',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The database names the rule that stopped a send; say it as a sentence.
String supportErrorMessage(Object error) {
  final raw = error.toString();
  if (raw.contains('too_many_open')) {
    return 'You already have three open conversations. Reply in one of them, '
        'or wait for the team to resolve one.';
  }
  if (raw.contains('rate_limited')) {
    return 'You have sent a lot of messages in a short time. Please wait a '
        'little and try again.';
  }
  if (raw.contains('conversation_closed')) {
    return 'This conversation is closed. Start a new one if you still need '
        'help.';
  }
  if (raw.contains('subject must be')) {
    return 'The subject needs 3 to 80 characters.';
  }
  if (raw.contains('message must be')) {
    return 'Your message needs between 1 and 2000 characters.';
  }
  if (raw.contains('connection')) return 'You need a connection to send this.';
  return 'Your message could not be sent. Check your connection and try '
      'again; it will not be sent twice.';
}

AppBar _bar(BuildContext context, String title) => AppBar(
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  leading: Navigator.of(context).canPop()
      ? IconButton(
          tooltip: 'Back',
          onPressed: context.pop,
          icon: const Icon(Icons.arrow_back_rounded),
        )
      : null,
  titleSpacing: Navigator.of(context).canPop() ? 0 : 20,
  title: Text(
    title,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
  ),
);

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.only(top: 80),
      child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 90, 32, 40),
      children: [
        Icon(icon, size: 42, color: VentlyColors.berryMagenta.withOpacity(0.7)),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: dark ? Colors.white70 : Colors.black54,
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final SupportStatus status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      SupportStatus.replied => (VentlyColors.roseTint, VentlyColors.roseDeep),
      SupportStatus.open => (const Color(0xFFFFF3E0), const Color(0xFF8A5300)),
      SupportStatus.resolved => (
        const Color(0xFFE8F6EC),
        const Color(0xFF1B6B33),
      ),
      SupportStatus.closed => (
        const Color(0xFFF1F1F3),
        const Color(0xFF55555E),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: fg),
      ),
    );
  }
}

String _shortDate(DateTime? d, {bool withTime = false}) {
  if (d == null) return '';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = '${d.day} ${months[d.month - 1]}';
  if (!withTime) return date;
  final minute = d.minute.toString().padLeft(2, '0');
  return '$date, ${d.hour}:$minute';
}
