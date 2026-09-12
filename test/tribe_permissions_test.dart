import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/tribe/tribe_management.dart';

/// These guard the seam this project has been bitten by repeatedly: PostgREST
/// hands back a plain map, so a column the server did not send is simply an
/// absent key, indistinguishable from a real null. Anything that reads a
/// permission set has to survive that without silently deciding somebody has
/// no authority — or worse, inventing some.
void main() {
  group('TribePermissionGrants', () {
    test('reads the shape tribe_permission_grants actually returns', () {
      final grants = TribePermissionGrants.fromJson({
        'catalog': [
          {
            'key': 'manage_members',
            'label': 'Manage members',
            'description': 'Warn, mute, remove and ban members.',
          },
          {
            'key': 'manage_rules',
            'label': 'Edit the rules',
            'description': 'Publish new rules.',
          },
        ],
        'members': [
          {
            'user_id': 'u1',
            'pseudonym': 'helper',
            'avatar_seed': 'seed-1',
            'role': 'mod',
            'permissions': ['manage_rules', 'view_management'],
          },
        ],
      });

      expect(grants.catalog.map((o) => o.key), ['manage_members', 'manage_rules']);
      expect(grants.helpers.single.pseudonym, 'helper');
      expect(grants.helpers.single.permissions, [
        'manage_rules',
        'view_management',
      ]);
    });

    test('an empty tribe yields no catalog and no helpers, not a crash', () {
      final grants = TribePermissionGrants.fromJson({
        'catalog': [],
        'members': [],
      });
      expect(grants.catalog, isEmpty);
      expect(grants.helpers, isEmpty);
    });

    test('missing keys degrade to empty rather than throwing', () {
      // A server that stops sending 'members' must not take the screen down;
      // showing no helpers is wrong but recoverable, a crash is not.
      final grants = TribePermissionGrants.fromJson(const {});
      expect(grants.catalog, isEmpty);
      expect(grants.helpers, isEmpty);
    });

    test('a member row missing its permissions holds none', () {
      // Never the other way round. If the server did not say what someone can
      // do, the answer the client assumes must be "nothing".
      final helper = TribeHelper.fromJson(const {
        'user_id': 'u2',
        'pseudonym': 'quiet',
      });
      expect(helper.permissions, isEmpty);
      expect(helper.role, 'member');
      expect(helper.avatarSeed, isNull);
    });
  });

  group('TribeRulesStatus', () {
    test('reads a live rules notice', () {
      final status = TribeRulesStatus.fromJson({
        'version': 3,
        'published_at': '2026-08-30T09:00:00Z',
        'change_note': 'Added a rule about screenshots',
        'acknowledged_version': 2,
        'is_member': true,
        'needs_acknowledgement': true,
        'rules': [
          {'position': 0, 'title': 'Be kind', 'description': 'No mocking.'},
        ],
      });

      expect(status.version, 3);
      expect(status.acknowledgedVersion, 2);
      expect(status.needsAcknowledgement, isTrue);
      expect(status.rules.single.title, 'Be kind');
      expect(status.publishedAt, isNotNull);
    });

    test('an absent needs_acknowledgement does not raise a notice', () {
      // The notice interrupts somebody. It only appears when the server has
      // positively said it should, never because a key was missing.
      final status = TribeRulesStatus.fromJson(const {'version': 1});
      expect(status.needsAcknowledgement, isFalse);
      expect(status.isMember, isFalse);
      expect(status.rules, isEmpty);
      expect(status.publishedAt, isNull);
    });

    test('a tribe that has never published rules reads as version zero', () {
      final status = TribeRulesStatus.fromJson(const {});
      expect(status.version, 0);
      expect(status.needsAcknowledgement, isFalse);
    });
  });
}
