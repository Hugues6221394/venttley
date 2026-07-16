import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../screens/compose/compose_screen.dart';
import '../screens/compose/create_story_screen.dart';
import '../screens/discover/discover_screen.dart';
import '../screens/home/adaptive_shell_tabs.dart';
import '../screens/feed/post_detail_screen.dart';
import '../screens/feed/story_viewer_screen.dart';
import '../screens/friends/friend_profile_screen.dart';
import '../screens/friends/friends_screen.dart';
import '../screens/home/home_shell.dart';
import '../screens/inbox/chat_screen.dart';
import '../screens/whispers/create_whisper_screen.dart';
import '../widgets/keep_alive.dart';
import '../screens/onboarding/email_signup_screen.dart';
import '../screens/onboarding/identity_screen.dart';
import '../screens/onboarding/recover_screen.dart';
import '../screens/onboarding/recovery_key_screen.dart';
import '../screens/onboarding/phone_signin_screen.dart';
import '../screens/onboarding/verify_email_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/onboarding/welcome_screen.dart';
import '../screens/plugz/plug_profile_screen.dart';
import '../screens/profile/avatar_builder_screen.dart';
import '../screens/profile/edit_profile_screen.dart';
import '../screens/profile/profile_stat_detail_screen.dart';
import '../screens/profile/security_screen.dart';
import '../screens/profile/password_security_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/questions/questions_screen.dart';
import '../screens/share/share_card_screen.dart';
import '../screens/tribes/create_tribe_screen.dart';
import '../screens/tribes/edit_tribe_screen.dart';
import '../screens/tribes/tribe_chat_screen.dart';
import '../screens/tribes/tribe_chat_hub_screen.dart';
import '../screens/tribes/tribe_detail_screen.dart';
import '../screens/tribes/space_home_screen.dart';
import '../screens/tribes/tribe_manage_screen.dart';
import '../screens/tribes/tribe_moderation_screen.dart';
import '../screens/tribes/tribe_reports_screen.dart';
import '../screens/tribes/tribes_directory_screen.dart';
import '../screens/keeper/keeper_moderation_center_screen.dart';
import '../screens/keeper/keeper_engagement_calendar_screen.dart';
import '../screens/keeper/keeper_comod_screen.dart';
import '../screens/keeper/keeper_insights_screen.dart';

