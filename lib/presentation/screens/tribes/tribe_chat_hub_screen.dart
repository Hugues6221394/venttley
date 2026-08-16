import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_chat_hub.dart';
import '../../widgets/tribe/tribe_chat_poll_sheet.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/tribe/online_avatar_ring.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// WhatsApp-style tribe group info hub.
class TribeChatHubScreen extends ConsumerWidget {
  const TribeChatHubScreen({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribeAsync = ref.watch(tribeBySlugProvider(slug));
    return tribeAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (tribe) {
        if (tribe == null) {
          return const Scaffold(body: Center(child: Text('Tribe not found')));
        }
        return DefaultTabController(
          length: 2,
          child: _HubBody(tribe: tribe),
        );
      },
    );
  }
}

class _HubBody extends ConsumerWidget {
  const _HubBody({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = ref.watch(canManageTribeProvider(tribe.tribeId));
    final me = ref.watch(sessionProvider);
    final isOwner = me != null && tribe.keeperId == me.userId;
    final onlineAsync = ref.watch(tribeOnlineMembersProvider(tribe.tribeId));
    final membersAsync = ref.watch(tribeMembersProvider(tribe.tribeId));
    final promptsAsync = ref.watch(tribePromptsProvider(tribe.tribeId));
    // extendBodyBehindAppBar lets the premium gradient show through the
    // transparent AppBar, but content must start BELOW the app bar + tab bar —
    // otherwise the hero (and its camera badge) render behind the bar and the
    // badge isn't even tappable.
    final topInset = MediaQuery.of(context).padding.top +
        kToolbarHeight +
        kTextTabBarHeight +
        12;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'Tribe info',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: context.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        // The bar is transparent so the premium gradient shows through, and
        // `topInset` below starts the content underneath it. That holds at
        // rest and breaks the moment the list moves: a scheduled-prompt row
        // and the "Chat settings" heading scrolled straight through the title
        // and the Info/Media tabs with nothing between them.
        //
        // A blur keeps the gradient visible — an opaque bar would flatten it —
        // while giving moving content something to pass behind. Always on
        // rather than scroll-driven, because unlike the public profile there
        // is no full-bleed hero here whose top edge needs protecting.
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).scaffoldBackgroundColor.withOpacity(0.72),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        bottom: TabBar(
          labelColor: VentlyColors.berryMagenta,
          unselectedLabelColor: context.ink.withOpacity(0.55),
          indicatorColor: VentlyColors.berryMagenta,
          labelStyle:
              const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
          unselectedLabelStyle:
              const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          tabs: const [
            Tab(text: 'Info'),
            Tab(text: 'Media'),
          ],
        ),
      ),
      body: VentlyPremiumBackground(
        child: TabBarView(
          children: [
            RefreshIndicator(
              color: VentlyColors.berryMagenta,
              onRefresh: () async {
                ref.invalidate(tribeBySlugProvider(tribe.slug));
                ref.invalidate(tribeOnlineMembersProvider(tribe.tribeId));
                ref.invalidate(tribeMembersProvider(tribe.tribeId));
                ref.invalidate(tribePromptsProvider(tribe.tribeId));
              },
              child: ListView(
                padding: EdgeInsets.fromLTRB(20, topInset, 20, 32),
                children: [
                  _HeroSection(tribe: tribe, canEditIdentity: isOwner)
                      .animate()
                      .fadeIn(duration: 280.ms)
                      .slideY(begin: 0.05, end: 0),
                  const SizedBox(height: 18),
                  _QuickActions(tribe: tribe, canManage: canManage)
                      .animate()
                      .fadeIn(delay: 60.ms, duration: 280.ms),
                  const SizedBox(height: 18),
                  const _SectionTitle('Active now'),
                  const SizedBox(height: 8),
                  onlineAsync.when(
                    loading: () => const LinearProgressIndicator(minHeight: 2),
                    error: (_, __) => const Text('Could not load presence'),
                    data: (online) => _OnlineRow(members: online),
                  ),
                  const SizedBox(height: 18),
                  _SectionTitle('${tribe.memberCount} members'),
                  const SizedBox(height: 8),
                  membersAsync.when(
                    loading: () => const LinearProgressIndicator(minHeight: 2),
                    error: (e, _) => Text('Could not load members: $e'),
                    data: (members) => _MembersList(
                      tribe: tribe,
                      members: members,
                      canManage: canManage,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _RulesSection(tribe: tribe, canManage: canManage),
                  const SizedBox(height: 18),
                  const _SectionTitle('Group prompts'),
                  const SizedBox(height: 8),
                  promptsAsync.when(
                    loading: () => const LinearProgressIndicator(minHeight: 2),
                    error: (e, _) => Text('Could not load prompts: $e'),
                    data: (prompts) => _PromptsSection(
                      tribe: tribe,
                      prompts: prompts,
                      canManage: canManage,
                    ),
                  ),
                  if (canManage) ...[
                    const SizedBox(height: 18),
                    const _SectionTitle('Chat settings'),
                    const SizedBox(height: 8),
                    _ChatSettingsCard(tribe: tribe),
                  ],
                  if (isOwner) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () =>
                          context.push('/tribe/${tribe.slug}/manage'),
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      label: const Text(
                        'Full tribe manage',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _MediaTab(tribeId: tribe.tribeId, topInset: topInset),
          ],
        ),
      ),
    );
  }
}

class _MediaTab extends ConsumerWidget {
  const _MediaTab({required this.tribeId, this.topInset = 16});
  final String tribeId;
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaAsync = ref.watch(tribeChatMediaProvider(tribeId));
    return mediaAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('No shared media yet'));
        }
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(16, topInset, 16, 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final m = items[i];
            if (m.imageUrl != null) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(m.imageUrl!, fit: BoxFit.cover),
              );
            }
            return Container(
              decoration: BoxDecoration(
                color: VentlyColors.berryMagenta.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.mic, color: VentlyColors.berryMagenta),
            );
          },
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: context.ink,
        fontWeight: FontWeight.w900,
        fontSize: 15,
      ),
    );
  }
}

