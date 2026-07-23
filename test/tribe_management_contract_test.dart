import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/tribe/tribe_management.dart';

void main() {
  group('Tribe management production contract', () {
    test('migration keeps lifecycle actions atomic, audited, and recoverable',
        () {
      final migration = File(
        'supabase/migrations/20260716175655_tribe_lifecycle_management.sql',
      ).readAsStringSync();

      expect(migration, contains('public.create_managed_tribe'));
      expect(migration, contains('public.require_tribe_owner'));
      expect(migration, contains('public.tribe_audit_log'));
      expect(migration, contains("now() + INTERVAL '30 days'"));
      expect(migration, contains('ensure_default_tribe_space'));
      expect(migration, contains("'tribe_ownership_transfer'"));
      expect(migration, contains('minimum_account_age_not_met'));
      expect(migration, contains('tribe_slow_mode_active'));
      expect(migration, contains('NEW.is_approved := FALSE'));
      expect(
        migration,
        contains(
            'GRANT EXECUTE ON FUNCTION public.purge_due_tribes() TO service_role'),
      );
      expect(
        migration,
        isNot(contains(
          'GRANT EXECUTE ON FUNCTION public.purge_due_tribes() TO authenticated',
        )),
      );
    });

    test('owner management surfaces and notification acceptance are routed',
        () {
      final router =
          File('lib/presentation/router/app_router.dart').readAsStringSync();
      final studio = File(
        'lib/presentation/screens/home/keeper_home_screen.dart',
      ).readAsStringSync();
      final notifications = File(
        'lib/presentation/screens/notifications/notifications_screen.dart',
      ).readAsStringSync();

      for (final route in const [
        "path: 'settings'",
        "path: 'identity'",
        "path: 'rules'",
        "path: 'members'",
        "path: 'spaces'",
        "path: 'content'",
        "path: 'audit'",
      ]) {
        expect(router, contains(route));
      }
      expect(studio, contains("label: 'Manage Tribe'"));
      expect(
        studio,
        contains("ValueKey('plug-studio-primary-manage-tribe')"),
        reason: 'Plug Studio must expose management above dashboard metrics',
      );
      expect(
        studio,
        contains("context.push('/tribe/\${tribe.slug}/manage/settings')"),
      );
      expect(
          notifications, contains("item.kind == 'tribe_ownership_transfer'"));
      expect(notifications, contains('respondTribeTransfer'));
    });

    test('management overview parses lifecycle, settings, rules, and transfer',
        () {
      final overview = TribeManagementOverview.fromJson({
        'tribe_id': 'tribe-1',
        'name': 'Quiet Nights',
        'slug': 'quiet-nights',
        'category': 'support',
        'tags': ['support', 'night'],
        'visibility': 'invite_only',
        'lifecycle_status': 'paused',
        'member_count': 12,
        'post_count': 18,
        'space_count': 3,
        'pending_join_requests': 2,
        'pending_invitations': 1,
        'open_reports': 0,
        'settings': {
          'join_approval_required': true,
          'minimum_account_age_days': 7,
          'slow_mode_seconds': 60,
        },
        'rules': [
          {
            'rule_id': 'rule-1',
            'position': 0,
            'title': 'Be kind',
            'is_enabled': true,
          },
        ],
        'pending_transfer': {
          'transfer_id': 'transfer-1',
          'to_user_id': 'user-2',
          'to_pseudonym': 'FuturePlug',
          'keep_previous_owner_as_mod': true,
          'created_at': '2026-07-16T18:00:00Z',
          'expires_at': '2026-07-23T18:00:00Z',
        },
      });

      expect(overview.lifecycleStatus, 'paused');
      expect(overview.visibility, 'invite_only');
      expect(overview.settings.joinApprovalRequired, isTrue);
      expect(overview.settings.minimumAccountAgeDays, 7);
      expect(overview.settings.slowModeSeconds, 60);
      expect(overview.rules.single.title, 'Be kind');
      expect(overview.pendingTransfer?.toPseudonym, 'FuturePlug');
    });

    test('member read model exposes active sanctions', () {
      final member = TribeMemberRow(
        userId: 'user-1',
        pseudonym: 'SoftVoice',
        avatarSeed: 'seed',
        role: 'member',
        joinedAt: DateTime.utc(2026, 7, 1),
        mutedUntil: DateTime.now().add(const Duration(hours: 1)),
        warningCount: 2,
      );

      expect(member.isMuted, isTrue);
      expect(member.hasWarnings, isTrue);
      expect(member.isMod, isFalse);
    });

    test('managed content parses moderation state', () {
      final post = TribeManagedPost.fromJson({
        'post_id': 'post-1',
        'author_pseudonym': '@SoftVoice',
        'author_avatar_seed': 'soft-seed',
        'content': 'A thoughtful vent',
        'category_name': 'healing_corner',
        'post_mood': 'hopeful',
        'likes_count': 4,
        'comments_count': 2,
        'created_at': '2026-07-16T20:00:00Z',
        'is_approved': false,
        'is_pinned': true,
        'locked_at': '2026-07-16T20:05:00Z',
      });

      expect(post.isPending, isTrue);
      expect(post.isPinned, isTrue);
      expect(post.isLocked, isTrue);
      expect(post.needsAttention, isTrue);
    });
  });
}
