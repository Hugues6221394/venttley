import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/logger.dart';
import 'package:vently_app/data/services/row_shape_guard.dart';

/// The guard exists because four separate bugs looked identical to "this user
/// has no photo". It only earns its place if it stays silent on a healthy row
/// and speaks up exactly once on a stale one — a guard that cries wolf gets
/// muted, and a muted guard is the silence it was built to end.
void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    resetColumnExpectations();
    Logger.instance.onRecord = records.add;
  });

  tearDown(() => Logger.instance.onRecord = null);

  List<LogRecord> warnings() =>
      records.where((r) => r.event == 'db.missing_columns').toList();

  test('says nothing when every expected column is present', () {
    expectColumns(
      'inbox_rooms',
      {'peer_profile_photo_url': null, 'group_avatar_path': 'x'},
      const {'peer_profile_photo_url': 'mig_a', 'group_avatar_path': 'mig_b'},
    );
    expect(warnings(), isEmpty);
  });

  test('a real null is not a missing column', () {
    // The distinction the whole guard exists for: the key is there and the
    // value is null, which is a person without a photo, not a stale view.
    expectColumns(
      'users',
      {'profile_banner_url': null},
      const {'profile_banner_url': 'mig_a'},
    );
    expect(warnings(), isEmpty);
  });

  test('reports the absent columns and the migrations that add them', () {
    expectColumns(
      'inbox_rooms',
      {'room_id': 'r1'},
      const {
        'peer_profile_photo_url': 'mig_photos',
        'group_avatar_path': 'mig_groups',
        'is_group_owner': 'mig_groups',
      },
    );
    expect(warnings(), hasLength(1));
    final props = warnings().single.props;
    expect(props['source'], 'inbox_rooms');
    expect(props['columns'], contains('peer_profile_photo_url'));
    expect(props['columns'], contains('is_group_owner'));
    // Deduplicated: two columns from one migration must not name it twice.
    expect(props['migrations'], ['mig_groups', 'mig_photos']);
  });

  test('warns once per source, not once per row', () {
    // A list screen maps hundreds of rows. Warning on each would bury the log
    // and make the signal unusable.
    for (var i = 0; i < 200; i++) {
      expectColumns('posts', {'post_id': '$i'}, const {'is_story': 'mig'});
    }
    expect(warnings(), hasLength(1));
  });

  test('sources are independent', () {
    expectColumns('posts', {'post_id': 'p'}, const {'is_story': 'mig_a'});
    expectColumns('users', {'user_id': 'u'}, const {'bio': 'mig_b'});
    expect(warnings(), hasLength(2));
    expect(
      warnings().map((w) => w.props['source']),
      containsAll(<String>['posts', 'users']),
    );
  });

  test('stays readable through the PII scrubber', () {
    // A joined string of column names ran past the scrubber's 120-character
    // ceiling and came out as <scrubbed:length=122>, which named nothing.
    expectColumns('inbox_rooms', const {}, const {
      'peer_profile_photo_url': '20260721195535_inbox_peer_profile_photos',
      'group_avatar_path': '20260719000932_group_chat_membership_and_settings',
      'group_invite_token': '20260719000932_group_chat_membership_and_settings',
      'group_invite_enabled':
          '20260719000932_group_chat_membership_and_settings',
      'group_allow_member_invites':
          '20260719000932_group_chat_membership_and_settings',
      'is_group_owner': '20260719000932_group_chat_membership_and_settings',
    });
    final props = warnings().single.props;
    for (final value in props.values) {
      expect(value.toString(), isNot(contains('<scrubbed')));
    }
    expect(props['count'], 6);
    // The timestamp is dropped, the identifying slug survives.
    expect(props['migrations'], [
      'group_chat_membership_and_settings',
      'inbox_peer_profile_photos',
    ]);
  });

  test(
    'never throws — a stale column degrades a screen, it does not end it',
    () {
      expect(
        () => expectColumns('anything', const {}, const {'nope': 'mig'}),
        returnsNormally,
      );
    },
  );
}
