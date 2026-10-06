import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../screens/compose/compose_screen.dart';
import '../screens/compose/create_story_screen.dart';
import '../screens/profile/avatar_picker_screen.dart';
import '../screens/profile/personas_screen.dart';
import '../screens/discover/discover_screen.dart';
import '../screens/home/adaptive_shell_tabs.dart';
import '../screens/feed/post_detail_screen.dart';
import '../screens/feed/story_viewer_screen.dart';
import '../screens/friends/friend_profile_screen.dart';
import '../screens/friends/friends_screen.dart';
import '../screens/home/home_shell.dart';
import '../screens/inbox/chat_screen.dart';
import '../screens/inbox/create_group_chat_screen.dart';
import '../screens/inbox/group_chat_settings_screen.dart';
import '../screens/inbox/group_invite_screen.dart';
import '../screens/whispers/create_whisper_screen.dart';
import '../widgets/keep_alive.dart';
import '../widgets/tribe_age_gate.dart';
import '../screens/onboarding/email_signup_screen.dart';
import '../screens/onboarding/age_completion_screen.dart';
import '../screens/onboarding/identity_screen.dart';
import '../screens/onboarding/mfa_challenge_screen.dart';
import '../screens/onboarding/password_reset_screen.dart';
import '../screens/onboarding/recover_screen.dart';
import '../screens/onboarding/recovery_key_screen.dart';
import '../screens/onboarding/phone_signin_screen.dart';
import '../screens/onboarding/launching_screen.dart';
import '../screens/onboarding/personalise_screen.dart';
import '../screens/onboarding/policy_consent_screen.dart';
import '../screens/onboarding/policy_reader_screen.dart';
import '../screens/onboarding/verify_email_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/onboarding/welcome_screen.dart';
import '../screens/plugz/plug_profile_screen.dart';
import '../screens/profile/active_devices_screen.dart';
import '../screens/profile/avatar_studio_screen.dart';
import '../screens/profile/edit_profile_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/profile/profile_stat_detail_screen.dart';
import '../screens/profile/security_check_screen.dart';
import '../screens/profile/security_screen.dart';
import '../screens/profile/password_security_screen.dart';
import '../screens/settings/appeals_screen.dart';
import '../screens/settings/support_screen.dart';
import '../../domain/support/support_conversation.dart';
import '../screens/settings/feedback_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/settings/verification_screen.dart';
import '../screens/goals/goals_screen.dart';
import '../screens/questions/questions_screen.dart';
import '../screens/share/share_card_screen.dart';
import '../screens/tribes/create_tribe_screen.dart';
import '../screens/tribes/edit_tribe_screen.dart';
import '../screens/tribes/tribe_chat_screen.dart';
import '../screens/tribes/tribe_chat_hub_screen.dart';
import '../screens/tribes/tribe_audit_screen.dart';
import '../screens/tribes/tribe_content_management_screen.dart';
import '../screens/tribes/tribe_detail_screen.dart';
import '../screens/tribes/tribe_members_management_screen.dart';
import '../screens/tribes/space_home_screen.dart';
import '../screens/tribes/tribe_helpers_screen.dart';
import '../screens/tribes/tribe_manage_screen.dart';
import '../screens/tribes/tribe_moderation_screen.dart';
import '../screens/tribes/tribe_reports_screen.dart';
import '../screens/tribes/tribe_rules_editor_screen.dart';
import '../screens/tribes/tribe_settings_screen.dart';
import '../screens/tribes/tribe_spaces_management_screen.dart';
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
    // Every launch starts here, not on the welcome screen. Where somebody
    // belongs is not knowable until the session restore comes back, and
    // guessing "signed out" meanwhile showed a sign-up screen to people who
    // were already signed in.
    initialLocation: '/launching',
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final gate = ref.read(authGateProvider);
      final pendingMfa = ref.read(pendingMfaFactorIdProvider);
      final path = state.matchedLocation;
      final onboardingRoute = path.startsWith('/onboarding');
      // The policy documents are readable with no session at all. Somebody
      // has to be able to read the Terms while deciding whether to sign up,
      // and the signup screen links straight to them — without this they
      // would bounce to /onboarding and the consent links would be dead.
      final legalRoute = path.startsWith('/legal');
      final onMfa = path == '/onboarding/mfa';

      // The last two steps of creating an account: being shown the recovery
      // phrase, and being offered an avatar and a background.
      //
      // Both sit behind the email gate below, which was written to keep an
      // unverified address off the homepage. It kept it off these as well —
      // so somebody signing up with an email went straight from the form to
      // the verification screen and then to the feed, and was never shown the
      // recovery phrase that is the only way back into the account if the
      // password goes. Losing the background picker was the visible half of
      // that; losing the phrase was the serious half.
      //
      // Verification is required before the app, not before finishing signup.
      //
      // The consent gate below needs the same exemption, for a subtler reason.
      // Signup accepts the policies and then invalidates
      // outstandingPoliciesProvider — but invalidating refetches
      // asynchronously and keeps the previous value until the new one lands,
      // while context.go runs on the next line. So the gate read the
      // pre-acceptance answer, bounced /onboarding/key to the consent screen,
      // and consent — finding nothing outstanding by then — sent the user
      // straight to the feed. The recovery phrase was never shown.
      //
      // Consent is still enforced: if the acceptance write genuinely failed,
      // these two screens pass and /feed catches it.
      final finishingSignup =
          path == '/onboarding/key' ||
          path == '/onboarding/personalise' ||
          path == '/avatar/design';
      // Hold the splash only while we genuinely do not know — which means no
      // session AND no answer yet. A session arriving by any route lifts it
      // without that route having to remember to, which is what makes sign-in,
      // sign-up and the OAuth redirect all work without their own handling.
      //
      // The legal documents stay reachable throughout: somebody who followed a
      // link to the Terms should not wait on an auth check to read them.
      if (gate == AuthGate.restoring && session == null) {
        return legalRoute || path == '/launching' ? null : '/launching';
      }
      // And leave it the moment it is: the splash is a waiting room, not a
      // screen anybody should be able to sit on.
      if (path == '/launching') {
        return session == null ? '/onboarding' : '/feed';
      }
      if (pendingMfa != null && !onMfa && !legalRoute) {
        return '/onboarding/mfa';
      }
      if (session == null && !onboardingRoute && !legalRoute) {
        return '/onboarding';
      }
      if (session != null &&
          session.birthYear == null &&
          path != '/onboarding/age' &&
          !onMfa) {
        return '/onboarding/age';
      }
      if (session != null &&
          session.birthYear != null &&
          path == '/onboarding/age') {
        return '/feed';
      }
      // An unverified real email does not reach the app.
      //
      // Verification used to be a banner on the feed: you signed up with an
      // email, landed on the homepage, and were invited to confirm it from
      // there whenever you felt like it. So the address on the account was
      // unproven while the account was fully in use — and the one thing that
      // address is for is getting back in when the password is gone.
      //
      // Only real addresses. The anonymous flow signs in with a synthetic
      // @id.venttly.app handle that nobody can receive mail at, and gating
      // those would lock out the entire pseudonymous path, which is the app's
      // default and its whole point.
      //
      // After the age gate and before consent, because an account with no
      // birth year cannot be asked anything else yet, and because bouncing
      // somebody between two gates is worse than either.
      if (session != null &&
          session.birthYear != null &&
          !session.emailVerified &&
          path != '/verify-email' &&
          !legalRoute &&
          !onMfa &&
          !finishingSignup) {
        final notifier = ref.read(sessionProvider.notifier);
        if (notifier.hasRealEmail) {
          final email = notifier.currentEmail;
          return email == null
              ? '/verify-email'
              : '/verify-email?email=${Uri.encodeComponent(email)}';
        }
      }

      // Outstanding consent, which happens two ways: the acceptance write
      // failed after the account was created, or a policy version changed
      // materially and everybody owes a fresh agreement.
      //
      // `valueOrNull` on purpose. While the answer is still loading, or if it
      // could not be fetched at all, this is null and nobody is redirected —
      // an unknown answer must not lock somebody out of a mental-health app.
      // What makes consent trustworthy is that the acceptance row can only be
      // written by the server-side RPC, not that this gate is airtight.
      if (session != null &&
          session.birthYear != null &&
          !legalRoute &&
          path != '/onboarding/consent' &&
          !onMfa &&
          !finishingSignup) {
        final outstanding = ref.read(outstandingPoliciesProvider).valueOrNull;
        if (outstanding != null && !outstanding.isEmpty) {
          return '/onboarding/consent';
        }
      }
      if (session != null && path == '/onboarding/consent') {
        final outstanding = ref.read(outstandingPoliciesProvider).valueOrNull;
        if (outstanding != null && outstanding.isEmpty) return '/feed';
      }
      if (session != null && path == '/onboarding') return '/feed';
      return null;
    },
    refreshListenable: GoRouterRefreshStream(ref),
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(
        leading: context.canPop()
            ? IconButton(
                tooltip: 'Back',
                onPressed: context.pop,
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        title: const Text('Page unavailable'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded, size: 48),
              const SizedBox(height: 16),
              const Text(
                'We couldn\'t open this page.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              const Text(
                'The link may be old or the content may no longer be available.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () => context.go('/feed'),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Home'),
              ),
            ],
          ),
        ),
      ),
    ),
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const WelcomeScreen()),
      GoRoute(
        path: '/onboarding/age',
        builder: (_, __) => const AgeCompletionScreen(),
      ),
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
        builder: (_, __) => const RecoverScreen(),
      ),
      GoRoute(
        path: '/onboarding/reset-password',
        builder: (_, __) => const PasswordResetScreen(),
      ),
      GoRoute(
        path: '/onboarding/email',
        builder: (_, __) => const EmailSignupScreen(),
      ),
      // Top level, not under /onboarding, because these are also reached
      // from Settings by an account that signed up long ago — and they must
      // stay reachable without a session, since somebody has to be able to
      // read the Terms before deciding to create one.
      GoRoute(path: '/launching', builder: (_, __) => const LaunchingScreen()),
      GoRoute(
        path: '/onboarding/personalise',
        builder: (_, __) => const PersonaliseScreen(),
      ),
      // The studio again, outside the tab shell.
      //
      // /profile/avatar sits in the profile branch, so pushing it from signup
      // would mount the whole tabbed app underneath — a bottom navigation bar
      // appearing behind a screen somebody reaches before they have an
      // account is not a shell being clever, it is a signup flow leaking. The
      // persona editor is a bottom sheet and wants the same thing.
      //
      // ?persona=<id> designs that persona's face instead of the account's.
      GoRoute(
        path: '/avatar/design',
        builder: (ctx, st) =>
            AvatarStudioScreen(personaId: st.uri.queryParameters['persona']),
      ),
      GoRoute(
        path: '/onboarding/consent',
        builder: (_, __) => const PolicyConsentScreen(),
      ),
      GoRoute(
        path: '/settings/verification',
        builder: (_, __) => const VerificationScreen(),
      ),
      // Top level, not inside the shell: reachable from Settings, and from a
      // crash boundary if one ever links to it.
      GoRoute(
        path: '/settings/feedback',
        builder: (_, __) => const FeedbackScreen(),
      ),
      GoRoute(
        path: '/settings/appeals',
        builder: (_, __) => const AppealsScreen(),
      ),
      GoRoute(
        path: '/settings/support',
        builder: (_, __) => const SupportScreen(),
      ),
      GoRoute(
        path: '/settings/support/new',
        builder: (_, __) => const NewSupportScreen(),
      ),
      // ?conversation=<id> or ?message=<id> (a staff message not yet
      // answered). Anything else falls back to the list.
      GoRoute(
        path: '/settings/support/thread',
        builder: (_, st) {
          final q = st.uri.queryParameters;
          final conversation = q['conversation'], message = q['message'];
          if (isSupportId(conversation) && message == null) {
            return SupportThreadScreen(
              thread: SupportThreadRef(conversationId: conversation),
            );
          }
          if (isSupportId(message) && conversation == null) {
            return SupportThreadScreen(
              thread: SupportThreadRef(communicationId: message),
            );
          }
          return const SupportScreen();
        },
      ),
      GoRoute(
        path: '/legal/terms',
        builder: (_, __) => const PolicyReaderScreen(kind: 'terms'),
      ),
      GoRoute(
        path: '/legal/privacy',
        builder: (_, __) => const PolicyReaderScreen(kind: 'privacy'),
      ),
      GoRoute(
        path: '/onboarding/phone',
        builder: (_, __) => const PhoneSignInScreen(),
      ),
      GoRoute(
        path: '/onboarding/mfa',
        builder: (_, __) => const MfaChallengeScreen(),
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
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/feed',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveHomeTab()),
              ),
              GoRoute(
                path: '/friends',
                builder: (_, __) => const FriendsScreen(),
              ),
              GoRoute(
                path: '/discover',
                builder: (_, __) => const DiscoverScreen(),
              ),
              GoRoute(
                path: '/tribes',
                builder: (_, __) => const TribesDirectoryScreen(),
              ),
              GoRoute(
                path: '/post/:id',
                builder: (ctx, st) {
                  final postId = st.pathParameters['id']!;
                  final extra = st.extra;
                  return PostDetailScreen(
                    postId: postId,
                    initialPost: extra is Post && extra.postId == postId
                        ? extra
                        : null,
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
              // A keeper's own member profile.
              //
              // /profile is a shell branch whose builder swaps in the Studio
              // analytics for keepers, so a keeper had no route to their own
              // profile at all — the avatar in the Studio header sent them to
              // Analytics. This lives in the Home branch alongside the other
              // Studio pushes: footer nav stays visible, and it is a page
              // rather than a tab because the tab slot is already spoken for.
              GoRoute(
                path: '/profile/me',
                builder: (_, __) => const ProfileScreen(showBackButton: true),
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
                        builder: (ctx, st) => TribeChatHubScreen(
                          slug: st.pathParameters['slug']!,
                        ),
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
                        builder: (ctx, st) => TribeReportsScreen(
                          slug: st.pathParameters['slug']!,
                        ),
                      ),
                      GoRoute(
                        path: 'moderation',
                        builder: (ctx, st) => TribeModerationScreen(
                          slug: st.pathParameters['slug']!,
                        ),
                      ),
                      GoRoute(
                        path: 'edit',
                        builder: (ctx, st) =>
                            EditTribeScreen(slug: st.pathParameters['slug']!),
                      ),
                      GoRoute(
                        path: 'settings',
                        builder: (ctx, st) => TribeSettingsScreen(
                          slug: st.pathParameters['slug']!,
                        ),
                        routes: [
                          GoRoute(
                            path: 'identity',
                            builder: (ctx, st) => EditTribeScreen(
                              slug: st.pathParameters['slug']!,
                              focusWelcome:
                                  st.uri.queryParameters['focus'] == 'welcome',
                            ),
                          ),
                          GoRoute(
                            path: 'rules',
                            builder: (ctx, st) => TribeRulesEditorScreen(
                              slug: st.pathParameters['slug']!,
                            ),
                          ),
                          GoRoute(
                            path: 'members',
                            builder: (ctx, st) => TribeMembersManagementScreen(
                              slug: st.pathParameters['slug']!,
                            ),
                          ),
                          GoRoute(
                            path: 'spaces',
                            builder: (ctx, st) => TribeSpacesManagementScreen(
                              slug: st.pathParameters['slug']!,
                              openCreate:
                                  st.uri.queryParameters['create'] == 'true',
                            ),
                          ),
                          GoRoute(
                            path: 'content',
                            builder: (ctx, st) => TribeContentManagementScreen(
                              slug: st.pathParameters['slug']!,
                              initialFilter:
                                  st.uri.queryParameters['filter'] ?? 'all',
                              initialAction: st.uri.queryParameters['action'],
                            ),
                          ),
                          GoRoute(
                            path: 'audit',
                            builder: (ctx, st) => TribeAuditScreen(
                              slug: st.pathParameters['slug']!,
                            ),
                          ),
                          GoRoute(
                            path: 'helpers',
                            builder: (ctx, st) => TribeHelpersScreen(
                              slug: st.pathParameters['slug']!,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(
                path: '/tribes/new',
                // Gated here rather than at each button: eight screens push
                // this path and only one of them was checking.
                builder: (_, __) =>
                    const TribeCreationGate(child: CreateTribeScreen()),
              ),
              GoRoute(
                path: '/questions',
                builder: (_, __) => const QuestionsScreen(),
              ),
              GoRoute(path: '/goals', builder: (_, __) => const GoalsScreen()),
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
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/whispers',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveWhispersTab()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/compose',
                builder: (ctx, st) =>
                    ComposeScreen(queryParams: st.uri.queryParameters),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/inbox',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveInboxTab()),
              ),
            ],
          ),
          // ── Profile + its sub-pages ───────────────────────────────────
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (_, __) =>
                    const KeepAliveWrapper(child: AdaptiveProfileTab()),
              ),
              GoRoute(
                path: '/profile/avatar',
                builder: (ctx, st) => AvatarStudioScreen(
                  personaId: st.uri.queryParameters['persona'],
                ),
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
                path: '/profile/devices',
                builder: (_, __) => const ActiveDevicesScreen(),
              ),
              GoRoute(
                path: '/security-check',
                builder: (_, __) => const SecurityCheckScreen(),
              ),
              GoRoute(
                path: '/settings',
                builder: (_, __) => const SettingsScreen(),
              ),
              GoRoute(
                path: '/personas',
                builder: (_, __) => const PersonasScreen(),
              ),
              GoRoute(
                path: '/avatar',
                builder: (ctx, st) => AvatarPickerScreen(
                  personaId: st.uri.queryParameters['persona'],
                ),
              ),
            ],
          ),
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
      GoRoute(path: '/plug-dashboard', redirect: (_, __) => '/feed'),
      // DM chat box — root navigator, no footer nav inside conversations.
      GoRoute(
        path: '/group-chat/new',
        builder: (ctx, st) => CreateGroupChatScreen(
          friendUserId: st.uri.queryParameters['friendId'] ?? '',
          friendPseudonym: st.uri.queryParameters['friendName'] ?? '@friend',
          friendAvatarSeed:
              st.uri.queryParameters['friendAvatar'] ?? 'default-orb',
        ),
      ),
      GoRoute(
        path: '/chat/:roomId',
        builder: (ctx, st) => ChatScreen(roomId: st.pathParameters['roomId']!),
      ),
      // Public profiles opened from a root-level conversation must stay on the
      // root navigator. Pushing the shell-owned /user route from here would
      // instantiate the stateful tab navigators a second time and trigger
      // Flutter's keyReservation assertion.
      GoRoute(
        path: '/user-preview/:userId',
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
      // Posts opened from a root-level conversation must remain on the root
      // navigator too. Re-entering the shell-owned /post route from chat can
      // reserve the stateful branch navigator keys twice.
      GoRoute(
        path: '/post-preview/:id',
        builder: (ctx, st) {
          final postId = st.pathParameters['id']!;
          final extra = st.extra;
          return PostDetailScreen(
            postId: postId,
            initialPost: extra is Post && extra.postId == postId ? extra : null,
          );
        },
      ),
      // Root-navigator twins, for destinations that normally live inside the
      // shell but are opened from a route that does not.
      //
      // Pushing a shell-owned route from a root one reserves the stateful
      // branch navigator keys a second time and trips
      // `!keyReservation.contains(key)`, which surfaces to a user as "this
      // part of Venttly didn't load". /user-preview and /post-preview already
      // existed for exactly this; these two close the remaining cases —
      // "Full tribe manage" from a chat hub, and Settings from the story
      // composer and the story viewer.
      //
      // `go` does not need a twin: it replaces the stack, so the shell is
      // rebuilt rather than re-entered. Only `push` is affected.
      GoRoute(
        path: '/manage-preview/:slug',
        builder: (ctx, st) =>
            TribeManageScreen(slug: st.pathParameters['slug']!),
      ),
      GoRoute(
        path: '/settings-preview',
        builder: (_, __) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/group-chat/:roomId/settings',
        builder: (ctx, st) =>
            GroupChatSettingsScreen(roomId: st.pathParameters['roomId']!),
      ),
      GoRoute(
        path: '/group-invite/:token',
        builder: (ctx, st) =>
            GroupInviteScreen(token: st.pathParameters['token']!),
      ),
      // Full-screen creators + story viewer stay immersive.
      GoRoute(
        path: '/compose/story',
        // Root navigator, explicitly. Pushed from inside the compose tab this
        // route landed in that tab's navigator, and the shell's floating nav
        // bar sat on top of the source tiles while its offline banner covered
        // the close button — a screen where nothing worked and there was no
        // way out.
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, __) => const CreateStoryScreen(),
      ),
      GoRoute(
        path: '/whispers/new',
        parentNavigatorKey: rootNavigatorKey,
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
    // Without this the splash never lifts: the gate settles, and nothing asks
    // the router to look again.
    ref.listen(authGateProvider, (_, __) => notifyListeners());
    ref.listen(pendingMfaFactorIdProvider, (_, __) => notifyListeners());
  }
  final Ref ref;
}
