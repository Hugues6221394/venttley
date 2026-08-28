import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/group_invite_links.dart';
import 'package:vently_app/presentation/screens/inbox/group_invite_screen.dart';

const _token = '550e8400-e29b-41d4-a716-446655440000';
const _link = 'venttly://group-invite/$_token';

void main() {
  test('invite URI builder emits only the canonical registered shape', () {
    expect(groupInviteUri(_token.toUpperCase()).toString(), _link);

    for (final value in [
      '',
      'not-a-uuid',
      '$_token/extra',
      '$_token?redirect=/profile',
    ]) {
      expect(() => groupInviteUri(value), throwsFormatException);
    }
  });

  testWidgets(
    'invite token stays off screen and leaves only through explicit actions',
    (tester) async {
      String? copied;
      String? shared;
      String? sharedSubject;
      Rect? origin;
      final feedback = <String>[];

      tester.view.physicalSize = const Size(390, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showGroupInviteShareSheet(
                  context,
                  groupTitle: 'Campus Support',
                  token: _token,
                  onFeedback: feedback.add,
                  copy: (text) async => copied = text,
                  share: (text, {sharePositionOrigin, subject}) async {
                    shared = text;
                    origin = sharePositionOrigin;
                    sharedSubject = subject;
                  },
                ),
                child: const Text('Open invite actions'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open invite actions'));
      await tester.pumpAndSettle();

      expect(find.textContaining(_token), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Share invite'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);

      await tester.ensureVisible(find.text('Share invite'));
      await tester.tap(find.text('Share invite'));
      await tester.pumpAndSettle();

      expect(shared, 'Join Campus Support on Venttly.\n$_link');
      expect(sharedSubject, 'Venttly group invite');
      expect(origin, isNotNull);
      expect(copied, isNull);

      await tester.ensureVisible(find.text('Copy link'));
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(copied, _link);
      expect(feedback, [
        'Invite link copied. Share it only with people you trust.',
      ]);
      expect(find.text('Invite people'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resetting an invite requires explicit confirmation', (
    tester,
  ) async {
    var resets = 0;
    final feedback = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showGroupInviteShareSheet(
                context,
                groupTitle: 'Campus Support',
                token: _token,
                onFeedback: feedback.add,
                onReset: () async => resets += 1,
              ),
              child: const Text('Open invite actions'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open invite actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset link'));
    await tester.pumpAndSettle();

    expect(find.text('Reset invite link?'), findsOneWidget);
    expect(resets, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resets, 0);

    await tester.tap(find.text('Reset link'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset link'));
    await tester.pumpAndSettle();

    expect(resets, 1);
    expect(feedback, [
      'A new invite link is ready. The old link no longer works.',
    ]);
    expect(find.text('Invite people'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default actions reach the share and clipboard platform channels',
      (tester) async {
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    MethodCall? shareCall;
    String? platformClipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      shareChannel,
      (call) async {
        shareCall = call;
        return '';
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          platformClipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': platformClipboard};
        }
        return null;
      },
    );
    addTearDown(
      () {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          shareChannel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showGroupInviteShareSheet(
                context,
                groupTitle: 'Campus Support',
                token: _token,
                onFeedback: (_) {},
              ),
              child: const Text('Open invite actions'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open invite actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share invite'));
    await tester.pumpAndSettle();

    expect(shareCall?.method, 'share');
    expect(shareCall?.arguments, isA<Map<Object?, Object?>>());
    final arguments = shareCall!.arguments as Map<Object?, Object?>;
    expect(arguments['text'], 'Join Campus Support on Venttly.\n$_link');
    expect(arguments['subject'], 'Venttly group invite');
    expect(arguments['originWidth'], greaterThan(0));
    expect(arguments['originHeight'], greaterThan(0));

    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipboard?.text, _link);
    expect(tester.takeException(), isNull);
  });
}
