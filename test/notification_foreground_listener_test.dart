import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/tribe/tribe_chat_hub.dart';
import 'package:vently_app/presentation/widgets/notification_foreground_listener.dart';

void main() {
  testWidgets('foreground streams can emit above the router route subtree',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allInboxRoomsStreamProvider.overrideWith(
            (_) => Stream.value(const <ChatRoom>[]),
          ),
          tribeChatInboxProvider.overrideWith(
            (_) async => const <TribeChatInboxSummary>[],
          ),
        ],
        child: MaterialApp(
          home: NotificationForegroundListener(
            router: router,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
