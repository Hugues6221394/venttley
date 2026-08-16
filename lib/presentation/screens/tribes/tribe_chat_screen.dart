import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/connection.dart';
import '../../../core/providers.dart';
import '../../../data/services/draft_store.dart';
import '../../../data/services/outbox.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../../core/vently_haptics.dart';
import '../../widgets/glass_surfaces.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/verified_badge.dart';
import '../../widgets/tribe/keeper_control_strip.dart';
import '../../widgets/tribe/tribe_member_sheet.dart';
import '../../widgets/tribe/tribe_rules_sheet.dart';
import '../../widgets/tribe/tribe_message_actions.dart';
import '../../widgets/report_reason_sheet.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/crisis_support_sheet.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe/tribe_chat_poll_card.dart';
import '../../widgets/tribe/tribe_chat_poll_sheet.dart';
import '../../widgets/tribe/tribe_question_answers_sheet.dart';
import 'tribe_chat_hub_screen.dart' show showTribePromptComposer;
import '../../../domain/tribe/tribe_chat_poll.dart';
import '../../widgets/chat_audio_bubble.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';
import '../../../data/services/whisper_recorder.dart';

/// Tribe Group Chat — Image #16.
///
/// Realtime fan-out of `tribe_messages` for one tribe; bubbles for text,
/// audio (waveform card), and image. Composer with +, mic, image, emoji
/// and a magenta send. Persistent community-safety banner
/// per the v2 brief — see notes in README; transport is TLS, server-side
/// moderation review is honored).
class TribeChatScreen extends ConsumerStatefulWidget {
  const TribeChatScreen({
    super.key,
    required this.slug,
    this.scrollToMessageId,
  });
  final String slug;
  final String? scrollToMessageId;

  @override
  ConsumerState<TribeChatScreen> createState() => _TribeChatScreenState();
}

class _TribeChatScreenState extends ConsumerState<TribeChatScreen> {
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final _messageKeys = <String, GlobalKey>{};
  bool _sending = false;
  bool _searchOpen = false;
  Timer? _heartbeat;
  Timer? _typingDebounce;
  bool _recordingVoice = false;
  String? _heartbeatTribeId;
  TribeMessage? _replyTo;
  bool _deepLinkHandled = false;

