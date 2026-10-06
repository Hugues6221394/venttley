// Talking to the Venttly team: does a member reach the team, read the answer,
// and reply, without ever being shown who on staff wrote it, and without a
// retry posting the same message twice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/notification_routing.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/support/support_conversation.dart';
import 'package:vently_app/presentation/screens/settings/support_screen.dart';

const _conversation = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _message = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class _FakeRepository extends VentlyRepository {
  _FakeRepository({this.list = const []}) : super(forceMock: true);

  List<SupportConversationSummary> list;
  final Map<SupportThreadRef, SupportThread> threads = {};
  final List<({String operation, SupportThreadRef ref, String body})> replies =
      [];
  final List<({String operation, SupportCategory category, String subject})>
  started = [];

  /// Fail the next send the way the database or network does.
  String? failNext;

  @override
  Future<List<SupportConversationSummary>> supportConversations() async => list;

  @override
  Future<SupportThread> supportThread(SupportThreadRef ref) async =>
      threads[ref]!;

  @override
  Future<String> replySupport({
    required String operationId,
    required SupportThreadRef ref,
    required String body,
  }) async {
    replies.add((operation: operationId, ref: ref, body: body));
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw Exception(failure);
    }
    final id = ref.conversationId ?? _conversation;
    final key = SupportThreadRef(conversationId: id);
    final before = threads[ref]!;
    threads[key] = SupportThread(
      conversationId: id,
      communicationId: before.communicationId,
      subject: before.subject,
      status: SupportStatus.open,
      canReply: true,
      messages: [
        ...before.messages,
        SupportMessage(
          id: 'm${replies.length}',
          fromMe: true,
          body: body,
          createdAt: DateTime(2026, 10, 7, 9),
        ),
      ],
    );
    return id;
  }

  @override
  Future<String> startSupportConversation({
    required String operationId,
    required SupportCategory category,
    required String subject,
    required String body,
  }) async {
    started.add((operation: operationId, category: category, subject: subject));
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw Exception(failure);
    }
    threads[const SupportThreadRef(
      conversationId: _conversation,
    )] = SupportThread(
      conversationId: _conversation,
      communicationId: null,
      subject: subject,
      status: SupportStatus.open,
      canReply: true,
      messages: [
        SupportMessage(id: 'm0', fromMe: true, body: body, createdAt: null),
      ],
    );
    return _conversation;
  }
}

SupportThread _staffMessageThread() => SupportThread(
  conversationId: null,
  communicationId: _message,
  subject: 'Checking in',
  status: SupportStatus.replied,
  canReply: true,
  messages: [
    SupportMessage(
      id: _message,
      fromMe: false,
      body: 'We saw your report and wanted to follow up.',
      createdAt: DateTime(2026, 10, 6, 18),
    ),
  ],
);

