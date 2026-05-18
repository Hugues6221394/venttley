import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../screens/compose/compose_screen.dart';
import '../screens/feed/feed_screen.dart';
import '../screens/feed/post_detail_screen.dart';
import '../screens/home/home_shell.dart';
import '../screens/inbox/chat_screen.dart';
import '../screens/inbox/inbox_screen.dart';
import '../screens/onboarding/identity_screen.dart';
import '../screens/onboarding/recover_screen.dart';
import '../screens/onboarding/recovery_key_screen.dart';
import '../screens/onboarding/welcome_screen.dart';
import '../screens/plugz/plug_profile_screen.dart';
import '../screens/plugz/plugz_directory_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/share/share_card_screen.dart';
import '../screens/spaces/spaces_discovery_screen.dart';
import '../screens/voice/voice_record_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/onboarding',
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final path = state.matchedLocation;
      final onboardingRoute = path.startsWith('/onboarding');
      if (session == null && !onboardingRoute) return '/onboarding';
      if (session != null && path == '/onboarding') return '/feed';
      return null;
    },
    refreshListenable: GoRouterRefreshStream(ref),
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const WelcomeScreen()),
      GoRoute(path: '/onboarding/identity', builder: (_, __) => const IdentityScreen()),
      GoRoute(path: '/onboarding/key', builder: (_, __) => const RecoveryKeyScreen()),
      GoRoute(path: '/onboarding/recover', builder: (_, __) => const RecoverScreen()),

      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/feed',     builder: (_, __) => const FeedScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/plugz',    builder: (_, __) => const PlugzDirectoryScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/compose',  builder: (_, __) => const ComposeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/inbox',    builder: (_, __) => const InboxScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/profile',  builder: (_, __) => const ProfileScreen()),
          ]),
        ],
      ),

      GoRoute(
        path: '/post/:id',
        builder: (ctx, st) => PostDetailScreen(postId: st.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'share',
            builder: (ctx, st) =>
                ShareCardScreen(postId: st.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/plug/:name',
        builder: (ctx, st) => PlugProfileScreen(
          displayName: Uri.decodeComponent(st.pathParameters['name']!),
        ),
      ),
      GoRoute(
        path: '/chat/:roomId',
        builder: (ctx, st) => ChatScreen(roomId: st.pathParameters['roomId']!),
      ),
      GoRoute(path: '/voice', builder: (_, __) => const VoiceRecordScreen()),
      GoRoute(path: '/discover', builder: (_, __) => const SpacesDiscoveryScreen()),
    ],
  );
});

/// Bridges Riverpod's session state changes into GoRouter's
/// `refreshListenable` so the redirect re-evaluates immediately on
/// login / logout.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(this.ref) {
    ref.listen(sessionProvider, (_, __) => notifyListeners());
  }
  final Ref ref;
}