  DraftSaver? _draftSaver;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    _search.addListener(() => setState(() {}));
    // Per-tribe draft: restore unfinished text, auto-save while typing.
    ref.read(draftStoreProvider.future).then((store) {
      if (!mounted) return;
      _draftSaver = DraftSaver(
        store: store,
        draftKey: 'tribechat.${widget.slug}',
        controller: _composer,
      );
      if (_draftSaver!.restore()) setState(() {});
    });
  }

  void _onComposerChanged() {
    final tribe = ref.read(tribeBySlugProvider(widget.slug)).valueOrNull;
    final me = ref.read(sessionProvider);
    if (tribe == null || me == null) return;
    if (_composer.text.trim().isEmpty) return;
    _typingDebounce?.cancel();
    ref
        .read(repositoryProvider)
        .broadcastTribeTyping(tribe.tribeId, pseudonym: me.anonymousPseudonym);
    _typingDebounce = Timer(const Duration(milliseconds: 1500), () {});
  }

  void _ensureHeartbeat(String tribeId) {
    if (_heartbeatTribeId == tribeId) return;
    _heartbeatTribeId = tribeId;
    _startHeartbeat(tribeId);
  }

  void _startHeartbeat(String tribeId) {
    _heartbeat?.cancel();
    ref.read(repositoryProvider).tribeChatHeartbeat(tribeId);
    ref.read(repositoryProvider).markTribeChatRead(tribeId);
    ref.invalidate(tribeChatInboxProvider);
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) {
      ref.read(repositoryProvider).tribeChatHeartbeat(tribeId);
      ref.invalidate(tribeChatPresenceProvider(tribeId));
    });
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _typingDebounce?.cancel();
    _draftSaver?.dispose();
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyForMessage(String messageId) =>
      _messageKeys.putIfAbsent(messageId, GlobalKey.new);

  List<TribeMessage> _filterMessages(List<TribeMessage> all, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((m) {
      if (m.isDeleted) return false;
      final content = m.content?.toLowerCase() ?? '';
      final sender = m.senderPseudonym.toLowerCase();
      return content.contains(q) || sender.contains(q);
    }).toList();
  }

  void _maybeScrollToDeepLink(List<TribeMessage> messages) {
    final id = widget.scrollToMessageId;
    if (id == null || _deepLinkHandled) return;
    if (!messages.any((m) => m.messageId == id)) return;
    _deepLinkHandled = true;
    _jumpToMessage(id);
  }

  void _openPollSheet(String tribeId) {
    showTribeChatCardSheet(
      context,
      ref,
      tribeId: tribeId,
      kind: TribeChatCardKind.poll,
    );
  }

  void _openQuestionSheet(String tribeId) {
    showTribeChatCardSheet(
      context,
      ref,
      tribeId: tribeId,
      kind: TribeChatCardKind.question,
    );
  }

  void _openQuestionAnswers(
    BuildContext context,
    WidgetRef ref,
    TribeMessage question,
    Tribe tribe,
  ) {
    showTribeQuestionAnswersSheet(
      context,
      ref,
      questionMessage: question,
      tribeId: tribe.tribeId,
      tribeSlug: tribe.slug,
      onReply: () => setState(() => _replyTo = question),
    );
  }

  void _jumpToMessage(String messageId) {
    setState(() {
      _searchOpen = false;
      _search.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _messageKeys[messageId]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    });
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _send(String tribeId) async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _composer.clear();
    final replyId = _replyTo?.messageId;
    final operationId = OutboxService.newOperationId();
    setState(() => _replyTo = null);
    String? sentId;
    try {
      await VentlyHaptics.send();
      sentId = await ref
          .read(repositoryProvider)
          .sendTribeMessage(
            tribeId: tribeId,
            content: text,
            replyToMessageId: replyId,
            idempotencyKey: operationId,
          );
      await _draftSaver?.clear();
      // Re-read after a successful write. watchTribeMessages emits once on
      // subscribe and then relies entirely on Supabase Realtime for updates, so
      // if the postgres_changes callback does not fire the thread never moves —
      // and the sender does not see their own message. Observed on device: two
      // messages persisted and neither appeared until the screen was left and
      // reopened, which reads as "send is broken" and makes people send again.
      // Edit and delete below already invalidate for the same reason; the three
      // send paths were the ones that did not.
      ref.invalidate(tribeMessagesProvider(tribeId));
      _scrollToBottomSoon();
    } catch (_) {
      if (!mounted) return;
      // Offline: queue for automatic retry instead of dropping the text.
      try {
        final outbox = await ref.read(outboxProvider.future);
        await outbox.enqueue(OutboxKind.tribeMessage, {
          'tribeId': tribeId,
          'content': text,
          'replyToMessageId': replyId,
        }, operationId: operationId);
        await _draftSaver?.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "You're offline — message queued, it will send automatically.",
            ),
          ),
        );
      } catch (queueError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not preserve message: $queueError. Your draft is still saved.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    // Safety scan on the sender's own message — offers crisis resources and
    // flags it for the Safety queue. Best-effort; runs after the send lands.
    final id = sentId;
    if (id != null && mounted) {
      await maybeSurfaceChatCrisis(
        ref: ref,
        context: context,
        text: text,
        tag: (level) =>
            ref.read(repositoryProvider).setTribeMessageCrisis(id, level),
      );
    }
  }

  /// Opens a message's whole reply thread — root + every descendant reply,
  /// with a composer that answers into the same topic. Lets members follow
  /// parallel conversations inside one chat hub.
  void _openTopicThread(TribeMessage root, Tribe tribe) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TopicThreadSheet(root: root, tribe: tribe),
    );
  }

  Future<void> _sendImage(String tribeId) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1600,
    );
    if (picked == null) return;
    setState(() => _sending = true);
    final operationId = OutboxService.newOperationId();
    final outbox = await ref.read(outboxProvider.future);
    StagedOutboxMedia? stagedMedia;
    String? imagePath;
    String? imageUrl;
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last
          : 'jpg';
      stagedMedia = await outbox.stageMedia(
        operationId: operationId,
        bytes: bytes,
        extension: ext,
        contentType: picked.mimeType ?? 'image/jpeg',
        mediaType: 'image',
      );
      final upload = await ref
          .read(repositoryProvider)
          .uploadTribeChatImage(
            bytes: bytes,
            extension: ext,
            contentType: picked.mimeType ?? 'image/jpeg',
          );
      imagePath = upload.path;
      imageUrl = upload.url;
      await ref
          .read(repositoryProvider)
          .sendTribeMessage(
            tribeId: tribeId,
            content: null,
            imagePath: upload.path,
            imageUrl: upload.url,
            idempotencyKey: operationId,
          );
      await outbox.discardStagedMedia(stagedMedia.path);
      // See _send: the stream does not re-emit on our own write.
      ref.invalidate(tribeMessagesProvider(tribeId));
      _scrollToBottomSoon();
    } catch (_) {
      if (stagedMedia != null) {
        await outbox.enqueue(OutboxKind.tribeMessage, {
          'tribeId': tribeId,
          'content': null,
          'imagePath': imagePath,
          'imageUrl': imageUrl,
          ...stagedMedia.toPayload(),
        }, operationId: operationId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            stagedMedia == null
                ? 'Could not preserve photo.'
                : 'Photo queued and will send automatically.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tribeAsync = ref.watch(tribeBySlugProvider(widget.slug));
    return tribeAsync.when(
      loading: () => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: const SafeArea(child: ChatSkeleton()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (tribe) {
        if (tribe == null) {
          return const Scaffold(body: Center(child: Text('Tribe not found')));
        }
        _ensureHeartbeat(tribe.tribeId);
        final messagesAsync = ref.watch(tribeMessagesProvider(tribe.tribeId));
        final presence =
            ref.watch(tribeChatPresenceProvider(tribe.tribeId)).valueOrNull ??
            tribe.memberCount;
        final typing =
            ref.watch(tribeTypingProvider(tribe.tribeId)).valueOrNull ??
            const [];
        final me = ref.watch(sessionProvider);
        final typingOthers = typing
            .where((t) => t.userId != me?.userId)
            .map((t) => t.pseudonym)
            .toList();
        final canManage = ref.watch(canManageTribeProvider(tribe.tribeId));
        final settings = tribe.chatSettings;
        TribeMessage? pinned;
        messagesAsync.valueOrNull?.forEach((m) {
          if (m.isPinned || m.messageId == tribe.pinnedMessageId) {
            pinned = m;
          }
        });

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: VentlyPremiumBackground(
            wallpaperUrl: settings.wallpaperUrl,
            wallpaperStyle: settings.wallpaperStyle,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _ChatHeader(
                    tribe: tribe,
                    soulsOnline: presence,
                    searchActive: _searchOpen,
                    onToggleSearch: () => setState(() {
                      _searchOpen = !_searchOpen;
                      if (!_searchOpen) _search.clear();
                    }),
                    onOpenHub: () =>
                        context.push('/tribe/${tribe.slug}/chat/hub'),
                    onOpenMembers: () => showTribeMemberSheet(
                      context,
                      tribeId: tribe.tribeId,
                      tribeSlug: tribe.slug,
                      tribeName: tribe.name,
                    ),
                  ),
                  const _PrivacyBanner(),
                  if (pinned != null)
                    PinnedMessageBanner(
                      message: pinned!,
                      onTap: () => _jumpToMessage(pinned!.messageId),
                      onUnpin: canManage
                          ? () async {
                              await ref
                                  .read(repositoryProvider)
                                  .unpinTribeMessage(tribe.tribeId);
                              ref.invalidate(
                                tribeMessagesProvider(tribe.tribeId),
                              );
                              ref.invalidate(tribeBySlugProvider(tribe.slug));
                            }
                          : null,
                    ),
                  KeeperControlStrip(
                    tribe: tribe,
                    onPinPrompt: () => showTribePromptComposer(
                      context,
                      tribeId: tribe.tribeId,
                    ),
                    onSlowModeToggle: () async {
                      final next = tribe.chatSettings.slowModeSeconds == 0
                          ? 30
                          : 0;
                      await ref
                          .read(repositoryProvider)
                          .setTribeChatSettings(
                            tribeId: tribe.tribeId,
                            patch: {'slow_mode_seconds': next},
                          );
                      ref.invalidate(tribeBySlugProvider(tribe.slug));
                    },
                  ),
                  if (_searchOpen)
                    _ChatSearchBar(
                      controller: _search,
                      onClose: () => setState(() {
                        _searchOpen = false;
                        _search.clear();
                      }),
                    ),
                  if (typingOthers.isNotEmpty) _TypingBar(names: typingOthers),
                  Expanded(
                    child: messagesAsync.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(child: Text('Error: $e')),
                      data: (messages) {
                        final query = _search.text;
                        if (_searchOpen && query.trim().isNotEmpty) {
                          final hits = _filterMessages(messages, query);
                          return _MessageSearchResults(
                            query: query,
                            hits: hits,
                            onTap: _jumpToMessage,
                          );
                        }
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!_scroll.hasClients || _searchOpen) return;
                          if ((_scroll.position.maxScrollExtent -
                                      _scroll.offset)
                                  .abs() <
                              200) {
                            _scrollToBottomSoon();
                          }
                        });
                        if (messages.isEmpty) {
                          return _ChatEmpty(tribe: tribe);
                        }
                        _maybeScrollToDeepLink(messages);
                        // Topic threads: messages that received replies
                        // become followable topics — the chip under a
                        // message opens its whole thread in one sheet.
                        final replyCounts = <String, int>{};
                        for (final m in messages) {
                          final r = m.replyToMessageId;
                          if (r != null) {
                            replyCounts[r] = (replyCounts[r] ?? 0) + 1;
                          }
                        }
                        return ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          itemCount: messages.length,
                          itemBuilder: (ctx, i) {
                            final msg = messages[i];
                            final prev = i == 0 ? null : messages[i - 1];
                            final showDateChip =
                                prev == null || _newDayBoundary(prev, msg);
                            final threadSize = replyCounts[msg.messageId] ?? 0;
                            return RepaintBoundary(
                              key: _keyForMessage(msg.messageId),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (showDateChip)
                                    _DateDivider(when: msg.createdAt),
                                  _MessageBubble(
                                    message: msg,
                                    tribeId: tribe.tribeId,
                                    tribeSlug: tribe.slug,
                                    canManage: canManage,
                                    onReply: (m) =>
                                        setState(() => _replyTo = m),
                                    onJumpTo: _jumpToMessage,
                                    onQuestionTap: (m) => _openQuestionAnswers(
                                      context,
                                      ref,
                                      m,
                                      tribe,
                                    ),
                                  ),
                                  if (threadSize > 0)
                                    _TopicThreadChip(
                                      count: threadSize,
                                      alignEnd: msg.sentByMe,
                                      onTap: () => _openTopicThread(msg, tribe),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  _Composer(
                    controller: _composer,
                    sending: _sending,
                    recording: _recordingVoice,
                    replyTo: _replyTo,
                    typingLabel: typingOthers.isEmpty
                        ? null
                        : (typingOthers.length == 1
                              ? '@${typingOthers.first} is typing…'
                              : '${typingOthers.length} people typing…'),
                    onClearReply: () => setState(() => _replyTo = null),
                    onSend: () => _send(tribe.tribeId),
                    onPickImage: () => _sendImage(tribe.tribeId),
                    onMicTap: () => _toggleVoice(tribe.tribeId),
                    onPoll: () => _openPollSheet(tribe.tribeId),
                    onQuestion: () => _openQuestionSheet(tribe.tribeId),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  bool _newDayBoundary(TribeMessage a, TribeMessage b) {
    return a.createdAt.year != b.createdAt.year ||
        a.createdAt.month != b.createdAt.month ||
        a.createdAt.day != b.createdAt.day;
  }

  Future<void> _toggleVoice(String tribeId) async {
    if (_recordingVoice) {
      setState(() => _recordingVoice = false);
      final result = await WhisperRecorder.instance.stop();
      if (result == null || result.bytes.isEmpty) return;
      if (result.duration.inSeconds < 1) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Recording too short')));
        }
        return;
      }
      setState(() => _sending = true);
      final durationSeconds = result.duration.inSeconds.clamp(1, 300);
      final operationId = OutboxService.newOperationId();
      final outbox = await ref.read(outboxProvider.future);
      StagedOutboxMedia? stagedMedia;
      String? audioPath;
      String? audioUrl;
      try {
        stagedMedia = await outbox.stageMedia(
          operationId: operationId,
          bytes: result.bytes,
          extension: 'm4a',
          contentType: 'audio/mp4',
          mediaType: 'audio',
          durationSeconds: durationSeconds,
        );
        final upload = await ref
            .read(repositoryProvider)
            .uploadTribeChatAudio(bytes: result.bytes);
        audioPath = upload.path;
        audioUrl = upload.url;
        await ref
            .read(repositoryProvider)
            .sendTribeMessage(
              tribeId: tribeId,
              audioPath: upload.path,
              audioUrl: upload.url,
              audioDurationSeconds: durationSeconds,
              idempotencyKey: operationId,
            );
        await outbox.discardStagedMedia(stagedMedia.path);
        // See _send: the stream does not re-emit on our own write.
        ref.invalidate(tribeMessagesProvider(tribeId));
        _scrollToBottomSoon();
      } catch (_) {
        if (stagedMedia != null) {
          await outbox.enqueue(OutboxKind.tribeMessage, {
            'tribeId': tribeId,
            'content': null,
            'audioPath': audioPath,
            'audioUrl': audioUrl,
            'audioDurationSeconds': durationSeconds,
            ...stagedMedia.toPayload(),
          }, operationId: operationId);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                stagedMedia == null
                    ? 'Could not preserve voice note.'
                    : 'Voice note queued and will send automatically.',
              ),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    final ok = await WhisperRecorder.instance.start();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission required')),
      );
      return;
    }
    await VentlyHaptics.recordStart();
    setState(() => _recordingVoice = true);
  }
}

// =========================================================================
// HEADER
// =========================================================================

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.tribe,
    required this.soulsOnline,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onOpenHub,
    required this.onOpenMembers,
  });
  final Tribe tribe;
  final int soulsOnline;
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback onOpenHub;
  final VoidCallback onOpenMembers;

  @override
  Widget build(BuildContext context) {
    return GlassHeader(
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.chevron_left_rounded,
              color: VentlyColors.berryMagenta,
            ),
            onPressed: () => context.pop(),
          ),
          GestureDetector(
            onTap: onOpenMembers,
            child: TribeAvatar(avatarUrl: tribe.avatarUrl, size: 40),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: onOpenHub,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tribe.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.ink,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: Color(0xFF21C76A),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${_compact(soulsOnline)} souls online · tap for info',
                            style: TextStyle(
                              color: context.ink.withOpacity(0.6),
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Tribe rules',
            icon: Icon(Icons.menu_book_outlined, color: context.ink),
            onPressed: () => showTribeRulesSheet(context, tribe),
          ),
          IconButton(
            icon: Icon(
              searchActive ? Icons.close_rounded : Icons.search_rounded,
              color: context.ink,
            ),
            onPressed: onToggleSearch,
          ),
          IconButton(
            icon: Icon(Icons.info_outline, color: context.ink),
            onPressed: onOpenHub,
          ),
        ],
      ),
    );
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

// =========================================================================
// IN-CHAT SEARCH
// =========================================================================

class _ChatSearchBar extends StatelessWidget {
  const _ChatSearchBar({required this.controller, required this.onClose});
  final TextEditingController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        borderRadius: 18,
        child: Row(
          children: [
            const SizedBox(width: 4),
            const Icon(
              Icons.search_rounded,
              color: VentlyColors.berryMagenta,
              size: 20,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search messages…',
                  border: InputBorder.none,
                  hintStyle: TextStyle(
                    color: context.ink.withOpacity(0.45),
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              color: context.ink,
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageSearchResults extends StatelessWidget {
  const _MessageSearchResults({
    required this.query,
    required this.hits,
    required this.onTap,
  });
  final String query;
  final List<TribeMessage> hits;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No messages match "$query"',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withOpacity(0.65),
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      itemCount: hits.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Text(
            '${hits.length} result${hits.length == 1 ? '' : 's'}',
            style: TextStyle(
              color: context.ink.withOpacity(0.55),
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          );
        }
        final msg = hits[i - 1];
        final preview = msg.content?.trim().isNotEmpty == true
            ? msg.content!.trim()
            : msg.hasAudio
            ? 'Voice note'
            : msg.hasImage
            ? 'Photo'
            : 'Message';
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => onTap(msg.messageId),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProfileAvatar(
                    avatarSeed: msg.senderAvatarSeed,
                    label: msg.senderPseudonym,
                    profilePhotoUrl: msg.senderProfilePhotoUrl,
                    size: 36,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                '@${msg.senderPseudonym}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: VentlyColors.berryMagenta,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            if (msg.senderIsVerified) ...[
                              const SizedBox(width: 3),
                              const VerifiedBadge(size: 12),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        _HighlightedText(text: preview, query: query),
                        const SizedBox(height: 4),
                        Text(
                          DateFormat('MMM d · h:mm a').format(msg.createdAt),
                          style: TextStyle(
                            color: context.ink.withOpacity(0.5),
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HighlightedText extends StatelessWidget {
  const _HighlightedText({required this.text, required this.query});
  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.ink,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          height: 1.35,
        ),
      );
    }
    final lower = text.toLowerCase();
    final idx = lower.indexOf(q);
    if (idx < 0) {
      return Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.ink,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          height: 1.35,
        ),
      );
    }
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(
          color: context.ink,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          height: 1.35,
        ),
        children: [
          if (idx > 0) TextSpan(text: text.substring(0, idx)),
          TextSpan(
            text: text.substring(idx, idx + q.length),
            style: const TextStyle(
              backgroundColor: Color(0xFFFFF3B0),
              fontWeight: FontWeight.w900,
            ),
          ),
          if (idx + q.length < text.length)
            TextSpan(text: text.substring(idx + q.length)),
        ],
      ),
    );
  }
}

// =========================================================================
// TYPING BAR
// =========================================================================

class _TypingBar extends StatelessWidget {
  const _TypingBar({required this.names});
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final label = names.length == 1
        ? '@${names.first} is typing…'
        : '${names.length} people are typing…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        children: [
          const _TypingDots(),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: VentlyColors.berryMagenta.withOpacity(0.85),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 12,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _ctl,
            builder: (_, __) {
              final t = (_ctl.value + i * 0.2) % 1.0;
              final scale = 0.5 + 0.5 * (t < 0.5 ? t * 2 : (1 - t) * 2);
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: VentlyColors.berryMagenta,
                    shape: BoxShape.circle,
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

// =========================================================================
// PRIVACY BANNER
// =========================================================================

class _PrivacyBanner extends StatelessWidget {
  const _PrivacyBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(40, 12, 40, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F5EA),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined, size: 14, color: Color(0xFF2E7D44)),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Community safety rules apply',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Color(0xFF2E7D44),
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// DATE DIVIDER
// =========================================================================

class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.when});
  final DateTime when;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    String label;
    if (now.year == when.year &&
        now.month == when.month &&
        now.day == when.day) {
      label = 'Today';
    } else if (now.difference(when).inDays == 1) {
      label = 'Yesterday';
    } else if (now.difference(when).inDays < 7) {
      label = DateFormat.EEEE().format(when);
    } else {
      label = DateFormat('MMM d').format(when);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: VentlyColors.softMauve.withOpacity(0.4),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 11.5,
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// MESSAGE BUBBLE
// =========================================================================

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    required this.message,
    required this.tribeId,
    required this.tribeSlug,
    required this.canManage,
    required this.onReply,
    required this.onJumpTo,
    required this.onQuestionTap,
  });
  final TribeMessage message;
  final String tribeId;
  final String tribeSlug;
  final bool canManage;
  final ValueChanged<TribeMessage> onReply;
  final ValueChanged<String> onJumpTo;
  final ValueChanged<TribeMessage> onQuestionTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = message.sentByMe;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    final col = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final timeStr = DateFormat('h:mm a').format(message.createdAt);
    if (message.isDeleted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: align,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: VentlyColors.softMauve.withOpacity(0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'Message removed',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: context.ink.withOpacity(0.55),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }
    final Widget body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: align,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          child: Column(
            crossAxisAlignment: col,
            children: [
              if (!mine)
                Padding(
                  padding: const EdgeInsets.fromLTRB(46, 0, 12, 4),
                  child: InkWell(
                    onTap: message.senderId == null
                        ? null
                        : () => context.push('/user/${message.senderId}'),
                    borderRadius: BorderRadius.circular(6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '@${message.senderPseudonym}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: VentlyColors.berryMagenta,
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (message.senderIsVerified) ...[
                          const SizedBox(width: 3),
                          const VerifiedBadge(size: 12),
                        ],
                      ],
                    ),
                  ),
                ),
              Row(
                mainAxisAlignment: mine
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!mine) ...[
                    InkWell(
                      onTap: message.senderId == null
                          ? null
                          : () => context.push('/user/${message.senderId}'),
                      borderRadius: BorderRadius.circular(17),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ProfileAvatar(
                          avatarSeed: message.senderAvatarSeed,
                          label: message.senderPseudonym,
                          profilePhotoUrl: message.senderProfilePhotoUrl,
                          size: 34,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Column(
                      crossAxisAlignment: col,
                      children: [
                        GestureDetector(
                          onLongPress: () => _openActions(context, ref),
                          child: _BubbleBody(
                            message: message,
                            mine: mine,
                            canManage: canManage,
                            onJumpTo: onJumpTo,
                            onQuestionTap: () => onQuestionTap(message),
                          ),
                        ),
                        MessageHugRow(
                          count: message.hugsCount,
                          huggedByMe: message.huggedByMe,
                          reactionCounts: message.reactionCounts ?? const {},
                          myReaction: message.myReaction,
                        ),
                        const SizedBox(height: 4),
                        Padding(
                          padding: EdgeInsets.only(
                            left: mine ? 0 : 6,
                            right: mine ? 6 : 0,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                message.isEdited
                                    ? '$timeStr · edited'
                                    : timeStr,
                                style: TextStyle(
                                  color: context.ink.withOpacity(0.5),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (mine) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.done_all_rounded,
                                  size: 13,
                                  color: VentlyColors.berryMagenta,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    // Swipe gesture: your own still-editable message opens the editor; any
    // other message starts a reply — the WhatsApp/IG muscle-memory gesture.
    final canEditNow = message.canEdit;
    return _TribeSwipeAction(
      icon: canEditNow ? Icons.edit_outlined : Icons.reply_rounded,
      onSwipe: canEditNow
          ? () => _editMessage(context, ref)
          : () => onReply(message),
      child: body,
    );
  }

  /// Unified long-press sheet for every message. Edit + delete-for-everyone
  /// are gated on the WhatsApp-style windows; delete-for-me is always there.
  void _openActions(BuildContext context, WidgetRef ref) {
    showTribeMessageActions(
      context,
      ref,
      message: message,
      tribeId: tribeId,
      tribeSlug: tribeSlug,
      canManage: canManage,
      onReply: () => onReply(message),
      onScrollToQuoted: () {
        if (message.replyToMessageId != null) {
          onJumpTo(message.replyToMessageId!);
        }
      },
      onEdit: message.canEdit ? () => _editMessage(context, ref) : null,
      onDeleteForEveryone: message.canDeleteForEveryone
          ? () => _deleteForEveryone(context, ref)
          : null,
      onDeleteForMe: () => _deleteForMe(context, ref),
      onCopy: (message.content?.trim().isNotEmpty ?? false)
          ? () => _copyText(context)
          : null,
      onReport: message.sentByMe ? null : () => _reportMessage(context, ref),
    );
  }

  void _copyText(BuildContext context) {
    Clipboard.setData(ClipboardData(text: message.content ?? ''));
    VentlyHaptics.selection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied.')));
  }

  Future<void> _reportMessage(BuildContext context, WidgetRef ref) async {
    final reason = await showReportReasonSheet(context);
    if (reason == null || !context.mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .reportTribeMessage(messageId: message.messageId, reason: reason);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you — a moderator will review.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not send: $e')));
    }
  }

  Future<void> _deleteForEveryone(BuildContext context, WidgetRef ref) async {
    try {
      final ok = await ref
          .read(repositoryProvider)
          .deleteTribeMessage(message.messageId);
      if (ok) ref.invalidate(tribeMessagesProvider(tribeId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendly(e))));
      }
    }
  }

  Future<void> _deleteForMe(BuildContext context, WidgetRef ref) async {
    try {
      final ok = await ref
          .read(repositoryProvider)
          .hideTribeMessage(message.messageId);
      if (ok) ref.invalidate(tribeMessagesProvider(tribeId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendly(e))));
      }
    }
  }

  Future<void> _editMessage(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: (message.content ?? ''));
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 1000,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated == null || updated.isEmpty) return;
    if (updated == (message.content ?? '')) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .editTribeMessage(messageId: message.messageId, newContent: updated);
      if (ok) ref.invalidate(tribeMessagesProvider(tribeId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendly(e))));
      }
    }
  }

  String _friendly(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('edit window')) {
      return 'The 30-minute edit window has passed.';
    }
    if (s.contains('delete-for-everyone window')) {
      return "It's been over 24h — you can only delete this for yourself.";
    }
    if (s.contains('not_author') || s.contains('not your message')) {
      return 'You can only do that to your own messages.';
    }
    return 'Something went wrong. Try again.';
  }
}

/// Horizontal-drag wrapper for tribe bubbles — nudges right and snaps back,
/// firing [onSwipe] past a 60px threshold. [icon] hints the action (reply or
/// edit). Mirrors the DM chat swipe so the gesture feels identical.
class _TribeSwipeAction extends StatefulWidget {
  const _TribeSwipeAction({
    required this.child,
    required this.onSwipe,
    this.icon = Icons.reply_rounded,
  });
  final Widget child;
  final VoidCallback onSwipe;
  final IconData icon;
  @override
  State<_TribeSwipeAction> createState() => _TribeSwipeActionState();
}

class _TribeSwipeActionState extends State<_TribeSwipeAction> {
  double _dx = 0;
  bool _fired = false;
  static const _trigger = 60.0;
  static const _maxNudge = 80.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        setState(() => _dx = (_dx + d.delta.dx).clamp(0.0, _maxNudge));
        if (!_fired && _dx >= _trigger) {
          _fired = true;
          VentlyHaptics.selection();
        }
      },
      onHorizontalDragEnd: (_) {
        if (_dx >= _trigger) widget.onSwipe();
        setState(() {
          _dx = 0;
          _fired = false;
        });
      },
      onHorizontalDragCancel: () => setState(() {
        _dx = 0;
        _fired = false;
      }),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_dx > 8)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Opacity(
                opacity: (_dx / _trigger).clamp(0.0, 1.0),
                child: Icon(
                  widget.icon,
                  size: 20,
                  color: VentlyColors.berryMagenta,
                ),
              ),
            ),
          AnimatedSlide(
            offset: Offset(_dx / 200, 0),
            duration: const Duration(milliseconds: 80),
            curve: Curves.easeOut,
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _BubbleBody extends StatelessWidget {
  const _BubbleBody({
    required this.message,
    required this.mine,
    required this.canManage,
    required this.onJumpTo,
    required this.onQuestionTap,
  });
  final TribeMessage message;
  final bool mine;
  final bool canManage;
  final ValueChanged<String> onJumpTo;
  final VoidCallback onQuestionTap;

  Widget _replyQuote() {
    if (message.replyToMessageId == null ||
        message.replySenderPseudonym == null) {
      return const SizedBox.shrink();
    }
    return ReplyQuote(
      senderPseudonym: message.replySenderPseudonym!,
      content: message.replyContent,
      lightOnDark: mine,
      onTap: () => onJumpTo(message.replyToMessageId!),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (message.isPoll) {
      return TribeChatPollCard(
        poll: TribeChatPoll.fromMessage(message),
        tribeId: message.tribeId,
        compact: true,
        lightOnDark: mine,
        canManage: canManage,
      );
    }
    if (message.isQuestion) {
      return TribeChatQuestionCard(
        question: TribeChatQuestion.fromMessage(message),
        lightOnDark: mine,
        answerCount: message.questionReplyCount,
        onTap: onQuestionTap,
      );
    }
    if (message.hasImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 260),
              child: CachedNetworkImage(
                imageUrl: message.imageUrl!,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  height: 180,
                  color: VentlyColors.softMauve.withOpacity(0.3),
                ),
                errorWidget: (_, __, ___) => Container(
                  height: 180,
                  color: VentlyColors.softMauve.withOpacity(0.3),
                ),
              ),
            ),
            if (message.hasText)
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: Text(
                  message.content!,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (message.hasAudio) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta,
          borderRadius: BorderRadius.circular(22),
        ),
        child: ChatAudioBubble(
          messageId: message.messageId,
          audioUrl: message.audioUrl!,
          durationSeconds: message.audioDurationSeconds ?? 0,
          caption: message.hasText ? message.content : null,
          lightOnDark: true,
        ),
      );
    }
    // Plain text.
    final textChild = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _replyQuote(),
        Text(
          message.content ?? '',
          style: TextStyle(
            color: mine ? Colors.white : context.ink,
            fontWeight: FontWeight.w700,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ],
    );
    if (mine) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(6),
          ),
          boxShadow: [
            BoxShadow(
              color: VentlyColors.berryMagenta.withOpacity(0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: textChild,
      );
    }
    return GlassBubble(child: textChild);
  }
}

