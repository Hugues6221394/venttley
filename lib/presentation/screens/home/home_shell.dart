import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../theme/motion.dart';
import '../../widgets/connection_banner.dart';
import '../../widgets/keeper_content_studio_sheet.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/quick_create_sheet.dart';

/// Bottom-nav shell — role-aware, floating glass pill per the launch mockups.
///
/// **Members:** Home · Whispers · [Post] · Friends · Inbox · Profile
/// **Keepers:** Studio · Spaces · [Create] · Members · Analytics
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const _memberTabs = [
    _Tab(CupertinoIcons.house, CupertinoIcons.house_fill, 'Home',
        branchIndex: 0),
    _Tab(CupertinoIcons.waveform, CupertinoIcons.waveform, 'Whispers',
        branchIndex: 1),
    _Tab(Icons.add_rounded, Icons.add_rounded, 'Post', isPost: true),
    _Tab(CupertinoIcons.person_2, CupertinoIcons.person_2_fill, 'Friends',
        pushRoute: '/friends'),
    _Tab(CupertinoIcons.chat_bubble, CupertinoIcons.chat_bubble_fill, 'Inbox',
        branchIndex: 3),
    _Tab(CupertinoIcons.person, CupertinoIcons.person_fill, 'Profile',
        branchIndex: 4),
  ];

  /// Public for navigation contract tests and accessibility audits.
  static List<String> get memberDestinationLabels =>
      List.unmodifiable(_memberTabs.map((tab) => tab.label));

  static const _keeperTabs = [
    _Tab(Icons.dashboard_outlined, Icons.dashboard_rounded, 'Studio',
        branchIndex: 0),
    _Tab(Icons.view_agenda_outlined, Icons.view_agenda_rounded, 'Spaces',
        branchIndex: 1),
    _Tab(Icons.add_rounded, Icons.add_rounded, 'Create', isPost: true),
    _Tab(Icons.groups_outlined, Icons.groups_rounded, 'Members',
        branchIndex: 3),
    _Tab(Icons.forum_outlined, Icons.forum_rounded, 'Chat', isTribeChat: true),
    _Tab(Icons.insights_outlined, Icons.insights_rounded, 'Analytics',
        branchIndex: 4),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isKeeper = ref.watch(isKeeperProvider).valueOrNull ?? false;
    final memberView = ref.watch(keeperMemberViewProvider);
    final studioMode = isKeeper && !memberView;
    final tabs = studioMode ? _keeperTabs : _memberTabs;
    final currentPath = GoRouterState.of(context).uri.path;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          navigationShell,
          // Floats over content so it never shifts layout; SafeArea inside.
          const Positioned(
              top: 0, left: 0, right: 0, child: ConnectionBanner()),
        ],
      ),
      bottomNavigationBar: _GlassNavBar(
        tabs: tabs,
        currentBranch: navigationShell.currentIndex,
        currentPath: currentPath,
        onTapTab: (tab) {
          if (tab.isPost) {
            if (studioMode) {
              showKeeperContentStudioSheet(context, ref);
            } else {
              showQuickCreateSheet(context, ref);
            }
            return;
          }
          if (tab.isTribeChat) {
            final tribe = ref.read(primaryKeeperTribeProvider);
            if (tribe != null) {
              context.push('/tribe/${tribe.slug}/chat');
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Create a tribe first.')),
              );
            }
            return;
          }
          if (tab.pushRoute != null) {
            context.push(tab.pushRoute!);
            return;
          }
          navigationShell.goBranch(
            tab.branchIndex!,
            initialLocation: tab.branchIndex == navigationShell.currentIndex,
          );
        },
      ),
    );
  }
}

class _Tab {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  /// Shell branch this tab activates; null for action/push tabs.
  final int? branchIndex;

  /// Route pushed on top of the shell (e.g. Friends).
  final String? pushRoute;

  /// The raised gradient create button.
  final bool isPost;

  /// Opens the plug's primary tribe group chat (dynamic slug, resolved at tap).
  final bool isTribeChat;

