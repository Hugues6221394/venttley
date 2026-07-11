import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../theme/motion.dart';
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
    _Tab(Icons.home_outlined, Icons.home_rounded, 'Home', branchIndex: 0),
    _Tab(Icons.graphic_eq_outlined, Icons.graphic_eq_rounded, 'Whispers',
        branchIndex: 1),
    _Tab(Icons.add_rounded, Icons.add_rounded, 'Post', isPost: true),
    _Tab(Icons.people_alt_outlined, Icons.people_alt_rounded, 'Connections',
        pushRoute: '/friends'),
    _Tab(Icons.mail_outline_rounded, Icons.mail_rounded, 'Inbox',
        branchIndex: 3),
    _Tab(Icons.person_outline, Icons.person, 'Profile', branchIndex: 4),
  ];

  static const _keeperTabs = [
    _Tab(Icons.dashboard_outlined, Icons.dashboard_rounded, 'Studio',
        branchIndex: 0),
    _Tab(Icons.view_agenda_outlined, Icons.view_agenda_rounded, 'Spaces',
        branchIndex: 1),
    _Tab(Icons.add_rounded, Icons.add_rounded, 'Create', isPost: true),
    _Tab(Icons.groups_outlined, Icons.groups_rounded, 'Members',
        branchIndex: 3),
    _Tab(Icons.forum_outlined, Icons.forum_rounded, 'Chat',
        isTribeChat: true),
    _Tab(Icons.insights_outlined, Icons.insights_rounded, 'Analytics',
        branchIndex: 4),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isKeeper = ref.watch(isKeeperProvider).valueOrNull ?? false;
    final memberView = ref.watch(keeperMemberViewProvider);
    final studioMode = isKeeper && !memberView;
    final tabs = studioMode ? _keeperTabs : _memberTabs;

    return Scaffold(
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: _GlassNavBar(
        tabs: tabs,
        currentBranch: navigationShell.currentIndex,
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

/// Floating frosted pill with a raised gradient Post button in the middle.
class _GlassNavBar extends ConsumerWidget {
  const _GlassNavBar({
    required this.tabs,
    required this.currentBranch,
    required this.onTapTab,
  });

  final List<_Tab> tabs;
  final int currentBranch;
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

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            decoration: BoxDecoration(
              color: (isDark ? VentlyColors.cardDark : Colors.white)
                  .withOpacity(isDark ? 0.72 : 0.62),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: (isDark ? Colors.white : Colors.white)
                    .withOpacity(isDark ? 0.10 : 0.70),
              ),
              boxShadow: [
                BoxShadow(
                  color: VentlyColors.berryMagenta
                      .withOpacity(isDark ? 0.18 : 0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
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
                            selected: tab.branchIndex != null &&
                                tab.branchIndex == currentBranch,
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
        : scheme.onSurface.withOpacity(isDark ? 0.55 : 0.50);
    return Pressable(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: VentlyMotion.base,
                curve: VentlyMotion.enter,
                width: 38,
                height: 34,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withOpacity(0.14)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Icon(
                  selected ? tab.activeIcon : tab.icon,
                  color: color,
                  size: 21,
                ),
              ),
              if (badge != null)
                Positioned(
                  right: -3,
                  top: -3,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    constraints:
                        const BoxConstraints(minWidth: 17, minHeight: 17),
                    decoration: BoxDecoration(
                      gradient: VentlyGradients.brand,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? VentlyColors.cardDark : Colors.white,
                        width: 1.6,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      badge! > 99 ? '99+' : '$badge',
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 1),
          Text(
            tab.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
              color: color,
            ),
          ),
          AnimatedContainer(
            duration: VentlyMotion.base,
            curve: VentlyMotion.enter,
            margin: const EdgeInsets.only(top: 2),
            width: selected ? 10 : 0,
            height: 3,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
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
    return Pressable(
      onTap: onTap,
      pressedScale: 0.90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.translate(
            offset: const Offset(0, -12),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                gradient: VentlyGradients.brand,
                shape: BoxShape.circle,
                border:
                    Border.all(color: Colors.white.withOpacity(0.8), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFC01A5B).withOpacity(0.45),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child:
                  const Icon(Icons.add_rounded, color: Colors.white, size: 28),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -12),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                color: VentlyColors.berryMagenta,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
