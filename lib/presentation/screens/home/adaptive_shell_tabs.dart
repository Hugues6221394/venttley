import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../inbox/inbox_screen.dart';
import '../profile/profile_screen.dart';
import '../whispers/whispers_screen.dart';
import 'home_tab_screen.dart';
import 'keeper_analytics_screen.dart';
import 'keeper_members_screen.dart';
import 'keeper_spaces_screen.dart';

/// Role-aware shell tab — renders Keeper Studio surfaces for Plugs/Keepers
/// and the consumer app for everyone else.
class AdaptiveHomeTab extends ConsumerWidget {
  const AdaptiveHomeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const HomeTabScreen();
  }
}

class AdaptiveWhispersTab extends ConsumerWidget {
  const AdaptiveWhispersTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_showStudio(ref)) return const KeeperSpacesScreen();
    return const WhispersScreen();
  }
}

class AdaptiveInboxTab extends ConsumerWidget {
  const AdaptiveInboxTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_showStudio(ref)) return const KeeperMembersScreen();
    return const InboxScreen();
  }
}

class AdaptiveProfileTab extends ConsumerWidget {
  const AdaptiveProfileTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_showStudio(ref)) return const KeeperAnalyticsScreen();
    return const ProfileScreen();
  }
}

/// Whether the shell is currently showing Studio surfaces rather than the
/// consumer app.
///
/// Public because callers outside the shell need to know what the profile tab
/// actually contains before sending someone to it: for a keeper that slot holds
/// the analytics, so "go to my profile" has to push /profile/me, while for
/// everyone else the tab *is* the profile and pushing a copy would be a loop.
/// One function so the answer cannot drift from what the tabs render.
bool showsStudioSurfaces(WidgetRef ref) => _showStudio(ref);

bool _showStudio(WidgetRef ref) {
  final memberView = ref.watch(keeperMemberViewProvider);
  if (memberView) return false;
  return ref.watch(isKeeperProvider).valueOrNull ?? false;
}
