import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../screens/compose/compose_screen.dart';
import '../screens/feed/feed_screen.dart';
import '../screens/feed/post_detail_screen.dart';
import '../screens/friends/friend_profile_screen.dart';
import '../screens/friends/friends_screen.dart';
import '../screens/home/home_shell.dart';
import '../screens/inbox/chat_screen.dart';
import '../screens/inbox/inbox_screen.dart';
import '../screens/onboarding/identity_screen.dart';
import '../screens/onboarding/recover_screen.dart';
import '../screens/onboarding/recovery_key_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/onboarding/welcome_screen.dart';
import '../screens/plugz/plug_profile_screen.dart';
import '../screens/profile/avatar_builder_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/questions/questions_screen.dart';
import '../screens/share/share_card_screen.dart';
import '../screens/tribes/create_tribe_screen.dart';
import '../screens/tribes/edit_tribe_screen.dart';
import '../screens/tribes/tribe_detail_screen.dart';
import '../screens/tribes/tribe_manage_screen.dart';
import '../screens/tribes/tribe_reports_screen.dart';
import '../screens/tribes/tribes_directory_screen.dart';

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
      GoRoute(
        path: '/onboarding/identity',
        builder: (_, __) => const IdentityScreen(),
      ),
      GoRoute(
        path: '/onboarding/key',
        builder: (ctx, st) =>
            RecoveryKeyScreen(phrase: (st.extra as String?) ?? ''),
      ),
      GoRoute(path: '/onboarding/recover', builder: (_, __) => const RecoverScreen()),

      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/feed',      builder: (_, __) => const FeedScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/tribes',    builder: (_, __) => const TribesDirectoryScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/compose',   builder: (_, __) => const ComposeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/questions', builder: (_, __) => const QuestionsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/inbox',     builder: (_, __) => const InboxScreen()),
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
        path: '/tribe/:slug',
        builder: (ctx, st) =>
            TribeDetailScreen(slug: st.pathParameters['slug']!),
        routes: [
          GoRoute(
            path: 'manage',
            builder: (ctx, st) =>
                TribeManageScreen(slug: st.pathParameters['slug']!),
            routes: [
              GoRoute(
                path: 'reports',
                builder: (ctx, st) => TribeReportsScreen(
                    slug: st.pathParameters['slug']!),
              ),
              GoRoute(
                path: 'edit',
                builder: (ctx, st) =>
                    EditTribeScreen(slug: st.pathParameters['slug']!),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/tribes/new',
        builder: (_, __) => const CreateTribeScreen(),
      ),
      GoRoute(
        path: '/chat/:roomId',
        builder: (ctx, st) => ChatScreen(roomId: st.pathParameters['roomId']!),
      ),
      GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
      GoRoute(
        path: '/profile/avatar',
        builder: (_, __) => const AvatarBuilderScreen(),
      ),
      GoRoute(path: '/friends', builder: (_, __) => const FriendsScreen()),
      GoRoute(
        path: '/user/:userId',
        builder: (ctx, st) =>
            FriendProfileScreen(userId: st.pathParameters['userId']!),
      ),
      GoRoute(
        path: '/notifications',
        builder: (_, __) => const NotificationsScreen(),
      ),
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
