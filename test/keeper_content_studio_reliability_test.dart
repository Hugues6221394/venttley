import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/data/services/mock_backend.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/keeper_content_studio_sheet.dart';
import 'package:vently_app/presentation/widgets/keeper_prompt_composer_sheet.dart';

void main() {
  group('Keeper Content Studio reliability', () {
    test('every Studio action has a concrete destination and target', () {
      final studio = File(
        'lib/presentation/widgets/keeper_content_studio_sheet.dart',
      ).readAsStringSync();
      final router = File(
        'lib/presentation/router/app_router.dart',
      ).readAsStringSync();
      final prompt = File(
        'lib/presentation/widgets/keeper_prompt_composer_sheet.dart',
      ).readAsStringSync();
      final memberSurfaces = [
        File(
          'lib/presentation/screens/home/keeper_members_screen.dart',
        ).readAsStringSync(),
        File(
          'lib/presentation/screens/keeper/keeper_comod_screen.dart',
        ).readAsStringSync(),
      ].join();

      expect(studio, isNot(contains('/manage?tab=')));
      expect(memberSurfaces, isNot(contains('/manage?tab=')));
      expect(memberSurfaces, contains('/manage/settings/members'));
      expect(studio, contains('composeTargetTribeProvider.notifier'));
      expect(studio, contains('composeTargetSpaceProvider.notifier'));
      expect(studio, contains('manage/settings/content?action=pin'));
      expect(studio, contains('manage/settings/identity?focus=welcome'));
      expect(studio, contains('manage/settings/spaces?create=true'));
      expect(studio, contains('manage/settings/rules'));
      expect(prompt, contains('.schedulePrompt('));
      expect(router, contains("queryParameters['focus'] == 'welcome'"));
      expect(router, contains("queryParameters['create'] == 'true'"));
      expect(router, contains("queryParameters['filter']"));
      expect(router, contains("queryParameters['action']"));
    });

    testWidgets('all eight Studio actions fit a compact phone', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [primaryKeeperTribeProvider.overrideWithValue(_testTribe)],
          child: MaterialApp(
            theme: VentlyTheme.light(),
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showKeeperContentStudioSheet(context, ref),
                    child: const Text('Open Studio'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Studio'));
      await tester.pumpAndSettle();

      for (final label in const [
        'Prompt',
        'Poll',
        'Announcement',
        'Pin post',
        'Schedule',
        'Welcome msg',
        'New space',
        'Rules',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('prompt publishing persists through the repository', (
      tester,
    ) async {
      final repository = VentlyRepository(forceMock: true);
      const tribeId = 'content-studio-prompt-test';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            theme: VentlyTheme.light(),
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () =>
                        showKeeperPromptComposer(context, tribeId: tribeId),
                    child: const Text('Create prompt'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Create prompt'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'What helped you feel grounded today?',
      );
      await tester.tap(find.text('Post prompt'));
      await tester.pumpAndSettle();

      final prompts = await repository.tribePrompts(tribeId);
      expect(prompts.last.text, 'What helped you feel grounded today?');
      expect(prompts.last.publishedAt, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('scheduled prompts remain pending until their future time', (
      tester,
    ) async {
      final repository = VentlyRepository(forceMock: true);
      const tribeId = 'content-studio-schedule-test';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            theme: VentlyTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showKeeperPromptComposer(
                      context,
                      tribeId: tribeId,
                      scheduleRequired: true,
                    ),
                    child: const Text('Schedule'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'What would make tomorrow gentler?',
      );
      await tester.tap(find.text('Schedule prompt').last);
      await tester.pumpAndSettle();

      final prompts = await repository.tribePrompts(tribeId);
      expect(prompts.last.scheduledFor, isNotNull);
      expect(prompts.last.scheduledFor!.isAfter(DateTime.now()), isTrue);
      expect(prompts.last.publishedAt, isNull);
      expect(tester.takeException(), isNull);
    });

    test(
      'Space lifecycle persists create, update, archive, restore and delete',
      () async {
        final mock = MockBackend.instance;
        addTearDown(mock.logout);
        final user = AppUser(
          userId: 'studio-owner-${DateTime.now().microsecondsSinceEpoch}',
          anonymousPseudonym: 'StudioOwner',
          avatarSeed: 'studio-owner',
          currentMood: 'hopeful',
          userRole: 'plug',
          isVerified: true,
          safetyTier: 'standard',
          accountStatus: 'active',
        );
        mock.registerSession(user);
        final repository = VentlyRepository(mock: mock, forceMock: true);
        final tribe = await repository.createTribe(
          name: 'Workflow ${DateTime.now().microsecondsSinceEpoch}',
          category: 'support',
          idempotencyKey: 'test-${DateTime.now().microsecondsSinceEpoch}',
        );

        final initial = await repository.spacesByTribe(tribe.tribeId);
        expect(initial.single.isDefault, isTrue);

        final spaceId = await repository.manageTribeSpace(
          tribeId: tribe.tribeId,
          action: 'create',
          name: 'Weekly Wins',
          description: 'Celebrate meaningful progress.',
          weeklyTheme: 'One small win',
          iconName: 'spark',
          postingPermission: 'members',
          isPinned: true,
        );
        var space = await repository.spaceById(spaceId);
        expect(space?.name, 'Weekly Wins');
        expect(space?.isPinned, isTrue);

        await repository.manageTribeSpace(
          tribeId: tribe.tribeId,
          action: 'update',
          spaceId: spaceId,
          name: 'Weekly Bright Spots',
          postingPermission: 'mods',
        );
        space = await repository.spaceById(spaceId);
        expect(space?.name, 'Weekly Bright Spots');
        expect(space?.postingPermission, 'mods');

        await repository.manageTribeSpace(
          tribeId: tribe.tribeId,
          action: 'archive',
          spaceId: spaceId,
          reason: 'Season complete',
        );
        expect((await repository.spaceById(spaceId))?.isArchived, isTrue);

        await repository.manageTribeSpace(
          tribeId: tribe.tribeId,
          action: 'restore',
          spaceId: spaceId,
        );
        expect((await repository.spaceById(spaceId))?.isArchived, isFalse);

        await repository.manageTribeSpace(
          tribeId: tribe.tribeId,
          action: 'delete',
          spaceId: spaceId,
          reason: 'Merged into General',
        );
        expect(await repository.spaceById(spaceId), isNull);
        expect(
          (await repository.spacesByTribe(tribe.tribeId)).single.isDefault,
          isTrue,
        );
      },
    );

    test('Space management RPC remains owner-gated and audited', () {
      final migration = File(
        'supabase/migrations/20260716175655_tribe_lifecycle_management.sql',
      ).readAsStringSync();
      final start = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.manage_tribe_space',
      );
      final end = migration.indexOf(
        'REVOKE ALL ON FUNCTION public.manage_tribe_space',
      );
      final function = migration.substring(start, end);

      expect(function, contains('require_tribe_owner'));
      expect(function, contains("WHEN 'archive'"));
      expect(function, contains("WHEN 'restore'"));
      expect(function, contains("WHEN 'delete'"));
      expect(function, contains('log_tribe_action'));
      expect(function, contains('cannot_delete_default_space'));
    });
  });
}

final _testTribe = Tribe(
  tribeId: 'tribe-studio',
  name: 'Quiet Mornings',
  slug: 'quiet-mornings',
  category: 'support',
  memberCount: 20,
  isPrivate: false,
  createdAt: DateTime.utc(2026, 7, 1),
  keeperId: 'keeper-studio',
  keeperPseudonym: 'StudioKeeper',
);
