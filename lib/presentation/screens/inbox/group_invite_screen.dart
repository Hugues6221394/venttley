import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/group_invite_links.dart';
import '../../../core/providers.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';

typedef GroupInviteShareCallback =
    Future<void> Function(
      String text, {
      String? subject,
      Rect? sharePositionOrigin,
    });

typedef GroupInviteClipboardCallback = Future<void> Function(String text);

Future<void> _shareInvite(
  String text, {
  String? subject,
  Rect? sharePositionOrigin,
}) {
  return Share.share(
    text,
    subject: subject,
    sharePositionOrigin: sharePositionOrigin,
  );
}

Future<void> _copyInvite(String text) {
  return Clipboard.setData(ClipboardData(text: text));
}

/// Opens an explicit capability-sharing surface without rendering the invite
/// token or URI. The secret only leaves this widget after a copy/share action.
Future<void> showGroupInviteShareSheet(
  BuildContext context, {
  required String groupTitle,
  required String token,
  Future<void> Function()? onReset,
  ValueChanged<String>? onFeedback,
  GroupInviteShareCallback share = _shareInvite,
  GroupInviteClipboardCallback copy = _copyInvite,
}) {
  // Validate before opening so a stale or corrupted backend value can never be
  // presented as a usable invitation.
  groupInviteUri(token);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => GroupInviteShareSheet(
      groupTitle: groupTitle,
      token: token,
      onReset: onReset,
      onFeedback: onFeedback,
      share: share,
      copy: copy,
    ),
  );
}

/// The member-side invite controls. Public for focused widget tests.
class GroupInviteShareSheet extends StatefulWidget {
  const GroupInviteShareSheet({
    super.key,
    required this.groupTitle,
    required this.token,
    this.onReset,
    this.onFeedback,
    this.share = _shareInvite,
    this.copy = _copyInvite,
  });

  final String groupTitle;
  final String token;
  final Future<void> Function()? onReset;
  final ValueChanged<String>? onFeedback;
  final GroupInviteShareCallback share;
  final GroupInviteClipboardCallback copy;

  @override
  State<GroupInviteShareSheet> createState() => _GroupInviteShareSheetState();
}

enum _InviteAction { share, copy, reset }

class _GroupInviteShareSheetState extends State<GroupInviteShareSheet> {
  _InviteAction? _action;

  String get _link => groupInviteUri(widget.token).toString();

  String get _groupTitle {
    final normalized = widget.groupTitle.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return 'this group';
    return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
  }

  String get _shareText => 'Join $_groupTitle on Venttly.\n$_link';

  Rect? _shareOrigin(BuildContext actionContext) {
    final box = actionContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _feedback(String message) {
    final callback = widget.onFeedback;
    if (callback != null) {
      callback(message);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(BuildContext actionContext) async {
    if (_action != null) return;
    setState(() => _action = _InviteAction.share);
    try {
      await widget.share(
        _shareText,
        subject: 'Venttly group invite',
        sharePositionOrigin: _shareOrigin(actionContext),
      );
    } catch (_) {
      _feedback('Could not open sharing. Try copying the link instead.');
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _copy() async {
    if (_action != null) return;
    setState(() => _action = _InviteAction.copy);
    try {
      await widget.copy(_link);
      if (!mounted) return;
      Navigator.pop(context);
      _feedback('Invite link copied. Share it only with people you trust.');
    } catch (_) {
      _feedback('Could not copy the invite link. Please try again.');
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _reset() async {
    if (_action != null || widget.onReset == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset invite link?'),
        content: const Text(
          'The current link will stop working. You will need to share the new '
          'one with anyone who still needs it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reset link'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _action = _InviteAction.reset);
    try {
      await widget.onReset!();
      if (!mounted) return;
      Navigator.pop(context);
      _feedback('A new invite link is ready. The old link no longer works.');
    } catch (_) {
      _feedback('Could not reset the invite link. Please try again.');
      if (mounted) setState(() => _action = null);
    }
  }

  Widget _progressIcon(IconData fallback, _InviteAction action) {
    if (_action != action) return Icon(fallback);
    return const SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        26 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Invite people',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            _groupTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'The private link is hidden on this screen. Anyone you '
                      'send it to can join while invites are enabled.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Builder(
            builder: (actionContext) => FilledButton.icon(
              onPressed: _action == null ? () => _share(actionContext) : null,
              icon: _progressIcon(Icons.ios_share_rounded, _InviteAction.share),
              label: const Text('Share invite'),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _action == null ? _copy : null,
            icon: _progressIcon(Icons.copy_rounded, _InviteAction.copy),
            label: const Text('Copy link'),
          ),
          const SizedBox(height: 8),
          Text(
            'Copying places the private link on your device clipboard.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (widget.onReset != null) ...[
            const Divider(height: 28),
            TextButton.icon(
              onPressed: _action == null ? _reset : null,
              icon: _progressIcon(Icons.refresh_rounded, _InviteAction.reset),
              label: const Text('Reset link'),
            ),
          ],
        ],
      ),
    );
  }
}

class GroupInviteScreen extends ConsumerStatefulWidget {
  const GroupInviteScreen({super.key, required this.token});

  final String token;

  @override
  ConsumerState<GroupInviteScreen> createState() => _GroupInviteScreenState();
}

class _GroupInviteScreenState extends ConsumerState<GroupInviteScreen> {
  bool _joining = false;

  Future<void> _join() async {
    if (_joining) return;
    final token = normalizeGroupInviteToken(widget.token);
    if (token == null) return;
    setState(() => _joining = true);
    try {
      final roomId = await ref
          .read(repositoryProvider)
          .joinGroupChatByInvite(token);
      ref.invalidate(inboxStreamProvider);
      ref.invalidate(inboxCountsProvider);
      ref.invalidate(roomByIdProvider(roomId));
      if (mounted) context.go('/chat/$roomId');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This invite is unavailable. Ask for a new link.'),
        ),
      );
      setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final token = normalizeGroupInviteToken(widget.token);
    final Widget content;
    if (token == null) {
      content = const _UnavailableInvite();
    } else {
      final inviteAsync = ref.watch(groupInvitePreviewProvider(token));
      content = inviteAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _UnavailableInvite(),
        data: (invite) {
          if (invite == null) return const _UnavailableInvite();
          final avatarUrl = invite.avatarPath == null
              ? null
              : ref
                    .watch(groupAvatarUrlProvider(invite.avatarPath!))
                    .valueOrNull;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProfileAvatar(
                    avatarSeed: 'group-${invite.roomId}',
                    label: invite.title,
                    profilePhotoUrl: avatarUrl,
                    size: 118,
                  ),
                  const SizedBox(height: 22),
                  Text(
                    invite.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('${invite.memberCount} members'),
                  const SizedBox(height: 26),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _joining ? null : _join,
                      icon: _joining
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.group_add_outlined),
                      label: const Text('Join group'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Only members can read this private conversation.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(),
      body: VentlyPremiumBackground(
        child: content,
      ),
    );
  }
}

class _UnavailableInvite extends StatelessWidget {
  const _UnavailableInvite();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off_rounded, size: 48),
              SizedBox(height: 14),
              Text(
                'Invite unavailable',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
              ),
              SizedBox(height: 6),
              Text(
                'This link may have expired or been reset by the group owner.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