Future<_FakeRepository> _pump(
  WidgetTester tester,
  _FakeRepository repo, {
  String initial = '/settings/support',
  double height = 900,
}) async {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/settings/support',
        builder: (_, __) => const SupportScreen(),
      ),
      GoRoute(
        path: '/settings/support/new',
        builder: (_, __) => const NewSupportScreen(),
      ),
      GoRoute(
        path: '/settings/support/thread',
        builder: (_, st) {
          final q = st.uri.queryParameters;
          return SupportThreadScreen(
            thread: q['conversation'] != null
                ? SupportThreadRef(conversationId: q['conversation'])
                : SupportThreadRef(communicationId: q['message']),
          );
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('with no conversations, it says who answers and how', (
    tester,
  ) async {
    await _pump(tester, _FakeRepository());
    expect(find.text('Talk to the Venttly team'), findsOneWidget);
    expect(find.text('New message'), findsOneWidget);
  });

  testWidgets('an unanswered staff message is listed as from the team', (
    tester,
  ) async {
    final repo = _FakeRepository(
      list: [
        SupportConversationSummary(
          conversationId: null,
          communicationId: _message,
          subject: 'Checking in',
          status: SupportStatus.replied,
          lastMessageAt: DateTime(2026, 10, 6, 18),
          lastFromTeam: true,
          unread: true,
          preview: 'We saw your report and wanted to follow up.',
          canReply: true,
        ),
      ],
    );
    repo.threads[const SupportThreadRef(communicationId: _message)] =
        _staffMessageThread();
    await _pump(tester, repo);

    expect(find.text('Checking in'), findsOneWidget);
    expect(
      find.text('Venttly team: We saw your report and wanted to follow up.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Checking in'));
    await tester.pumpAndSettle();
    expect(find.text('Venttly team'), findsOneWidget);
  });

  testWidgets(
    'replying to a staff message starts the conversation and follows it',
    (tester) async {
      final repo = _FakeRepository();
      repo.threads[const SupportThreadRef(communicationId: _message)] =
          _staffMessageThread();
      await _pump(
        tester,
        repo,
        initial: '/settings/support/thread?message=$_message',
      );

      await tester.enterText(find.byType(TextField), 'Thank you, I am okay.');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(repo.replies.single.ref.communicationId, _message);
      expect(find.text('Thank you, I am okay.'), findsOneWidget);
      expect(
        find.text('We saw your report and wanted to follow up.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a failed send keeps the text and retries as the same message', (
    tester,
  ) async {
    final repo = _FakeRepository();
    repo.threads[const SupportThreadRef(conversationId: _conversation)] =
        _staffMessageThread();
    repo.failNext = 'network down';
    await _pump(
      tester,
      repo,
      initial: '/settings/support/thread?conversation=$_conversation',
    );

    await tester.enterText(find.byType(TextField), 'Still not working.');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('it will not be sent twice'), findsOneWidget);
    expect(find.text('Still not working.'), findsOneWidget);

    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(repo.replies, hasLength(2));
    expect(repo.replies[0].operation, repo.replies[1].operation);
  });

  testWidgets('a closed conversation offers a new one instead of a reply box', (
    tester,
  ) async {
    final repo = _FakeRepository();
    repo.threads[const SupportThreadRef(
      conversationId: _conversation,
    )] = SupportThread(
      conversationId: _conversation,
      communicationId: null,
      subject: 'Old question',
      status: SupportStatus.closed,
      canReply: false,
      messages: const [],
    );
    await _pump(
      tester,
      repo,
      initial: '/settings/support/thread?conversation=$_conversation',
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('This conversation is closed'), findsOneWidget);
  });

  testWidgets('starting a conversation needs a topic, subject and message', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      _FakeRepository(),
      initial: '/settings/support/new',
      height: 1400,
    );
    FilledButton send() =>
        tester.widget<FilledButton>(find.byType(FilledButton));

    expect(send().onPressed, isNull);
    await tester.tap(find.text('Something is not working'));
    await tester.enterText(find.byType(TextField).at(0), 'App closes');
    await tester.enterText(
      find.byType(TextField).at(1),
      'It closes on launch.',
    );
    await tester.pump();
    expect(send().onPressed, isNotNull);

    repo.failNext = 'too_many_open: finish an open conversation first';
    await tester.tap(find.text('Send to Venttly'));
    await tester.pumpAndSettle();
    expect(find.textContaining('three open conversations'), findsOneWidget);

    await tester.tap(find.text('Send to Venttly'));
    await tester.pumpAndSettle();
    expect(repo.started, hasLength(2));
    expect(repo.started[0].operation, repo.started[1].operation);
    expect(repo.started.last.category, SupportCategory.technical);
    expect(find.text('It closes on launch.'), findsOneWidget);
  });

  test(
    'a team message opens its conversation; anything malformed does not',
    () {
      expect(
        NotificationPayload.fromNotificationItem('system', {
          'source': 'venttly_team',
          'support_case_id': _conversation,
        }),
        'support:$_conversation',
      );
      expect(
        NotificationPayload.fromNotificationItem('system', {
          'source': 'venttly_team',
          'communication_id': _message,
        }),
        'support_message:$_message',
      );
      expect(
        NotificationPayload.fromNotificationItem('system', {
          'source': 'venttly_team',
          'support_case_id': '../admin',
        }),
        'notifications',
      );
      expect(
        NotificationPayload.fromNotificationItem('system', {'title': 'Hello'}),
        'notifications',
      );
      expect(
        routeForNotificationPayload('support:$_conversation'),
        '/settings/support/thread?conversation=$_conversation',
      );
      expect(
        routeForNotificationPayload('support_message:$_message'),
        '/settings/support/thread?message=$_message',
      );
      expect(routeForNotificationPayload('support:x&y=1'), '/settings/support');
    },
  );
}
