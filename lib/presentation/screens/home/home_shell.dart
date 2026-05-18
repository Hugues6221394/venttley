import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../theme/colors.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const _tabs = [
    _Tab('/feed',    Icons.home_outlined,        Icons.home_rounded,       'Feed'),
    _Tab('/plugz',   Icons.diversity_3_outlined, Icons.diversity_3,        'Plugz'),
    _Tab('/compose', Icons.add_circle_outline,   Icons.add_circle,         'Post'),
    _Tab('/inbox',   Icons.notifications_none,   Icons.notifications,      'Inbox'),
    _Tab('/profile', Icons.person_outline,       Icons.person,             'Profile'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: _CustomNavBar(
        current: navigationShell.currentIndex,
        onTap: (i) => navigationShell.goBranch(i, initialLocation: i == navigationShell.currentIndex),
      ),
    );
  }
}

class _Tab {
  final String route;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _Tab(this.route, this.icon, this.activeIcon, this.label);
}

class _CustomNavBar extends StatelessWidget {
  const _CustomNavBar({required this.current, required this.onTap});
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? VentlyColors.cardDark : Colors.white,
        border: Border(
          top: BorderSide(
            color: scheme.onSurface.withOpacity(0.06),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: List.generate(HomeShell._tabs.length, (i) {
              final tab = HomeShell._tabs[i];
              final selected = current == i;
              final isPost = tab.label == 'Post';
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: isPost ? 38 : 32,
                          height: isPost ? 38 : 32,
                          decoration: BoxDecoration(
                            color: isPost
                                ? scheme.primary
                                : selected
                                    ? scheme.primary.withOpacity(0.14)
                                    : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            selected ? tab.activeIcon : tab.icon,
                            color: isPost
                                ? Colors.white
                                : selected
                                    ? scheme.primary
                                    : scheme.onSurface.withOpacity(0.6),
                            size: 22,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tab.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? scheme.primary
                                : scheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
