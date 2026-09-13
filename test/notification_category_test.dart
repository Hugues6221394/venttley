// Activity tabs: the partition, and the routing.
//
// Two properties, both of which failed quietly before this existed.
//
// A kind that belongs to no tab is reachable only from "All". It is not
// missing — it renders, it is counted, it just cannot be found by anyone
// filtering. Nothing about the screen looks broken.
//
// A kind that routes nowhere is worse: it renders, it is tappable, and the tap
// does nothing at all. Five kinds were in that state — new_follower,
// message_accepted, moderation_action, admin_broadcast and system — because
// notification_routing.dart returned null for anything its switch did not
// name, and the default case is silent.
//
// The kind list here mirrors the CHECK on public.notifications.kind. The
// duplication is the point: a new kind added to the database and not to this
// list fails the first test below, which is the only signal that would
// otherwise never arrive.

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/notification_routing.dart';
import 'package:vently_app/domain/notifications/notification_category.dart';

/// Every identifier a payload might legitimately carry, so routing is tested
/// for coverage rather than for whether this fixture guessed the right key.
const _fullPayload = <String, dynamic>{
  'post_id': 'a0000000-0000-4000-8000-000000000001',
  'whisper_id': 'b0000000-0000-4000-8000-000000000001',
  'room_id': 'c0000000-0000-4000-8000-000000000001',
  'tribe_slug': 'late-night-study',
  'message_id': 'd0000000-0000-4000-8000-000000000001',
  'friend_id': 'e0000000-0000-4000-8000-000000000001',
  'actor_id': 'f0000000-0000-4000-8000-000000000001',
  'transfer_id': '10000000-0000-4000-8000-000000000001',
  'case_id': '20000000-0000-4000-8000-000000000001',
};

void main() {
  group('categories partition every kind', () {
    test('each kind belongs to exactly one tab besides All', () {
      for (final kind in kNotificationKinds) {
        final owners = NotificationCategory.tabs
            .where((c) => c != NotificationCategory.all && c.matches(kind))
            .toList();
        expect(
          owners.length,
          1,
          reason: owners.isEmpty
              ? '"$kind" belongs to no tab, so it can only be found under All'
              : '"$kind" appears under ${owners.map((c) => c.label).join(" and ")} '
                    '— a reader clearing one tab would still see it in another',
        );
      }
    });

    test('All shows everything', () {
      for (final kind in kNotificationKinds) {
        expect(NotificationCategory.all.matches(kind), isTrue);
      }
    });

    test('no tab claims a kind the database would reject', () {
      for (final category in NotificationCategory.tabs) {
        for (final kind in category.kinds) {
          expect(kNotificationKinds, contains(kind),
              reason: '${category.label} filters on "$kind", which is not a '
                  'kind the notifications CHECK allows — a typo here silently '
                  'empties a tab');
        }
      }
    });

    test('the tabs are the ones the brief asks for, in order', () {
      expect(
        NotificationCategory.tabs.map((c) => c.label).toList(),
        ['All', 'Mentions', 'Reactions', 'Comments', 'Friends', 'Tribes', 'System'],
      );
    });
  });

  group('every kind opens something', () {
    test('no kind resolves to null when its payload is complete', () {
      final dead = <String>[];
      for (final kind in kNotificationKinds) {
        final target = NotificationPayload.fromNotificationItem(
          kind,
          _fullPayload,
        );
        if (target == null || target.isEmpty) dead.add(kind);
      }
      expect(dead, isEmpty,
          reason: 'these kinds render and are tappable but go nowhere: '
              '${dead.join(", ")}');
    });

    test('the kinds that were silently dead now resolve', () {
      // Named individually so a regression points at the specific one.
      for (final kind in [
        'new_follower',
        'message_accepted',
        'moderation_action',
        'admin_broadcast',
        'system',
      ]) {
        expect(
          NotificationPayload.fromNotificationItem(kind, _fullPayload),
          isNotNull,
          reason: '$kind routed nowhere before',
        );
      }
    });

    test('a reply routes to the thread it was left on', () {
      expect(
        NotificationPayload.fromNotificationItem('comment_reply', _fullPayload),
        'post:${_fullPayload['post_id']}',
      );
      // A reply to a Whisper carries no post_id and must fall through to the
      // Whisper rather than returning null.
      expect(
        NotificationPayload.fromNotificationItem('whisper_reply', {
          'whisper_id': _fullPayload['whisper_id'],
        }),
        'whisper:${_fullPayload['whisper_id']}',
      );
    });

    test('a missing identifier degrades instead of dying', () {
      // An empty payload is the realistic bad case — a row written before a
      // column existed, or a kind whose producer forgot one. Friends and
      // system rows have somewhere sensible to land; the content ones do not,
      // and returning null so the tile simply does not navigate is better
      // than pushing a route with a null id.
      expect(NotificationPayload.fromNotificationItem('new_follower', const {}),
          isNotNull);
      expect(NotificationPayload.fromNotificationItem('system', const {}),
          isNotNull);
      expect(NotificationPayload.fromNotificationItem('post_like', const {}),
          isNull);
    });
  });
}