class _HeroSection extends ConsumerWidget {
  const _HeroSection({
    required this.tribe,
    required this.canEditIdentity,
  });
  final Tribe tribe;
  final bool canEditIdentity;

  Future<void> _pickAvatar(BuildContext context, WidgetRef ref) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 88,
    );
    if (picked == null) return;
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.split('.').last;
      final upload = await ref.read(repositoryProvider).uploadTribeAvatar(
            tribeId: tribe.tribeId,
            bytes: bytes,
            extension: ext,
            contentType: picked.mimeType ?? 'image/jpeg',
          );
      await ref.read(repositoryProvider).setTribeAvatar(
            tribeId: tribe.tribeId,
            avatarUrl: upload.url,
          );
      ref.invalidate(tribeBySlugProvider(tribe.slug));
      ref.invalidate(tribesIKeepProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tribe photo updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            TribeAvatar(avatarUrl: tribe.avatarUrl, size: 96),
            if (canEditIdentity)
              Material(
                color: VentlyColors.berryMagenta,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _pickAvatar(context, ref),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.camera_alt_rounded,
                        color: Colors.white, size: 16),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          tribe.name,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 22,
            color: context.ink,
          ),
        ),
        if ((tribe.description ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              tribe.description!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink.withOpacity(0.65),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

class _QuickActions extends ConsumerWidget {
  const _QuickActions({required this.tribe, required this.canManage});
  final Tribe tribe;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: _ActionChip(
            icon: Icons.poll_rounded,
            label: 'Poll',
            onTap: () => showTribeChatCardSheet(
              context,
              ref,
              tribeId: tribe.tribeId,
              kind: TribeChatCardKind.poll,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionChip(
            icon: Icons.help_rounded,
            label: 'Question',
            onTap: () => showTribeChatCardSheet(
              context,
              ref,
              tribeId: tribe.tribeId,
              kind: TribeChatCardKind.question,
            ),
          ),
        ),
        if (canManage) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _ActionChip(
              icon: Icons.lightbulb_outline,
              label: 'Prompt',
              onTap: () => _showPromptComposer(context, ref),
            ),
          ),
        ],
      ],
    );
  }

  void _showPromptComposer(BuildContext context, WidgetRef ref) {
    showTribePromptComposer(context, tribeId: tribe.tribeId);
  }
}

