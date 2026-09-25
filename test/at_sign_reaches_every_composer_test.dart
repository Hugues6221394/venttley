import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/notification_routing.dart';

/// Where an @ can be typed, and where a tag can be tapped.
///
/// Asked for: "ensure the @ is for tagging people on vents, 24 hr stories,
/// comments, in spaces, group chats, everywhere where a tag can be useful".
///
/// Two widgets do this work. TagAutocomplete is what offers names while you
/// type; TaggedText is what turns @handle into something tappable once it is
/// written. A screen that has one and not the other is half-tagged: either you
/// can write a name nobody can tap, or you can tap names you had to spell from
/// memory.
///
/// A source scan rather than a widget test per screen, because the failure is
/// an omission — the next composer somebody adds is the one that forgets.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('you can type a name where people write to each other', () {
    const composers = <String, String>{
      'a vent': 'lib/presentation/screens/compose/compose_screen.dart',
      'a comment on a vent':
          'lib/presentation/screens/feed/post_detail_screen.dart',
      'a comment on a whisper':
          'lib/presentation/widgets/whisper_comments_sheet.dart',
      'a 24-hour story':
          'lib/presentation/screens/compose/create_story_screen.dart',
      'a tribe chat, which is also a space':
          'lib/presentation/screens/tribes/tribe_chat_screen.dart',
      'a group chat in the inbox':
          'lib/presentation/screens/inbox/chat_screen.dart',
    };

    for (final entry in composers.entries) {
      test('in ${entry.key}', () {
        expect(
          read(entry.value),
          contains('TagAutocomplete'),
          reason:
              '${entry.value} takes text that other people read, so typing @ '
              'should offer names',
        );
      });
    }
  });

  group('and a name that is written can be tapped', () {
    const readers = <String, String>{
      'a vent': 'lib/presentation/widgets/post_card.dart',
      'a vent opened in full':
          'lib/presentation/screens/feed/post_detail_screen.dart',
      'a story': 'lib/presentation/screens/feed/story_viewer_screen.dart',
      'a comment on a whisper':
          'lib/presentation/widgets/whisper_comments_sheet.dart',
      'a tribe chat message':
          'lib/presentation/screens/tribes/tribe_chat_screen.dart',
      'a chat message': 'lib/presentation/screens/inbox/chat_screen.dart',
    };

    for (final entry in readers.entries) {
      test('in ${entry.key}', () {
        expect(
          read(entry.value),
          contains('TaggedText'),
          reason: '${entry.value} shows text somebody else wrote',
        );
      });
    }
  });

  group('and being tagged takes you to where it happened', () {
    test('a tag in a tribe chat opens that chat, at the message', () {
      expect(
        NotificationPayload.fromNotificationItem('mention', {
          'tribe_slug': 'night-owls',
          'message_id': 'm1',
        }),
        'tribe_chat:night-owls/m1',
      );
    });

    test('a tag in a group chat opens the thread', () {
      expect(
        NotificationPayload.fromNotificationItem('mention', {'room_id': 'r1'}),
        'chat:r1',
      );
    });

    test('a tag on a vent still opens the vent', () {
      expect(
        NotificationPayload.fromNotificationItem('mention', {'post_id': 'p1'}),
        'post:p1',
      );
    });

    test(
      'and a tag with nothing to open goes nowhere rather than guessing',
      () {
        expect(
          NotificationPayload.fromNotificationItem('mention', const {}),
          isNull,
        );
      },
    );
  });
}
