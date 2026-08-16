import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/connection.dart';
import '../../../core/providers.dart';
import '../../../data/services/draft_store.dart';
import '../../../data/services/moderation_service.dart';
import '../../../data/services/outbox.dart';
import '../../../data/services/whisper_recorder.dart';
import '../../widgets/chat_audio_bubble.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/report_reason_sheet.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/crisis_support_sheet.dart';
import '../../widgets/chat_options_sheet.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/verified_badge.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.roomId});
  final String roomId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// Debounce typing broadcasts so each keystroke doesn't ping Realtime.
  Timer? _typingDebounce;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bytes of an image the user picked but hasn't sent yet, plus its
  /// extension. Cleared on send or on the discard button.
  Uint8List? _pendingImageBytes;
  String _pendingImageExt = 'jpg';
  String _pendingImageMime = 'image/jpeg';
  bool _recordingVoice = false;
  bool _searching = false;
  final _searchController = TextEditingController();

  /// Chat V2: the message currently being quoted in the composer.
  /// When set, the composer shows a reply preview chip + the next send
  /// stamps parent_message_id on the new row.
  ChatMessage? _replyingTo;

  /// Chat V2: the message currently being edited in-place. When set,
  /// the composer is pre-filled with the existing plaintext and the
  /// send button calls edit_chat_message instead of send.
  ChatMessage? _editingMessage;

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      unawaited(
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ext = picked.path.split('.').last.toLowerCase();
      setState(() {
        _pendingImageBytes = bytes;
        _pendingImageExt = ext == 'jpeg' ? 'jpg' : ext;
        _pendingImageMime = picked.mimeType ?? 'image/jpeg';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not pick image: $e')));
    }
  }

  /// Voice note: first tap starts recording, second tap stops → uploads the
  /// m4a into chat-media → sends a message with attachedMediaType 'audio'.
  /// Mirrors the tribe-chat flow (WhisperRecorder is a shared singleton).
  Future<void> _toggleVoice() async {
    if (_recordingVoice) {
      setState(() => _recordingVoice = false);
      final result = await WhisperRecorder.instance.stop();
      if (result == null || !mounted) return;
      final durationSeconds = result.duration.inSeconds.clamp(1, 300);
      final operationId = OutboxService.newOperationId();
      final outbox = await ref.read(outboxProvider.future);
      StagedOutboxMedia? stagedMedia;
      String? mediaPath;
      try {
        stagedMedia = await outbox.stageMedia(
          operationId: operationId,
          bytes: result.bytes,
          extension: 'm4a',
          contentType: 'audio/mp4',
          mediaType: 'audio',
          durationSeconds: durationSeconds,
        );
        final up = await ref
            .read(repositoryProvider)
            .uploadChatAudio(
              roomId: widget.roomId,
              bytes: result.bytes,
              durationSeconds: durationSeconds,
            );
        mediaPath = up.path;
        await ref
            .read(repositoryProvider)
            .sendMessage(
              roomId: widget.roomId,
              plaintext: '',
              attachedMediaPath: up.path,
              attachedMediaType: 'audio',
              idempotencyKey: operationId,
            );
        await outbox.discardStagedMedia(stagedMedia.path);
        ref.invalidate(messagesProvider(widget.roomId));
      } catch (_) {
        if (stagedMedia != null) {
          await outbox.enqueue(OutboxKind.dm, {
            'roomId': widget.roomId,
            'plaintext': '',
            'attachedMediaPath': mediaPath,
            'attachedMediaType': mediaPath == null ? null : 'audio',
            ...stagedMedia.toPayload(),
          }, operationId: operationId);
        }
        if (!mounted) return;
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
      return;
    }
    final ok = await WhisperRecorder.instance.start();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone unavailable — check permissions.'),
        ),
      );
      return;
    }
    setState(() => _recordingVoice = true);
  }

  @override
  void initState() {
    super.initState();
    // Mark the room as read the moment the screen opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(repositoryProvider)
            .markRoomRead(widget.roomId)
            .then((_) {
              ref.invalidate(navInboxBadgeCountProvider);
              ref.invalidate(unreadInboxCountProvider);
              ref.invalidate(inboxStreamProvider);
            })
            .catchError((_) {});
      }
    });
    _controller.addListener(_handleTyping);
    // Per-room draft: restore unfinished text, auto-save while typing.
    ref.read(draftStoreProvider.future).then((store) {
      if (!mounted) return;
      _draftSaver = DraftSaver(
        store: store,
        draftKey: 'chat.${widget.roomId}',
        controller: _controller,
      );
      if (_draftSaver!.restore()) setState(() {});
    });
  }

  DraftSaver? _draftSaver;

  void _handleTyping() {
    // Throttle: emit at most once every 1.5 seconds while typing.
    final now = DateTime.now();
    if (now.difference(_lastTypingSent).inMilliseconds < 1500) return;
    _lastTypingSent = now;
    ref.read(repositoryProvider).broadcastTyping(widget.roomId);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 1500), () {});
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _draftSaver?.dispose();
    _controller.removeListener(_handleTyping);
    _controller.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roomAsync = ref.watch(roomByIdProvider(widget.roomId));
    final r = roomAsync.valueOrNull;
    if (roomAsync.isLoading && r == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const ChatSkeleton(),
      );
    }
    if (r == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('Conversation not found')),
      );
    }
    final messages =
        ref.watch(messagesProvider(widget.roomId)).valueOrNull ?? const [];
    final prefs =
        ref.watch(dmRoomPrefsProvider(widget.roomId)).valueOrNull ??
        DmRoomPrefs.empty;
    final peerName = r.isGroup
        ? (r.groupTitle ?? r.peerPseudonym)
        : (prefs.peerNickname?.trim().isNotEmpty ?? false)
        ? prefs.peerNickname!.trim()
        : r.peerDisplayName;
    final groupAvatarUrl = r.groupAvatarPath == null
        ? null
        : ref.watch(groupAvatarUrlProvider(r.groupAvatarPath!)).valueOrNull;
    // DM peers are always accepted friends, so reuse the cached friends list
    // to know whether the peer is verified (no extra fetch).
    final peerVerified = () {
      if (r.isGroup) return false;
      final pid = r.peerUserId;
      if (pid == null) return false;
      final friends =
          ref.watch(myFriendsProvider).valueOrNull ?? const <FriendSummary>[];
      for (final f in friends) {
        if (f.userId == pid) return f.isVerified;
      }
      return false;
    }();
    // Conversation-level disappearing TTL (server hard-deletes on a cron;
    // hide immediately here so it feels instant) + in-chat search.
    final disappearing =
        ref.watch(roomDisappearingProvider(widget.roomId)).valueOrNull ?? 0;
    List<ChatMessage> visible = messages;
    if (disappearing > 0) {
      final cutoff = DateTime.now().subtract(Duration(seconds: disappearing));
      visible = visible.where((m) => m.createdAt.isAfter(cutoff)).toList();
    }
    final query = _searchController.text.trim().toLowerCase();
    if (_searching && query.isNotEmpty) {
      visible = visible
          .where((m) => m.plaintext.toLowerCase().contains(query))
          .toList();
    }
    // Per-room chat theme: inject the chosen accent as colorScheme.primary for
    // this screen's subtree, so every scheme.primary (bubbles, send button,
    // header, chips, typing dots) picks it up consistently — one source of
    // truth, no per-widget threading.
    final accent =
        kChatThemes[prefs.theme] ?? Theme.of(context).colorScheme.primary;
    final scheme = Theme.of(context).colorScheme.copyWith(primary: accent);
    final peerTyping =
        ref.watch(typingProvider(widget.roomId)).valueOrNull ?? false;

    // Mark unread peer messages as read whenever the messages list ticks
    // forward (new arrivals while the screen is open).
    ref.listen<AsyncValue<List<ChatMessage>>>(messagesProvider(widget.roomId), (
      prev,
      next,
    ) {
      final list = next.valueOrNull;
      if (list == null) return;
      final previousLength = prev?.valueOrNull?.length ?? 0;
      if (list.length > previousLength) {
        final nearLatest =
            !_scrollController.hasClients ||
            _scrollController.position.maxScrollExtent -
                    _scrollController.position.pixels <
                180;
        if (nearLatest || list.last.sentByMe) _scrollToLatest();
      }
      final hasUnreadFromPeer = list.any(
        (m) => !m.sentByMe && m.readAt == null,
      );
      if (hasUnreadFromPeer) {
        ref.read(repositoryProvider).markRoomRead(widget.roomId).then((_) {
          ref.invalidate(navInboxBadgeCountProvider);
          ref.invalidate(unreadInboxCountProvider);
          ref.invalidate(inboxStreamProvider);
        });
      }
    });

    // The last own-message that the peer has read. We show "Seen" on
    // exactly this bubble so the indicator doesn't pollute every message.
    String? lastSeenOwnId;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.sentByMe && m.readAt != null) {
        lastSeenOwnId = m.messageId;
        break;
      }
    }

    return Theme(
      data: Theme.of(context).copyWith(colorScheme: scheme),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _searching
            ? AppBar(
                title: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Search in conversation',
                    border: InputBorder.none,
                  ),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _searching = false;
                      _searchController.clear();
                    }),
                  ),
                ],
              )
            : AppBar(
                title: InkWell(
                  onTap: () => showChatOptionsSheet(
                    context,
                    room: r,
                    onSearch: () => setState(() {
                      _searching = true;
                      _searchController.clear();
                    }),
                  ),
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ProfileAvatar(
                        avatarSeed: r.isGroup
                            ? 'group-${r.roomId}'
                            : r.peerAvatarSeed,
                        label: peerName,
                        profilePhotoUrl: r.isGroup
                            ? groupAvatarUrl
                            : r.peerProfilePhotoUrl,
                        size: 34,
                      ),
                      const SizedBox(width: 9),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    peerName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (peerVerified) ...[
                                  const SizedBox(width: 4),
                                  const VerifiedBadge(size: 14),
                                ],
                              ],
                            ),
                            if (r.isGroup)
                              Text(
                                '${r.memberCount} members',
                                style: TextStyle(
                                  color: scheme.onSurface.withOpacity(0.58),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            else
                              _PresenceLine(
                                peerUserId: r.peerUserId,
                                accent: scheme.primary,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.more_horiz_rounded),
                    tooltip: 'Options',
                    onPressed: () => showChatOptionsSheet(
                      context,
                      room: r,
                      onSearch: () => setState(() {
                        _searching = true;
                        _searchController.clear();
                      }),
                    ),
                  ),
                ],
              ),
        body: Column(
          children: [
            Container(
              color: scheme.primary.withOpacity(0.06),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      r.isGroup
                          ? 'Private group chat - only members see this. Moderators can review reported chats.'
                          : 'Private chat - only you and your peer see this. Moderators can review reported chats.',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: visible.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: VentlyColors.softMauve.withOpacity(0.35),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'TODAY',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    );
                  }
                  final m = visible[i - 1];
                  if (SystemNotice.isSystem(m.plaintext)) {
                    return _SystemNoticeLine(
                      text: SystemNotice.strip(m.plaintext),
                    );
                  }
                  return _Bubble(
                    message: m,
                    fontStyle: prefs.fontStyle,
                    showSeen: m.messageId == lastSeenOwnId,
                    onReply: () => setState(() {
                      _replyingTo = m;
                      _editingMessage = null;
                    }),
                    onCopy: () {
                      Clipboard.setData(ClipboardData(text: m.plaintext));
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Copied.')));
                    },
                    onEdit: () {
                      setState(() {
                        _editingMessage = m;
                        _replyingTo = null;
                        _controller.text = m.plaintext;
                        _controller.selection = TextSelection.collapsed(
                          offset: _controller.text.length,
                        );
                      });
                    },
                    onDeleteForEveryone: () async {
                      try {
                        await ref
                            .read(repositoryProvider)
                            .deleteChatMessage(m.messageId);
                        ref.invalidate(messagesProvider(widget.roomId));
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(_deleteError(e))),
                        );
                      }
                    },
                    onDeleteForMe: () async {
                      try {
                        await ref
                            .read(repositoryProvider)
                            .hideChatMessage(m.messageId);
                        ref.invalidate(messagesProvider(widget.roomId));
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Could not delete: $e')),
                        );
                      }
                    },
                    onReport: () => _reportMessage(context, m),
                  );
                },
              ),
            ),
            _TypingChip(
              peerPseudonym: r.isGroup ? 'Someone' : r.peerPseudonym,
              visible: peerTyping,
            ),
            if (_replyingTo != null)
              _ReplyContextChip(
                message: _replyingTo!,
                onCancel: () => setState(() => _replyingTo = null),
              ),
            if (_editingMessage != null)
              _EditContextChip(
                message: _editingMessage!,
                onCancel: () {
                  setState(() {
                    _editingMessage = null;
                    _controller.clear();
                  });
                },
              ),
            _Composer(
              controller: _controller,
              pendingImageBytes: _pendingImageBytes,
              onAttachImage: _pickImage,
              onMicTap: _toggleVoice,
              recording: _recordingVoice,
              onClearImage: () => setState(() => _pendingImageBytes = null),
              onSend: () async {
                final t = _controller.text.trim();
                // EDIT path. Re-run the same safety review as a fresh send so
                // an initially-safe message cannot be replaced with abuse.
                if (_editingMessage != null) {
                  if (t.isEmpty) return;
                  final original = _editingMessage!;
                  try {
                    final moderation = await ref
                        .read(moderationServiceProvider)
                        .review(t);
                    if (!mounted) return;
                    if (moderation.isBlocked) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            moderation.reasons.isEmpty
                                ? 'Held back by safety AI.'
                                : moderation.reasons.first,
                          ),
                        ),
                      );
                      return;
                    }
                    await ref
                        .read(repositoryProvider)
                        .editChatMessage(
                          messageId: original.messageId,
                          newPlaintext: t,
                        );
                    if (!mounted) return;
                    _controller.clear();
                    setState(() => _editingMessage = null);
                    ref.invalidate(messagesProvider(widget.roomId));
                    if (moderation.surfaceCrisisHelpline && mounted) {
                      unawaited(
                        ref
                            .read(repositoryProvider)
                            .setChatMessageCrisis(
                              original.messageId,
                              'elevated',
                            )
                            .catchError((_) {}),
                      );
                      await showCrisisSupportSheet(context, ref);
                    }
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not edit: $e')),
                    );
                  }
                  return;
                }

                final pending = _pendingImageBytes;
                if (t.isEmpty && pending == null) return;
                ModerationResult? moderation;
                if (t.isNotEmpty) {
                  moderation = await ref
                      .read(moderationServiceProvider)
                      .review(t);
                  if (!context.mounted) return;
                  if (moderation.isBlocked) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          moderation.reasons.isEmpty
                              ? 'Held back by safety AI.'
                              : moderation.reasons.first,
                        ),
                      ),
                    );
                    return;
                  }
                }
                final operationId = OutboxService.newOperationId();
                final outbox = await ref.read(outboxProvider.future);
                final parentMessageId = _replyingTo?.messageId;
                String? mediaPath;
                String? mediaType;
                StagedOutboxMedia? stagedMedia;
                final ChatMessage sent;
                try {
                  if (pending != null) {
                    stagedMedia = await outbox.stageMedia(
                      operationId: operationId,
                      bytes: pending,
                      extension: _pendingImageExt,
                      contentType: _pendingImageMime,
                      mediaType: 'image',
                    );
                    final up = await ref
                        .read(repositoryProvider)
                        .uploadChatImage(
                          roomId: widget.roomId,
                          bytes: pending,
                          extension: _pendingImageExt,
                          contentType: _pendingImageMime,
                        );
                    mediaPath = up.path;
                    mediaType = 'image';
                  }
                  sent = await ref
                      .read(repositoryProvider)
                      .sendMessage(
                        roomId: widget.roomId,
                        plaintext: t,
                        attachedMediaPath: mediaPath,
                        attachedMediaType: mediaType,
                        parentMessageId: parentMessageId,
                        idempotencyKey: operationId,
                      );
                  await outbox.discardStagedMedia(stagedMedia?.path);
                } catch (_) {
                  if (pending != null && stagedMedia == null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not securely preserve the photo. The message was not queued.',
                          ),
                        ),
                      );
                    }
                    return;
                  }
                  try {
                    await outbox.enqueue(OutboxKind.dm, {
                      'roomId': widget.roomId,
                      'plaintext': t,
                      'attachedMediaPath': mediaPath,
                      'attachedMediaType': mediaType,
                      'parentMessageId': parentMessageId,
                      if (stagedMedia != null) ...stagedMedia.toPayload(),
                    }, operationId: operationId);
                    await _draftSaver?.clear();
                    _controller.clear();
                    if (mounted) setState(() => _replyingTo = null);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            "You're offline - message queued, it will send automatically.",
                          ),
                        ),
                      );
                    }
                  } catch (queueError) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "Couldn't preserve message: $queueError. Your draft is still saved.",
                        ),
                      ),
                    );
                  }
                  return;
                }
                await _draftSaver?.clear();
                _controller.clear();
                if (mounted) {
                  setState(() {
                    _pendingImageBytes = null;
                    _replyingTo = null;
                  });
                }
                ref.invalidate(messagesProvider(widget.roomId));
                _scrollToLatest();
                // Reuse the advisory pre-submit verdict to surface help quickly.
                // PostgreSQL separately scans the server-readable body at
                // ingress, so a modified client cannot bypass the safety rule.
                if (moderation != null &&
                    moderation.surfaceCrisisHelpline &&
                    context.mounted) {
                  final level =
                      moderation.categories.contains(HazardCategory.selfHarm) &&
                          moderation.reasons.any(
                            (r) => r.contains('care about you'),
                          )
                      ? 'high'
                      : 'elevated';
                  unawaited(
                    ref
                        .read(repositoryProvider)
                        .setChatMessageCrisis(sent.messageId, level)
                        .catchError((_) {}),
                  );
                  await showCrisisSupportSheet(context, ref);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reportMessage(BuildContext context, ChatMessage m) async {
    final reason = await showReportReasonSheet(context);
    if (reason == null || !context.mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .reportChatMessage(messageId: m.messageId, reason: reason);
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
}

/// Maps an edit/delete RPC error onto a friendly one-liner.
String _deleteError(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('window expired')) {
    return "It's been over 24h — you can only delete this for yourself.";
  }
  if (s.contains('not your message')) {
    return 'You can only delete your own messages.';
  }
  return 'Could not delete. Please try again.';
}

/// A centered, WhatsApp-style system line (e.g. disappearing-messages changes).
class _SystemNoticeLine extends StatelessWidget {
  const _SystemNoticeLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.primary.withOpacity(0.14)),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface.withOpacity(0.7),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({
    required this.message,
    required this.fontStyle,
    this.showSeen = false,
    this.onReply,
    this.onCopy,
    this.onEdit,
    this.onDeleteForEveryone,
    this.onDeleteForMe,
    this.onReport,
  });
  final ChatMessage message;
  final String fontStyle;

  /// Render the "Seen" footer under this bubble. The chat screen only
  /// sets this on the latest own-message that the peer has read so the
  /// indicator stays single, anchored, and unobtrusive.
  final bool showSeen;

  /// Chat V2 callbacks. onEdit fires only when the message is still editable
  /// (own + within 30 min); the action sheet gates on [ChatMessage.canEdit].
  /// Delete is two-tier: "for everyone" (own + <24h) and "for me" (always).
  final VoidCallback? onReply;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onDeleteForEveryone;
  final VoidCallback? onDeleteForMe;
  final VoidCallback? onReport;

  Future<void> _react(BuildContext context, WidgetRef ref) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReactionPalette(current: message.myReaction),
    );
    if (picked == null) return;
    try {
      await ref
          .read(repositoryProvider)
          .setMessageReaction(message.messageId, picked);
      ref.invalidate(messagesProvider(message.roomId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not react: $e')));
      }
    }
  }

  Future<void> _openActionSheet(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    final mine = message.sentByMe;
    final canEdit = onEdit != null && message.canEdit;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (onReply != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.reply_rounded, color: context.ink),
                  title: const Text(
                    'Reply',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onReply!();
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.add_reaction_outlined, color: context.ink),
                title: const Text(
                  'React',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _react(context, ref);
                },
              ),
              if (onCopy != null && message.plaintext.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.copy_rounded, color: context.ink),
                  title: const Text(
                    'Copy',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onCopy!();
                  },
                ),
              if (canEdit)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.edit_outlined, color: context.ink),
                  title: const Text(
                    'Edit',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text(
                    'Within 30 minutes of sending',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8B5566)),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onEdit!();
                  },
                ),
              if (onDeleteForMe != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Delete',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmDelete(context);
                  },
                ),
              if (!mine && onReport != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.flag_outlined, color: context.ink),
                  title: const Text(
                    'Report',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onReport!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// WhatsApp-style delete chooser. "Delete for everyone" only appears when
  /// the message is still yours-and-fresh (<24h); "Delete for me" is always
  /// available and hides the message from just this device.
  Future<void> _confirmDelete(BuildContext context) async {
    final canEveryone =
        onDeleteForEveryone != null && message.canDeleteForEveryone;
    final error = Theme.of(context).colorScheme.error;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Delete message?',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
              ),
              if (canEveryone)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.public_off_rounded, color: error),
                  title: Text(
                    'Delete for everyone',
                    style: TextStyle(color: error, fontWeight: FontWeight.w800),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    HapticFeedback.mediumImpact();
                    onDeleteForEveryone!();
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline, color: context.ink),
                title: const Text(
                  'Delete for me',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text(
                  'Removes it from your view only',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8B5566)),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onDeleteForMe!();
                },
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(sheetCtx),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.sentByMe;
    final snapshot = message.attachedPostSnapshot;
    final hasText = message.plaintext.trim().isNotEmpty;
    final reactions = message.reactionCounts;
    final deleted = message.isDeleted;

    // Soft-delete tombstone — minimal, italic, no actions wired.
    if (deleted) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.74,
          ),
          decoration: BoxDecoration(
            color: VentlyColors.softMauve.withOpacity(0.18),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.do_not_disturb_on_outlined,
                size: 12,
                color: scheme.onSurface.withOpacity(0.55),
              ),
              const SizedBox(width: 6),
              Text(
                'Message deleted',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.6),
                  fontStyle: FontStyle.italic,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final bubble = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _openActionSheet(context, ref),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (message.parentMessageId != null)
              Container(
                margin: EdgeInsets.only(
                  top: 4,
                  left: mine ? 0 : 6,
                  right: mine ? 6 : 0,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.72,
                ),
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border(
                    left: BorderSide(color: scheme.primary, width: 3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Replying to ${message.parentSenderPseudonym ?? "them"}',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      message.parentPreview ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withOpacity(0.72),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            // Shared-post card — rendered as its own bubble above any
            // accompanying text so the conversation reads "they sent me
            // this vent" then "their thought about it" in order.
            if (snapshot != null)
              Container(
                margin: EdgeInsets.only(top: 4, bottom: hasText ? 2 : 4),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                child: _SharedPostCard(
                  snapshot: snapshot,
                  attachedPostId: message.attachedPostId,
                  mine: mine,
                ),
              ),
            if (message.attachedMediaPath != null &&
                message.attachedMediaType == 'image')
              Container(
                margin: EdgeInsets.only(top: 4, bottom: hasText ? 2 : 4),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.72,
                ),
                child: _ChatImage(storagePath: message.attachedMediaPath!),
              ),
            if (message.attachedMediaPath != null &&
                message.attachedMediaType == 'audio')
              GestureDetector(
                onLongPress: () => _openActionSheet(context, ref),
                child: Container(
                  margin: EdgeInsets.only(top: 4, bottom: hasText ? 2 : 4),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.72,
                  ),
                  child: _ChatVoiceNote(
                    messageId: message.messageId,
                    storagePath: message.attachedMediaPath!,
                  ),
                ),
              ),

            if (hasText)
              GestureDetector(
                onLongPress: () => _openActionSheet(context, ref),
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  decoration: BoxDecoration(
                    color: mine ? scheme.primary : Theme.of(context).cardColor,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(mine ? 18 : 4),
                      bottomRight: Radius.circular(mine ? 4 : 18),
                    ),
                    border: mine
                        ? null
                        : Border.all(
                            color: VentlyColors.softMauve.withOpacity(0.4),
                          ),
                  ),
                  child: Text(
                    message.plaintext,
                    style: TextStyle(
                      color: mine ? Colors.white : null,
                      height: 1.35,
                      fontFamily: switch (fontStyle) {
                        'serif' => 'serif',
                        'mono' => 'monospace',
                        _ => null,
                      },
                    ),
                  ),
                ),
              ),
            if (reactions.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: 2,
                  left: mine ? 0 : 6,
                  right: mine ? 6 : 0,
                ),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final entry in reactions.entries)
                      _ReactionChip(
                        emoji: PostReactions.emoji(entry.key),
                        count: entry.value,
                        mine: message.myReaction == entry.key,
                        onTap: () => ref
                            .read(repositoryProvider)
                            .setMessageReaction(message.messageId, entry.key),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateFormat.jm().format(message.createdAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                  if (message.editedAt != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· edited',
                      style: TextStyle(
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurface.withOpacity(0.55),
                      ),
                    ),
                  ],
                  if (message.sentByMe && !message.isDeleted) ...[
                    const SizedBox(width: 6),
                    // WhatsApp-style ticks: ✓ sent, ✓✓ delivered,
                    // accent ✓✓ seen (delivered_at — migration 0114).
                    Icon(
                      message.readAt != null || message.deliveredAt != null
                          ? Icons.done_all
                          : Icons.done,
                      size: 12,
                      color: message.readAt != null
                          ? scheme.primary.withOpacity(0.85)
                          : scheme.onSurface.withOpacity(0.45),
                    ),
                  ],
                  if (showSeen) ...[
                    const SizedBox(width: 2),
                    Text(
                      'Seen',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary.withOpacity(0.85),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Swipe gesture: on your own still-editable message it opens the editor
    // (as requested); on anything else it starts a reply — the familiar
    // WhatsApp/IG gesture. Long-press still opens the full action sheet.
    final canEditNow = onEdit != null && message.canEdit;
    if (canEditNow) {
      return _SwipeAction(
        icon: Icons.edit_outlined,
        onSwipe: onEdit!,
        child: bubble,
      );
    }
    if (onReply != null) {
      return _SwipeAction(
        icon: Icons.reply_rounded,
        onSwipe: onReply!,
        child: bubble,
      );
    }
    return bubble;
  }
}

/// Lightweight horizontal-drag wrapper. We deliberately avoid
/// Dismissible because we never want the child to actually slide off
/// the screen — the bubble just nudges right and snaps back, then
/// triggers the intent (reply or edit) at the end of the gesture. The
/// [icon] hints which action will fire.
class _SwipeAction extends StatefulWidget {
  const _SwipeAction({
    required this.child,
    required this.onSwipe,
    this.icon = Icons.reply_rounded,
  });
  final Widget child;
  final VoidCallback onSwipe;
  final IconData icon;
  @override
  State<_SwipeAction> createState() => _SwipeActionState();
}

class _SwipeActionState extends State<_SwipeAction> {
  double _dx = 0;
  bool _fired = false;
  static const _trigger = 60.0;
  static const _maxNudge = 80.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        setState(() {
          _dx = (_dx + d.delta.dx).clamp(0.0, _maxNudge);
        });
        if (!_fired && _dx >= _trigger) {
          _fired = true;
          HapticFeedback.selectionClick();
        }
      },
      onHorizontalDragEnd: (_) {
        if (_dx >= _trigger) widget.onSwipe();
        setState(() {
          _dx = 0;
          _fired = false;
        });
      },
      onHorizontalDragCancel: () {
        setState(() {
          _dx = 0;
          _fired = false;
        });
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_dx > 8)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Opacity(
                opacity: (_dx / _trigger).clamp(0.0, 1.0),
                child: Icon(widget.icon, size: 20, color: context.ink),
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

/// Reply preview chip shown above the composer when [_replyingTo] is
/// set. Cancels via the X button.
class _ReplyContextChip extends StatelessWidget {
  const _ReplyContextChip({required this.message, required this.onCancel});
  final ChatMessage message;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = message.plaintext.trim().isEmpty
        ? '(media message)'
        : message.plaintext;
    return Container(
      color: scheme.primary.withOpacity(0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, color: scheme.primary, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to ${message.sentByMe ? "yourself" : "them"}',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withOpacity(0.75),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Edit preview chip — shows the original text the user is editing,
/// with a cancel button that restores the composer.
class _EditContextChip extends StatelessWidget {
  const _EditContextChip({required this.message, required this.onCancel});
  final ChatMessage message;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primary.withOpacity(0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.edit_outlined, color: scheme.primary, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
                Text(
                  message.plaintext,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withOpacity(0.7),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Presence subtitle under the peer's name: green-dot Online, Active
/// recently, Last seen Xh ago — or the "Private" fallback when the peer
/// hides their last seen (migration 0114).
class _PresenceLine extends ConsumerWidget {
  const _PresenceLine({required this.peerUserId, required this.accent});
  final String? peerUserId;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = peerUserId;
    final presence = id == null
        ? null
        : ref.watch(peerPresenceProvider(id)).valueOrNull;

    String label;
    Color color = accent;
    bool dot = false;
    switch (presence?.state) {
      case 'online':
        label = 'Online';
        color = VentlyColors.onlineGreen;
        dot = true;
        break;
      case 'recent':
        label = 'Active recently';
        break;
      case 'offline':
        label = 'Last seen ${_ago(presence!.lastSeen)}';
        break;
      default:
        label = 'Private';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot)
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 4),
            decoration: const BoxDecoration(
              color: VentlyColors.onlineGreen,
              shape: BoxShape.circle,
            ),
          )
        else ...[
          Icon(Icons.shield_outlined, size: 10, color: accent),
          const SizedBox(width: 3),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  String _ago(DateTime? t) {
    if (t == null) return 'a while ago';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

class _TypingChip extends StatelessWidget {
  const _TypingChip({required this.peerPseudonym, required this.visible});
  final String peerPseudonym;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: VentlyColors.softMauve.withOpacity(0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TypingDots(color: scheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          '$peerPseudonym is typing…',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Three pulsing dots — pure-Flutter typing affordance.
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});
  final Color color;
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value * 3 - i) % 1.0;
            final opacity = (t < 0.5) ? 0.3 + t : 1.3 - t;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: widget.color.withOpacity(opacity.clamp(0.25, 1.0)),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttachImage,
    required this.onMicTap,
    this.recording = false,
    this.pendingImageBytes,
    this.onClearImage,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;

  /// Voice note: tap to record, tap again to send. [recording] drives the
  /// pulsing red state.
  final VoidCallback onMicTap;
  final bool recording;

  /// When non-null, shows a small preview chip above the composer with
  /// a clear button. The send action will upload + attach this image.
  final Uint8List? pendingImageBytes;
  final VoidCallback? onClearImage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pendingImageBytes != null)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 6),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          pendingImageBytes!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Image attached. Hit send to share.',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: onClearImage,
                        tooltip: 'Discard image',
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  tooltip: 'Attach image',
                  onPressed: onAttachImage,
                ),
                IconButton(
                  icon: Icon(
                    recording
                        ? Icons.stop_circle_rounded
                        : Icons.mic_none_rounded,
                    color: recording ? Colors.redAccent : null,
                  ),
                  tooltip: recording ? 'Tap to send voice note' : 'Voice note',
                  onPressed: onMicTap,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    decoration: InputDecoration(
                      hintText: recording
                          ? 'Recording… tap ■ to send'
                          : 'Message',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.white),
                    onPressed: onSend,
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

/// Shared-post bubble rendered inside the chat thread. Reads from the
/// snapshot the sender captured at share time (migration 0027) so the
/// card still renders if the original post was later deleted.
///
/// Tapping opens the root-level post preview when the original still exists.
class _SharedPostCard extends StatelessWidget {
  const _SharedPostCard({
    required this.snapshot,
    required this.attachedPostId,
    required this.mine,
  });

  final SharedPostSnapshot snapshot;
  final String? attachedPostId;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final deleted = attachedPostId == null; // FK was nulled on post delete
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: deleted
            ? null
            : () => context.push('/post-preview/${snapshot.postId}'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine ? scheme.primary.withOpacity(0.10) : scheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.primary.withOpacity(0.35),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    snapshot.isWhisper
                        ? Icons.nightlight_round
                        : Icons.format_quote,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      snapshot.authorPseudonym ?? '@anonymous',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (snapshot.mood != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      Moods.emoji(snapshot.mood!),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                deleted
                    ? '[Original post deleted]\n\n${snapshot.content}'
                    : snapshot.content,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
                  color: deleted
                      ? Theme.of(context).colorScheme.onSurface.withOpacity(0.7)
                      : null,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.open_in_new,
                    size: 11,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.55),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    deleted ? 'Original no longer available' : 'Open original',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.55),
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

/// Floating emoji palette shown on long-press of a bubble. Returns the
/// chosen reaction key to the caller via Navigator.pop.
class _ReactionPalette extends StatelessWidget {
  const _ReactionPalette({required this.current});
  final String? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final key in PostReactions.all)
                _PaletteEmoji(
                  emoji: PostReactions.emoji(key),
                  label: PostReactions.label(key),
                  selected: key == current,
                  onTap: () => Navigator.of(context).pop(key),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteEmoji extends StatelessWidget {
  const _PaletteEmoji({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 28,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Image attachment in a chat bubble. Resolves the storage path to a
/// short-lived signed URL via the repo, then renders via
/// CachedNetworkImage. Tap → fullscreen InteractiveViewer.
class _ChatImage extends ConsumerStatefulWidget {
  const _ChatImage({required this.storagePath});
  final String storagePath;

  @override
  ConsumerState<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends ConsumerState<_ChatImage> {
  late Future<String> _urlFuture;

  @override
  void initState() {
    super.initState();
    _urlFuture = ref
        .read(repositoryProvider)
        .chatImageSignedUrl(widget.storagePath);
  }

  void _openFullscreen(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator()),
                errorWidget: (_, __, ___) => const Icon(
                  Icons.broken_image,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _urlFuture,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return Container(
            height: 160,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        final url = snap.data!;
        return GestureDetector(
          onTap: () => _openFullscreen(context, url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                height: 200,
                color: Theme.of(context).colorScheme.surface,
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (_, __, ___) => Container(
                height: 100,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(
                  child: Icon(Icons.broken_image, color: Colors.black45),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Voice-note attachment in a chat bubble. Resolves the private storage path
/// to a signed URL, parses the duration encoded in the object name
/// (`voice-<id>-d<seconds>s.m4a`), and renders the shared audio player.
class _ChatVoiceNote extends ConsumerStatefulWidget {
  const _ChatVoiceNote({required this.messageId, required this.storagePath});
  final String messageId;
  final String storagePath;

  @override
  ConsumerState<_ChatVoiceNote> createState() => _ChatVoiceNoteState();
}

class _ChatVoiceNoteState extends ConsumerState<_ChatVoiceNote> {
  late Future<String> _urlFuture;

  @override
  void initState() {
    super.initState();
    _urlFuture = ref
        .read(repositoryProvider)
        .chatImageSignedUrl(widget.storagePath);
  }

  int get _durationSeconds {
    final m = RegExp(r'-d(\d+)s\.').firstMatch(widget.storagePath);
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _urlFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return Container(
            height: 52,
            width: 220,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: snap.hasError
                ? const Icon(Icons.error_outline, size: 18)
                : const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          );
        }
        return ChatAudioBubble(
          messageId: widget.messageId,
          audioUrl: snap.data!,
          durationSeconds: _durationSeconds,
          lightOnDark: false,
        );
      },
    );
  }
}

/// Small pill below a bubble showing one reaction type + count. Tappable
/// to toggle/swap; highlighted when it's the caller's reaction.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: mine ? scheme.primary.withOpacity(0.18) : scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine
                ? scheme.primary.withOpacity(0.6)
                : scheme.outline.withOpacity(0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 12)),
            if (count > 1) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: mine
                      ? scheme.primary
                      : scheme.onSurface.withOpacity(0.75),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
