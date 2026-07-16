import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/inbox/create_group_chat_screen.dart';
import 'package:vently_app/presentation/widgets/chat_options_sheet.dart';

void main() {
  test('group chat schema is friend-gated and keeps DMs compatible', () {
    final migration = File(
      'supabase/migrations/20260716224000_group_chat_reliability.sql',
    ).readAsStringSync();
    final sheet = File(
      'lib/presentation/widgets/chat_options_sheet.dart',
    ).readAsStringSync();

    expect(migration,
        contains('CREATE OR REPLACE FUNCTION public.create_group_chat'));
    expect(migration, contains("f.status = 'accepted'"));
    expect(migration, contains("room_kind IN ('direct', 'group')"));
    expect(migration, contains("r.room_kind = 'group' AS is_group"));
    expect(sheet, contains("path: '/group-chat/new'"));
    expect(sheet, isNot(contains("context.push('/tribes/new')")));
  });

  testWidgets('group chat action closes its sheet before navigation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = VentlyRepository(forceMock: true);
    late final GoRouter router;
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showChatOptionsSheet(
                  context,
                  room: _room,
                  onSearch: () {},
                ),
                child: const Text('Open options'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/group-chat/new',
          builder: (context, state) => Scaffold(
            body: Text(
              'Group creator ${state.uri.queryParameters['friendId']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.text('Open options'));
    await tester.pumpAndSettle();
    if (find.text('Create a group chat').evaluate().isEmpty) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -360));
      await tester.pumpAndSettle();
    }
    expect(find.text('Create a group chat'), findsOneWidget);

    await tester.tap(find.text('Create a group chat'));
    await tester.pumpAndSettle();

    expect(find.text('Group creator friend-user'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group creator stays composed on a compact phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(
            VentlyRepository(forceMock: true),
          ),
        ],
        child: const MaterialApp(
          home: CreateGroupChatScreen(
            friendUserId: 'friend-user',
            friendPseudonym: '@HealingSlow',
            friendAvatarSeed: 'healing-slow',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New group chat'), findsOneWidget);
    expect(find.text('Create group chat'), findsOneWidget);
    expect(find.text('@HealingSlow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final _room = ChatRoom(
  roomId: 'room-direct',
  peerPseudonym: '@HealingSlow',
  peerAvatarSeed: 'healing-slow',
  peerUserId: 'friend-user',
  requestPreview: '',
  roomStatus: 'active',
  createdAt: DateTime.utc(2026, 7, 16),
  initiatedByMe: true,
);
