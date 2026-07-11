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

bool _showStudio(WidgetRef ref) {
  final memberView = ref.watch(keeperMemberViewProvider);
  if (memberView) return false;
  return ref.watch(isKeeperProvider).valueOrNull ?? false;
}
