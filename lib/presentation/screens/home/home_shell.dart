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
    _Tab(Icons.people_alt_outlined, Icons.people_alt_rounded, 'Friends',
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
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              // Layered translucent gradient reads as frosted glass with a
              // brighter top edge catching the light.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        VentlyColors.cardDark.withOpacity(0.80),
                        VentlyColors.cardDark.withOpacity(0.66),
                      ]
                    : [
                        Colors.white.withOpacity(0.78),
                        Colors.white.withOpacity(0.52),
                      ],
              ),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: Colors.white.withOpacity(isDark ? 0.12 : 0.75),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: VentlyColors.berryMagenta
                      .withOpacity(isDark ? 0.22 : 0.14),
                  blurRadius: 30,
                  spreadRadius: -4,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.30 : 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
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
    // Icons-only footer (IG / X style). The selected tab reads through a
    // tinted glass pill + soft berry glow instead of a text label.
    final color = selected
        ? scheme.primary
        : scheme.onSurface.withOpacity(isDark ? 0.62 : 0.55);
    return Pressable(
      onTap: onTap,
      child: Semantics(
        label: tab.label,
        button: true,
        selected: selected,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: VentlyMotion.base,
                curve: VentlyMotion.enter,
                width: 52,
                height: 44,
                decoration: BoxDecoration(
                  gradient: selected
                      ? LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            scheme.primary.withOpacity(0.22),
                            scheme.primary.withOpacity(0.10),
                          ],
                        )
                      : null,
                  borderRadius: BorderRadius.circular(16),
                  border: selected
                      ? Border.all(
                          color: scheme.primary.withOpacity(0.28), width: 1)
                      : null,
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: scheme.primary.withOpacity(0.22),
                            blurRadius: 14,
                            spreadRadius: -2,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: AnimatedScale(
                  duration: VentlyMotion.base,
                  curve: VentlyMotion.enter,
                  scale: selected ? 1.08 : 1.0,
                  child: Icon(
                    selected ? tab.activeIcon : tab.icon,
                    color: color,
                    size: 24,
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  right: 8,
                  top: 2,
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
      label: label,
      button: true,
      child: Pressable(
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
        ],
      ),
      ),
    );
  }
}