/// Opens the tribe prompt composer as a modal sheet. Shared by the hub's
/// "Prompt" action and the in-chat keeper "Prompt" chip so both write a
/// prompt (rather than the chip bouncing to the info/hub screen).
Future<void> showTribePromptComposer(
  BuildContext context, {
  required String tribeId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _PromptComposer(tribeId: tribeId),
  );
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: VentlyColors.berryMagenta, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                  color: context.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnlineRow extends StatelessWidget {
  const _OnlineRow({required this.members});
  final List<TribeOnlineMember> members;

  @override
  Widget build(BuildContext context) {
    final online = members.where((m) => m.isOnline).toList();
    if (online.isEmpty) {
      return GlassCard(
        child: Text(
          'No one active in the last 5 minutes.',
          style: TextStyle(
            color: context.ink.withOpacity(0.6),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return SizedBox(
      height: 78,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: online.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final m = online[i];
          return InkWell(
            onTap: () => context.push('/user/${m.userId}'),
            borderRadius: BorderRadius.circular(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OnlineAvatarRing(
                  avatarSeed: m.avatarSeed,
                  label: m.displayName,
                  profilePhotoUrl: m.profilePhotoUrl,
                  size: 48,
                  isOnline: m.isOnline,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: 56,
                  child: Text(
                    m.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MembersList extends ConsumerWidget {
  const _MembersList({
    required this.tribe,
    required this.members,
    required this.canManage,
  });
  final Tribe tribe;
  final List<TribeMemberRow> members;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final isKeeper = me?.userId == tribe.keeperId;

    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          for (final m in members)
            ListTile(
              onTap: () => context.push('/user/${m.userId}'),
              leading: UserProfileLink(
                userId: m.userId,
                pseudonym: m.pseudonym,
                avatarSeed: m.avatarSeed,
                profilePhotoUrl: m.profilePhotoUrl,
                size: 40,
              ),
              // Display name leads, handle follows. This roster was the last
              // list in the app still headed by "@pseudonym" after the
              // display-name rollout reached the feed, threads, chat and the
              // friends list — so the same person read as "Healing Slow"
              // everywhere else and "@HealingSlow" here.
              title: Text(m.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                m.role == 'keeper'
                    ? '@${m.pseudonym} · Plug'
                    : m.role == 'mod'
                        ? '@${m.pseudonym} · Co-mod'
                        : '@${m.pseudonym} · Member',
                style: TextStyle(
                  fontSize: 11,
                  color: VentlyColors.berryMagenta.withOpacity(0.85),
                  fontWeight: FontWeight.w800,
                ),
              ),
              trailing: canManage &&
                      m.userId != me?.userId &&
                      m.role != 'keeper'
                  ? PopupMenuButton<String>(
                      onSelected: (v) async {
                        final repo = ref.read(repositoryProvider);
                        try {
                          if (v == 'kick') {
                            await repo.kickMember(
                              tribeId: tribe.tribeId,
                              userId: m.userId,
                              reason: 'Removed by keeper',
                            );
                          } else if (v == 'promote' && isKeeper) {
                            await repo.promoteToMod(
                              tribeId: tribe.tribeId,
                              userId: m.userId,
                            );
                          } else if (v == 'demote' && isKeeper) {
                            await repo.demoteToMember(
                              tribeId: tribe.tribeId,
                              userId: m.userId,
                            );
                          }
                          ref.invalidate(tribeMembersProvider(tribe.tribeId));
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$e')),
                            );
                          }
                        }
                      },
                      itemBuilder: (_) => [
                        if (m.role == 'member' && isKeeper)
                          const PopupMenuItem(
                            value: 'promote',
                            child: Text('Promote to mod'),
                          ),
                        if (m.role == 'mod' && isKeeper)
                          const PopupMenuItem(
                            value: 'demote',
                            child: Text('Demote to member'),
                          ),
                        const PopupMenuItem(
                          value: 'kick',
                          child: Text('Remove from tribe',
                              style: TextStyle(color: VentlyColors.dangerRed)),
                        ),
                      ],
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

class _RulesSection extends ConsumerStatefulWidget {
  const _RulesSection({required this.tribe, required this.canManage});
  final Tribe tribe;
  final bool canManage;

  @override
  ConsumerState<_RulesSection> createState() => _RulesSectionState();
}

class _RulesSectionState extends ConsumerState<_RulesSection> {
  late TextEditingController _ctl;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.tribe.rules ?? '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(repositoryProvider).setTribeRules(
      tribeId: widget.tribe.tribeId,
      rules: {'text': _ctl.text.trim()},
    );
    ref.invalidate(tribeBySlugProvider(widget.tribe.slug));
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tribe rules',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: context.ink,
                  ),
                ),
              ),
              if (widget.canManage)
                TextButton(
                  onPressed: () {
                    if (_editing) {
                      _save();
                    } else {
                      setState(() => _editing = true);
                    }
                  },
                  child: Text(_editing ? 'Save' : 'Edit'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_editing)
            TextField(
              controller: _ctl,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Be kind. No names. Keep it safe.',
                border: OutlineInputBorder(),
              ),
            )
          else
            Text(
              (widget.tribe.rules ?? '').isEmpty
                  ? 'No rules set yet.'
                  : widget.tribe.rules!,
              style: TextStyle(
                color: context.ink.withOpacity(0.75),
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
        ],
      ),
    );
  }
}

class _PromptsSection extends ConsumerWidget {
  const _PromptsSection({
    required this.tribe,
    required this.prompts,
    required this.canManage,
  });
  final Tribe tribe;
  final List<ScheduledPrompt> prompts;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (prompts.isEmpty) {
      return GlassCard(
        child: Text(
          'No prompts yet.',
          style: TextStyle(
            color: context.ink.withOpacity(0.6),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          for (final p in prompts)
            ListTile(
              leading: Icon(
                p.isLive ? Icons.check_circle : Icons.schedule,
                color: VentlyColors.berryMagenta,
                size: 20,
              ),
              title: Text(p.text,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800)),
              subtitle: Text(
                p.scheduledFor == null
                    ? (p.isLive ? 'Live' : 'Draft')
                    : DateFormat('MMM d · HH:mm').format(p.scheduledFor!),
                style: const TextStyle(fontSize: 11),
              ),
              trailing: canManage
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => _editPrompt(context, ref, p),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 18, color: VentlyColors.dangerRed),
                          onPressed: () => _deletePrompt(context, ref, p),
                        ),
                      ],
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _editPrompt(
      BuildContext context, WidgetRef ref, ScheduledPrompt p) async {
    final ctl = TextEditingController(text: p.text);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit prompt'),
        content: TextField(
          controller: ctl,
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated == null || updated.length < 4) return;
    await ref.read(repositoryProvider).updatePrompt(
          tribeId: tribe.tribeId,
          promptId: p.promptId,
          text: updated,
          scheduledFor: p.scheduledFor,
        );
    ref.invalidate(tribePromptsProvider(tribe.tribeId));
  }

  Future<void> _deletePrompt(
      BuildContext context, WidgetRef ref, ScheduledPrompt p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete prompt?'),
        content: const Text('This removes the prompt from your tribe hub.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repositoryProvider).deletePrompt(tribe.tribeId, p.promptId);
    ref.invalidate(tribePromptsProvider(tribe.tribeId));
  }
}

class _ChatSettingsCard extends ConsumerWidget {
  const _ChatSettingsCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = tribe.chatSettings;
    return GlassCard(
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 72,
              width: double.infinity,
              child: VentlyPremiumBackground(
                wallpaperUrl: s.wallpaperUrl,
                wallpaperStyle: s.wallpaperStyle,
                child: Center(
                  child: Text(
                    'Chat preview',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: context.ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Members can invite',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Let members add friends to this tribe'),
            value: s.membersCanInvite,
            onChanged: (v) => _patch(ref, {'members_can_invite': v}),
          ),
          SwitchListTile(
            title: const Text('Members can send media',
                style: TextStyle(fontWeight: FontWeight.w800)),
            value: s.membersCanSendMedia,
            onChanged: (v) => _patch(ref, {'members_can_send_media': v}),
          ),
          SwitchListTile(
            title: const Text('Announce joins',
                style: TextStyle(fontWeight: FontWeight.w800)),
            value: s.announceJoins,
            onChanged: (v) => _patch(ref, {'announce_joins': v}),
          ),
          SwitchListTile(
            title: const Text('Disappearing messages',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Auto-clear after 7 days (beta)'),
            value: s.disappearingMessages,
            onChanged: (v) => _patch(ref, {'disappearing_messages': v}),
          ),
          ListTile(
            title: const Text('Wallpaper style',
                style: TextStyle(fontWeight: FontWeight.w800)),
            trailing: DropdownButton<String>(
              value: s.wallpaperStyle,
              items: const [
                DropdownMenuItem(value: 'gradient', child: Text('Gradient')),
                DropdownMenuItem(value: 'photo', child: Text('Photo')),
              ],
              onChanged: (v) {
                if (v != null) _patch(ref, {'wallpaper_style': v});
              },
            ),
          ),
          ListTile(
            title: const Text('Slow mode',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(s.slowModeSeconds == 0
                ? 'Off'
                : '${s.slowModeSeconds}s between messages'),
            trailing: DropdownButton<int>(
              value: s.slowModeSeconds,
              items: const [
                DropdownMenuItem(value: 0, child: Text('Off')),
                DropdownMenuItem(value: 10, child: Text('10s')),
                DropdownMenuItem(value: 30, child: Text('30s')),
                DropdownMenuItem(value: 60, child: Text('60s')),
              ],
              onChanged: (v) {
                if (v != null) _patch(ref, {'slow_mode_seconds': v});
              },
            ),
          ),
          const Divider(height: 24),
          SwitchListTile(
            title: const Text('Daily check-in ritual',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text(
                'Plug posts a morning question automatically (UTC hour)'),
            value: s.dailyCheckinEnabled,
            onChanged: (v) => _patch(ref, {'daily_checkin_enabled': v}),
          ),
          if (s.dailyCheckinEnabled) ...[
            ListTile(
              title: const Text('Check-in hour (UTC)',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              trailing: DropdownButton<int>(
                value: s.dailyCheckinHour.clamp(0, 23),
                items: [
                  for (var h = 6; h <= 14; h++)
                    DropdownMenuItem(
                      value: h,
                      child: Text('${h.toString().padLeft(2, '0')}:00 UTC'),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) _patch(ref, {'daily_checkin_hour': v});
                },
              ),
            ),
            ListTile(
              title: const Text('Check-in prompt',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(s.dailyCheckinPrompt),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () =>
                  _editCheckinPrompt(context, ref, s.dailyCheckinPrompt),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _patch(WidgetRef ref, Map<String, dynamic> patch) async {
    await ref.read(repositoryProvider).setTribeChatSettings(
          tribeId: tribe.tribeId,
          patch: patch,
        );
    ref.invalidate(tribeBySlugProvider(tribe.slug));
  }

  Future<void> _editCheckinPrompt(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => ModalTextControllerScope(
        initialValues: [current],
        builder: (ctx, controllers) => AlertDialog(
          title: const Text('Daily check-in prompt'),
          content: TextField(
            controller: controllers.single,
            maxLines: 2,
            maxLength: 200,
            decoration: const InputDecoration(
              hintText: 'How is everyone feeling today?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controllers.single.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (updated == null || updated.isEmpty) return;
    await _patch(ref, {'daily_checkin_prompt': updated});
  }
}

class _PromptComposer extends ConsumerStatefulWidget {
  const _PromptComposer({required this.tribeId});
  final String tribeId;

  @override
  ConsumerState<_PromptComposer> createState() => _PromptComposerState();
}

class _PromptComposerState extends ConsumerState<_PromptComposer> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.length < 4) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).schedulePrompt(
            tribeId: widget.tribeId,
            text: text,
          );
      ref.invalidate(tribePromptsProvider(widget.tribeId));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'New group prompt',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'What should members reflect on today?',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Post prompt',
                    style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }
}