  const _Tab(
    this.icon,
    this.activeIcon,
    this.label, {
    this.branchIndex,
    this.pushRoute,
    this.isPost = false,
    this.isTribeChat = false,
  });
}

/// Quiet floating navigation with a raised compose button in the middle.
class _GlassNavBar extends ConsumerWidget {
  const _GlassNavBar({
    required this.tabs,
    required this.currentBranch,
    required this.currentPath,
    required this.onTapTab,
  });

  final List<_Tab> tabs;
  final int currentBranch;
  final String currentPath;
  final ValueChanged<_Tab> onTapTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final inboxBadge = ref.watch(navInboxBadgeCountProvider).valueOrNull ?? 0;
    final isKeeper = ref.watch(isKeeperProvider).valueOrNull ?? false;
    final memberView = ref.watch(keeperMemberViewProvider);
    final studioMode = isKeeper && !memberView;

    int? badgeFor(_Tab tab) {
      if (studioMode) return null;
      if (tab.label == 'Inbox' && inboxBadge > 0) return inboxBadge;
      return null;
    }

    bool selectedFor(_Tab tab) {
      final route = tab.pushRoute;
      if (route != null) return currentPath.startsWith(route);
      if (tab.branchIndex == 0 && currentPath.startsWith('/friends')) {
        return false;
      }
      return tab.branchIndex != null && tab.branchIndex == currentBranch;
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: RepaintBoundary(
        key: const Key('member-bottom-navigation'),
        child: Container(
          height: 78,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? scheme.surface : const Color(0xFFFFFEFF),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.10)
                  : VentlyColors.softMauve,
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color:
                    VentlyColors.berryMagenta.withOpacity(isDark ? 0.10 : 0.08),
                blurRadius: 28,
                spreadRadius: -10,
                offset: const Offset(0, 9),
              ),
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.24 : 0.05),
                blurRadius: 18,
                spreadRadius: -8,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              for (final tab in tabs)
                Expanded(
                  child: tab.isPost
                      ? _PostNavButton(
                          label: tab.label, onTap: () => onTapTab(tab))
                      : _NavItem(
                          tab: tab,
                          selected: selectedFor(tab),
                          badge: badgeFor(tab),
                          scheme: scheme,
                          isDark: isDark,
                          onTap: () => onTapTab(tab),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.badge,
    required this.scheme,
    required this.isDark,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final int? badge;
  final ColorScheme scheme;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? scheme.primary
        : scheme.onSurface.withOpacity(isDark ? 0.62 : 0.55);
    return Pressable(
      onTap: onTap,
      child: Semantics(
        key: ValueKey('member-nav-${tab.label.toLowerCase()}'),
        label: tab.label,
        button: true,
        selected: selected,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 50,
                height: 50,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedScale(
                      duration: VentlyMotion.fast,
                      curve: VentlyMotion.enter,
                      scale: selected ? 1.06 : 1,
                      child: Icon(
                        selected ? tab.activeIcon : tab.icon,
                        color: color,
                        size: selected ? 28 : 27,
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedContainer(
                      duration: VentlyMotion.fast,
                      width: selected ? 6 : 0,
                      height: selected ? 6 : 0,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null)
                Positioned(
                  right: 8,
                  top: 2,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    constraints:
                        const BoxConstraints(minWidth: 19, minHeight: 19),
                    decoration: BoxDecoration(
                      gradient: VentlyGradients.brand,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? Theme.of(context).colorScheme.surface
                            : Colors.white,
                        width: 1.8,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      badge! > 99 ? '99+' : '$badge',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
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

/// Raised gradient create button — lifts above the pill like the mockup.
class _PostNavButton extends StatelessWidget {
  const _PostNavButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('member-nav-post'),
      label: label,
      button: true,
      child: Pressable(
        onTap: onTap,
        pressedScale: 0.90,
        child: Transform.translate(
          offset: const Offset(0, -11),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 54, maxHeight: 54),
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: VentlyGradients.brand,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.surface,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: VentlyColors.berryMagenta.withOpacity(0.30),
                        blurRadius: 24,
                        spreadRadius: -5,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    color: Colors.white,
                    size: 31,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