// =========================================================================
// COMPOSER
// =========================================================================

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.recording,
    required this.replyTo,
    required this.typingLabel,
    required this.onClearReply,
    required this.onSend,
    required this.onPickImage,
    required this.onMicTap,
    required this.onPoll,
    required this.onQuestion,
  });
  final TextEditingController controller;
  final bool sending;
  final bool recording;
  final TribeMessage? replyTo;
  final String? typingLabel;
  final VoidCallback onClearReply;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onMicTap;
  final VoidCallback onPoll;
  final VoidCallback onQuestion;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: GlassComposer(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (typingLabel != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    children: [
                      const _TypingDots(),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          typingLabel!,
                          style: TextStyle(
                            color: VentlyColors.berryMagenta.withOpacity(0.85),
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (replyTo != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                  child: Material(
                    color: VentlyColors.softMauve.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                      leading: const Icon(
                        Icons.reply,
                        size: 18,
                        color: VentlyColors.berryMagenta,
                      ),
                      title: Text(
                        'Reply to @${replyTo!.senderPseudonym}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                      subtitle: Text(
                        replyTo!.content ?? 'Attachment',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: onClearReply,
                      ),
                    ),
                  ),
                ),
              if (recording)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: VentlyColors.dangerRed,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Recording… tap mic to send',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: VentlyColors.dangerRed,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const _TypingDots(),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE3EC),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: IconButton(
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.add_rounded,
                        color: VentlyColors.berryMagenta,
                      ),
                      onPressed: _showAttachmentSheet(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: context.isDark
                            ? Colors.white.withOpacity(0.08)
                            : VentlyColors.cardBlush.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              minLines: 1,
                              maxLines: 5,
                              textCapitalization: TextCapitalization.sentences,
                              style: TextStyle(
                                color: context.ink,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Share your thoughts…',
                                hintStyle: TextStyle(
                                  color: context.ink.withOpacity(0.42),
                                  fontWeight: FontWeight.w700,
                                ),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              recording
                                  ? Icons.stop_circle
                                  : Icons.mic_none_rounded,
                              color: recording
                                  ? VentlyColors.dangerRed
                                  : context.ink,
                              size: 20,
                            ),
                            onPressed: onMicTap,
                            visualDensity: VisualDensity.compact,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.image_outlined,
                              color: context.ink,
                              size: 20,
                            ),
                            onPressed: onPickImage,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: FilledButton(
                      onPressed: sending ? null : onSend,
                      style: FilledButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      child: sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  VoidCallback _showAttachmentSheet(BuildContext context) {
    return () {
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) => GlassSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.photo_outlined,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Photo',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onPickImage();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.poll_outlined,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Poll',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onPoll();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.help_outline,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Question of the day',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onQuestion();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.mic_none_rounded,
                  color: VentlyColors.berryMagenta,
                ),
                title: Text(
                  recording ? 'Tap mic again to send' : 'Voice note',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onMicTap();
                },
              ),
            ],
          ),
        ),
      );
    };
  }
}

