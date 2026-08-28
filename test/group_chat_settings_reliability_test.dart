import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/main.dart';
import 'package:vently_app/presentation/widgets/report_reason_sheet.dart';
import 'package:vently_app/presentation/widgets/user_link.dart';

void main() {
  test('group management migration exposes secured lifecycle RPCs', () {
    final migration = File(
      'supabase/migrations/20260719000932_group_chat_membership_and_settings.sql',
    ).readAsStringSync();

    expect(migration,
        contains('CREATE TABLE IF NOT EXISTS public.chat_room_members'));
    expect(migration,
        contains('CREATE OR REPLACE FUNCTION public.create_group_chat_v2'));
    expect(
        migration,
        contains(
            'CREATE OR REPLACE FUNCTION public.mark_group_spam_and_leave'));
    expect(
        migration,
        contains(
            'CREATE OR REPLACE FUNCTION public.join_group_chat_by_invite'));
    expect(migration, contains('REVOKE ALL ON FUNCTION'));
    expect(migration, contains('FROM anon'));
  });

  test('group member RPC restores its complete invoker privilege chain', () {
    final migration = File(
      'supabase/migrations/20260813184402_restore_group_chat_member_rpc_grants.sql',
    ).readAsStringSync();

    expect(migration, contains('GRANT USAGE ON SCHEMA private'));
    expect(
      migration,
      contains('GRANT EXECUTE ON FUNCTION private.is_chat_room_member(UUID)'),
    );
    expect(
      migration,
      contains(
        'ALTER FUNCTION public.group_chat_members(UUID) SECURITY INVOKER',
      ),
    );
    expect(
      migration,
      isNot(
        contains(
          'ALTER FUNCTION public.group_chat_members(UUID) SECURITY DEFINER',
        ),
      ),
    );
  });

  test('group settings expose the required Instagram-style controls', () {
    final settings = File(
      'lib/presentation/screens/inbox/group_chat_settings_screen.dart',
    ).readAsStringSync();
    final creator = File(
      'lib/presentation/screens/inbox/create_group_chat_screen.dart',
    ).readAsStringSync();

    for (final label in [
      'Change name and image',
      'Customize',
      'Invite link',
      'People',
      'Nicknames',
      'Privacy & safety',
      'Create a new group chat',
      "Something isn't working",
      'Mark as spam & leave',
    ]) {
      expect(settings, contains(label));
    }
    expect(settings, contains('showGroupInviteShareSheet'));
    expect(settings, isNot(contains('SelectableText(link')));
    expect(settings, isNot(contains("venttly://group-invite/\$token")));
    expect(creator, contains('ImagePicker'));
    expect(creator, contains('additionalMemberUserIds'));
  });

  test('group invite deep links accept only the registered route shape', () {
    const token = '550e8400-e29b-41d4-a716-446655440000';
    expect(
      groupInvitePathFromUri(Uri.parse('venttly://group-invite/$token')),
      '/group-invite/$token',
    );
    expect(
      groupInvitePathFromUri(Uri.parse('venttly:///group-invite/$token')),
      '/group-invite/$token',
    );
    expect(groupInvitePathFromUri(Uri.parse('https://example.com')), isNull);
    expect(
      groupInvitePathFromUri(Uri.parse('venttly://profile/user-id')),
      isNull,
    );
    for (final uri in [
      Uri.parse('venttly://group-invite/not-a-uuid'),
      Uri.parse('venttly://group-invite/$token/extra'),
      Uri.parse('venttly://group-invite/$token?redirect=/profile'),
      Uri.parse('venttly://group-invite/$token#fragment'),
      Uri.parse('venttly://attacker@group-invite/$token'),
    ]) {
      expect(groupInvitePathFromUri(uri), isNull, reason: '$uri');
    }
  });

  testWidgets('member profile opens on root navigator from group settings',
      (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    late final GoRouter router;
    router = GoRouter(
      navigatorKey: rootKey,
      initialLocation: '/group-chat/room-id/settings',
      routes: [
        GoRoute(
          path: '/group-chat/:roomId/settings',
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => openUserProfile(context, 'member-id'),
                child: const Text('Open member'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/user-preview/:userId',
          builder: (context, state) => Text(
            'Preview ${state.pathParameters['userId']}',
          ),
        ),
        GoRoute(
          path: '/user/:userId',
          builder: (context, state) => Text(
            'Shell profile ${state.pathParameters['userId']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Open member'));
    await tester.pumpAndSettle();

    expect(find.text('Preview member-id'), findsOneWidget);
    expect(find.text('Shell profile member-id'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('report reasons remain usable on a compact phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showReportReasonSheet(
                context,
                title: 'What is not working?',
              ),
              child: const Text('Report'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    expect(find.text('What is not working?'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView), const Offset(0, -480));
    await tester.pumpAndSettle();
    expect(find.text('Something else'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
