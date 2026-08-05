import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/notification_prefs.dart';
import '../../../core/providers.dart';
import '../../../data/services/moderation_service.dart';
import '../../theme/colors.dart';
import '../../widgets/blocked_accounts_sheet.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/recovery_phrase_dialog.dart';
import '../../widgets/vently_notification_bell.dart';

/// Account, appearance, privacy, and safety settings.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final themeMode = ref.watch(themeModeProvider);
    final blocks = ref.watch(myBlocksProvider).valueOrNull ?? const [];
    final notificationsOn = ref.watch(pushNotificationsEnabledProvider);
    final storyReplies =
        ref.watch(storyRepliesEnabledProvider).valueOrNull ?? true;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (me != null) ...[
            const _SectionHeader('Signed in as'),
            ListTile(
              leading: ProfileAvatar(
                avatarSeed: me.avatarSeed,
                label: me.anonymousPseudonym,
                profilePhotoUrl: me.profilePhotoUrl,
                size: 42,
              ),
              title: Text(
                me.anonymousPseudonym,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: ref.watch(keeperModeProvider).when(
                    data: (mode) => Text(
                      mode.label,
                      style:
                          TextStyle(color: scheme.onSurface.withOpacity(0.6)),
                    ),
                    loading: () => Text(
                      me.userRole == 'super_admin'
                          ? 'Super Admin'
                          : me.isPlug
                              ? 'Verified Plug'
                              : 'Member',
                      style:
                          TextStyle(color: scheme.onSurface.withOpacity(0.6)),
                    ),
                    error: (_, __) => Text(
                      me.userRole == 'super_admin'
                          ? 'Super Admin'
                          : me.isPlug
                              ? 'Verified Plug'
                              : 'Member',
                      style:
                          TextStyle(color: scheme.onSurface.withOpacity(0.6)),
                    ),
                  ),
            ),
          ],
          const _SectionHeader('Appearance'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(
              children: [
                for (final option in VentlyThemeMode.values) ...[
                  Expanded(
                    child: _AppearanceOption(
                      mode: option,
                      selected: themeMode == option,
                      onTap: () =>
                          ref.read(themeModeProvider.notifier).setMode(option),
                    ),
                  ),
                  if (option != VentlyThemeMode.values.last)
                    const SizedBox(width: 10),
                ],
              ],
            ),
          ),
          const _SectionHeader('Data & network'),
          SwitchListTile(
            secondary: const Icon(Icons.data_saver_on_rounded,
                color: VentlyColors.berryMagenta),
            title: const Text('Data Saver',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text(
                'Lighter images, no whisper autoplay, less prefetch'),
            activeColor: VentlyColors.berryMagenta,
            value: ref.watch(dataSaverProvider),
            onChanged: (v) =>
                ref.read(dataSaverProvider.notifier).setEnabled(v),
          ),
          const _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.face_retouching_natural_rounded,
                color: VentlyColors.berryMagenta),
            title: const Text('Avatar builder',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Colors, shape, and glow'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/profile/avatar'),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined,
                color: VentlyColors.berryMagenta),
            title: const Text('Password & security',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle:
                const Text('Password, recovery email, 2FA, active sessions'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/profile/password-security'),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined,
                color: VentlyColors.berryMagenta),
            title: const Text('Recovery phrase',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('View your 12-word backup key'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showRecoveryPhraseDialog(context, ref),
          ),
          if (me?.isPlug == true)
            ListTile(
              leading: const Icon(Icons.dashboard_customize_rounded,
                  color: VentlyColors.berryMagenta),
              title: const Text('Plug dashboard',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('Manage tribes, prompts, and reports'),
              trailing: const Icon(Icons.chevron_right_rounded),
              // Use go(), not push(): the keeper studio lives in the bottom-nav
              // shell branch. push() would stack a second copy of the branch
              // and duplicate its GlobalKeys (keyReservation assertion crash).
              // Also exit "member view" or /feed just shows the member feed.
              onTap: () {
                ref.read(keeperMemberViewProvider.notifier).state = false;
                context.go('/feed');
              },
            ),
          const _SectionHeader('Privacy'),
          SwitchListTile(
            secondary: const Icon(
              Icons.chat_bubble_outline_rounded,
              color: VentlyColors.berryMagenta,
            ),
            title: const Text(
              'Story replies',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              storyReplies
                  ? 'Friends can reply privately to your stories'
                  : 'No one can reply to your stories',
            ),
            activeColor: VentlyColors.berryMagenta,
            value: storyReplies,
            onChanged: (enabled) async {
              try {
                await ref
                    .read(storyRepliesEnabledProvider.notifier)
                    .setEnabled(enabled);
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not update story replies.'),
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.block_rounded,
                color: VentlyColors.berryMagenta),
            title: const Text('Blocked accounts',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(
              blocks.isEmpty ? 'No one blocked' : '${blocks.length} blocked',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showBlockedAccountsSheet(context),
          ),
          ListTile(
            leading: const VentlyNotificationBell(
              color: VentlyColors.berryMagenta,
            ),
            title: const Text('Notification alerts',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text(
              'Messages, friend requests, and reactions while Venttly is open',
            ),
            trailing: Switch.adaptive(
              value: notificationsOn,
              onChanged: (v) => ref
                  .read(pushNotificationsEnabledProvider.notifier)
                  .setEnabled(v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.inbox_outlined,
                color: VentlyColors.berryMagenta),
            title: const Text('Activity inbox',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Likes, replies, and friend activity'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded,
                color: VentlyColors.berryMagenta),
            title: const Text('Download my data',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Export everything you\'ve shared (JSON)'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _exportMyData(context, ref),
          ),
          const _SectionHeader('Safety'),
          ListTile(
            leading: const Icon(Icons.favorite_rounded,
                color: VentlyColors.berryMagenta),
            title: const Text('Crisis resources',
                style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Verified support contacts for Rwanda'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _showCrisisSheet(context),
          ),
          const _SectionHeader('Session'),
          ListTile(
            leading: Icon(Icons.logout_rounded,
                color: scheme.error.withOpacity(0.85)),
            title: Text(
              'Sign out',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: scheme.error.withOpacity(0.9),
              ),
            ),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Sign out?'),
                      content: const Text(
                        'You will need your username and password to sign back in.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!confirmed || !context.mounted) return;
              try {
                await ref.read(sessionProvider.notifier).logout();
              } catch (_) {
                // SessionController still clears local state in finally.
              }
              if (context.mounted) context.go('/onboarding');
            },
          ),
          if (me != null) ...[
            const _SectionHeader('Danger zone'),
            ListTile(
              leading: const Icon(Icons.pause_circle_outline_rounded,
                  color: VentlyColors.berryMagenta),
              title: const Text('Deactivate account',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text(
                'Hide your profile, vents, and whispers. Reappears when you '
                'log back in.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _confirmDeactivate(context, ref),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_rounded,
                  color: scheme.error.withOpacity(0.9)),
              title: Text(
                'Delete account',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.error.withOpacity(0.9),
                ),
              ),
              subtitle: const Text(
                'Schedule permanent deletion. You have 30 days to change your '
                'mind by logging back in.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _confirmDelete(context, ref),
            ),
          ],
          const SizedBox(height: 12),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) {
              final version = snap.data?.version ?? '—';
              final build = snap.data?.buildNumber ?? '';
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 116),
                child: Text(
                  'Venttly v$version${build.isEmpty ? '' : ' ($build)'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface.withOpacity(0.45),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeactivate(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Deactivate account?'),
            content: const Text(
              'Your profile, vents, whispers, and comments are hidden from '
              'everyone while deactivated. Nothing is deleted — just log back '
              'in anytime to restore your account exactly as it was.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Deactivate'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !context.mounted) return;
    try {
      await ref.read(sessionProvider.notifier).deactivateAccount();
      if (context.mounted) context.go('/onboarding');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not deactivate: $e')),
        );
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete account?'),
            content: const Text(
              'Your account is deactivated now and permanently deleted after '
              '30 days — including your vents, whispers, tribes, and messages. '
              'This cannot be undone once the 30 days pass.\n\n'
              'Change your mind? Just log back in within 30 days and your '
              'account is fully restored.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep my account'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !context.mounted) return;
    try {
      await ref.read(sessionProvider.notifier).deleteAccount();
      if (context.mounted) context.go('/onboarding');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not schedule deletion: $e')),
        );
      }
    }
  }

  /// GDPR/CCPA export — pulls the caller's full data bundle and hands it to the
  /// system share sheet as a JSON file.
  Future<void> _exportMyData(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing your data…')),
    );
    try {
      final data = await ref.read(repositoryProvider).exportMyData();
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/venttly-data-$stamp.json');
      await file.writeAsString(json);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'My Venttly data',
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export your data: $e')),
      );
    }
  }

  void _showCrisisSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'You are not alone',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  color: context.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'If you are in immediate danger, contact emergency services. '
                'These Rwanda contacts can help you find appropriate support.',
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.7),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              for (final r in kCrisisResources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ctx.isDark ? ctx.glass() : VentlyColors.cardBlush,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: ctx.isDark
                            ? ctx.glassBorder
                            : VentlyColors.softMauve.withOpacity(0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.label,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          r.reach,
                          style: TextStyle(
                            color: Theme.of(ctx)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tile of the Light / Dark / Black appearance selector.
class _AppearanceOption extends StatelessWidget {
  const _AppearanceOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final VentlyThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label) = switch (mode) {
      VentlyThemeMode.light => (Icons.light_mode_rounded, 'Light'),
      VentlyThemeMode.dark => (Icons.dark_mode_rounded, 'Dark'),
      VentlyThemeMode.black => (Icons.contrast_rounded, 'Black'),
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color:
            selected ? scheme.primary.withOpacity(0.14) : context.glass(0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected ? scheme.primary : context.glassBorder,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: selected ? scheme.primary : context.inkMuted,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: selected ? scheme.primary : context.inkMuted,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary.withOpacity(0.85),
        ),
      ),
    );
  }
}