// =========================================================================
// EMPTY STATE
// =========================================================================

class _ChatEmpty extends StatelessWidget {
  const _ChatEmpty({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TribeAvatar(avatarUrl: tribe.avatarUrl, size: 88),
          const SizedBox(height: 16),
          Text(
            'Be the first to share.',
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'This tribe is waiting for the conversation to begin. Drop a vent, a voice note, or a photo.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withOpacity(0.66),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// "N replies · Follow topic" chip rendered under any message that has
/// replies. Tapping opens the topic thread sheet.
class _TopicThreadChip extends StatelessWidget {
  const _TopicThreadChip({
    required this.count,
    required this.alignEnd,
    required this.onTap,
  });

  final int count;
  final bool alignEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        top: 2,
        bottom: 6,
        left: alignEnd ? 0 : 46,
        right: alignEnd ? 8 : 0,
      ),
      child: Row(
        mainAxisAlignment: alignEnd
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: scheme.primary.withOpacity(0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.forum_outlined, size: 13, color: scheme.primary),
                  const SizedBox(width: 5),
                  Text(
                    '$count ${count == 1 ? 'reply' : 'replies'} · Follow topic',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full topic thread: root message + every descendant reply in order, with
/// a composer pinned to the bottom that replies into this topic.
class _TopicThreadSheet extends ConsumerStatefulWidget {
  const _TopicThreadSheet({required this.root, required this.tribe});

  final TribeMessage root;
  final Tribe tribe;

  @override
  ConsumerState<_TopicThreadSheet> createState() => _TopicThreadSheetState();
}

class _TopicThreadSheetState extends ConsumerState<_TopicThreadSheet> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Root + all descendants (replies to replies included), chronological.
  List<TribeMessage> _thread(List<TribeMessage> all) {
    final inThread = <String>{widget.root.messageId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final m in all) {
        final parent = m.replyToMessageId;
        if (parent != null &&
            inThread.contains(parent) &&
            inThread.add(m.messageId)) {
          grew = true;
        }
      }
    }
    return all.where((m) => inThread.contains(m.messageId)).toList();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await VentlyHaptics.send();
      await ref
          .read(repositoryProvider)
          .sendTribeMessage(
            tribeId: widget.tribe.tribeId,
            content: text,
            replyToMessageId: widget.root.messageId,
          );
      _controller.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not send: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(tribeMessagesProvider(widget.tribe.tribeId));
    final thread = _thread(async.valueOrNull ?? const <TribeMessage>[]);

    return GlassSheet(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: VentlyColors.softMauve.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.forum_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Topic · ${thread.isEmpty ? 1 : thread.length} messages',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: thread.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        itemCount: thread.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final m = thread[i];
                          final isRoot = i == 0;
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isRoot
                                  ? scheme.primary.withOpacity(0.10)
                                  : Colors.white.withOpacity(0.55),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isRoot
                                    ? scheme.primary.withOpacity(0.30)
                                    : VentlyColors.softMauve.withOpacity(0.30),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    ProfileAvatar(
                                      avatarSeed: m.senderAvatarSeed,
                                      label: m.senderPseudonym,
                                      profilePhotoUrl: m.senderProfilePhotoUrl,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              '@${m.senderPseudonym}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          if (m.senderIsVerified) ...[
                                            const SizedBox(width: 3),
                                            const VerifiedBadge(size: 12),
                                          ],
                                        ],
                                      ),
                                    ),
                                    Text(
                                      DateFormat.jm().format(m.createdAt),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: scheme.onSurface.withOpacity(
                                          0.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  m.deletedAt != null
                                      ? 'Message removed'
                                      : (m.content ?? '[media]'),
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.35,
                                    fontStyle: m.deletedAt != null
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                    color: m.deletedAt != null
                                        ? scheme.onSurface.withOpacity(0.5)
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'Reply in this topic…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: const BoxDecoration(
                      color: VentlyColors.berryMagenta,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded, color: Colors.white),
                      onPressed: _sending ? null : _send,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