/// Root navigator — routes registered here render ABOVE the bottom-nav
/// shell (chat boxes, full-screen creators/viewers, onboarding).
final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
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
      GoRoute(
          path: '/onboarding/recover',
          builder: (_, __) => const RecoverScreen()),
      GoRoute(
        path: '/onboarding/email',
        builder: (_, __) => const EmailSignupScreen(),
      ),
      GoRoute(
        path: '/onboarding/phone',
        builder: (_, __) => const PhoneSignInScreen(),
      ),

      // Bottom-nav shell. Five stateful branches plus the Friends shortcut:
      // Home / Whispers / Post / Friends / Inbox / Profile. Social apps keep
      // the footer nav on nearly every screen,
      // so the browse/detail routes live INSIDE the branches (nav stays
      // visible). Only chat boxes, full-screen creators/viewers and
      // onboarding escape to the root navigator via [rootNavigatorKey].
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          // ── Home + all browse/detail surfaces ─────────────────────────
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/feed',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveHomeTab())),
            GoRoute(
                path: '/friends', builder: (_, __) => const FriendsScreen()),
            GoRoute(
                path: '/discover', builder: (_, __) => const DiscoverScreen()),
            GoRoute(
                path: '/tribes',
                builder: (_, __) => const TribesDirectoryScreen()),
            GoRoute(
              path: '/post/:id',
              builder: (ctx, st) {
                final postId = st.pathParameters['id']!;
                final extra = st.extra;
                return PostDetailScreen(
                  postId: postId,
                  initialPost:
                      extra is Post && extra.postId == postId ? extra : null,
                );
              },
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
              path: '/keeper/moderation',
              builder: (_, __) => const KeeperModerationCenterScreen(),
            ),
            GoRoute(
              path: '/keeper/calendar',
              builder: (_, __) => const KeeperEngagementCalendarScreen(),
            ),
            GoRoute(
              path: '/keeper/comod',
              builder: (_, __) => const KeeperComodScreen(),
            ),
            GoRoute(
              path: '/keeper/insights',
              builder: (_, __) => const KeeperInsightsScreen(),
            ),
            GoRoute(
              path: '/tribe/:slug',
              builder: (ctx, st) =>
                  TribeDetailScreen(slug: st.pathParameters['slug']!),
              routes: [
                GoRoute(
                  path: 'chat',
                  // Chat boxes hide the footer nav — best-practice UX.
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (ctx, st) => TribeChatScreen(
                    slug: st.pathParameters['slug']!,
                    scrollToMessageId: st.uri.queryParameters['message'],
                  ),
                  routes: [
                    GoRoute(
                      path: 'hub',
                      parentNavigatorKey: rootNavigatorKey,
                      builder: (ctx, st) =>
                          TribeChatHubScreen(slug: st.pathParameters['slug']!),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'space/:spaceId',
                  builder: (ctx, st) =>
                      SpaceHomeScreen(spaceId: st.pathParameters['spaceId']!),
                ),
                GoRoute(
                  path: 'manage',
                  builder: (ctx, st) =>
                      TribeManageScreen(slug: st.pathParameters['slug']!),
                  routes: [
                    GoRoute(
                      path: 'reports',
                      builder: (ctx, st) =>
                          TribeReportsScreen(slug: st.pathParameters['slug']!),
                    ),
                    GoRoute(
                      path: 'moderation',
                      builder: (ctx, st) => TribeModerationScreen(
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
                path: '/questions',
                builder: (_, __) => const QuestionsScreen()),
            GoRoute(
              path: '/user/:userId',
              builder: (ctx, st) =>
                  FriendProfileScreen(userId: st.pathParameters['userId']!),
              routes: [
                GoRoute(
                  path: 'stat/:statKind',
                  builder: (ctx, st) => ProfileStatDetailScreen(
                    userId: st.pathParameters['userId']!,
                    statKind: st.pathParameters['statKind']!,
                  ),
                ),
              ],
            ),
            GoRoute(
              path: '/notifications',
              builder: (_, __) => const NotificationsScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/whispers',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveWhispersTab())),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/compose',
                builder: (ctx, st) => ComposeScreen(
                      queryParams: st.uri.queryParameters,
                    )),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/inbox',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveInboxTab())),
          ]),
          // ── Profile + its sub-pages ───────────────────────────────────
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/profile',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveProfileTab())),
            GoRoute(
              path: '/profile/avatar',
              builder: (_, __) => const AvatarBuilderScreen(),
            ),
            GoRoute(
              path: '/profile/edit',
              builder: (_, __) => const EditProfileScreen(),
            ),
            GoRoute(
              path: '/profile/security',
              builder: (_, __) => const SecurityScreen(),
            ),
            GoRoute(
              path: '/profile/password-security',
              builder: (_, __) => const PasswordSecurityScreen(),
            ),
            GoRoute(
              path: '/settings',
              builder: (_, __) => const SettingsScreen(),
            ),
          ]),
        ],
      ),

      GoRoute(
        path: '/verify-email',
        builder: (_, st) =>
            VerifyEmailScreen(email: st.uri.queryParameters['email']),
      ),
      GoRoute(
        path: '/whisper/:id',
        redirect: (_, state) =>
            '/whispers?whisper=${state.pathParameters['id']}',
      ),
      GoRoute(
        path: '/plug-dashboard',
        redirect: (_, __) => '/feed',
      ),
      // DM chat box — root navigator, no footer nav inside conversations.
      GoRoute(
        path: '/chat/:roomId',
        builder: (ctx, st) => ChatScreen(roomId: st.pathParameters['roomId']!),
      ),
      // Full-screen creators + story viewer stay immersive.
      GoRoute(
        path: '/compose/story',
        builder: (_, __) => const CreateStoryScreen(),
      ),
      GoRoute(
        path: '/whispers/new',
        builder: (_, __) => const CreateWhisperScreen(),
      ),
      GoRoute(
        path: '/story/:postId',
        builder: (ctx, st) =>
            StoryViewerScreen(initialPostId: st.pathParameters['postId']!),
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
