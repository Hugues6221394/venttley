import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/connection.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/data/services/draft_store.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/compose/compose_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

import 'helpers/memory_sensitive_store.dart';

void main() {
  group('post authoring reliability contract', () {
    late String migration;
    late String styleMigration;
    late String styleVisibilityMigration;

    setUpAll(() {
      migration = File(
        'supabase/migrations/20260716212500_post_authoring_reliability.sql',
      ).readAsStringSync();
      styleMigration = File(
        'supabase/migrations/20260727132714_post_card_colors.sql',
      ).readAsStringSync();
      styleVisibilityMigration = File(
        'supabase/migrations/20260727142156_post_card_colors_visibility_repair.sql',
      ).readAsStringSync();
    });

    test('canonical post RPC matches the current posts schema', () {
      final createStart = migration.indexOf(
        'CREATE FUNCTION public.create_post_idempotent',
      );
      final createEnd = migration.indexOf(
        'REVOKE ALL ON FUNCTION public.create_post_idempotent',
      );
      final createFunction = migration.substring(createStart, createEnd);

      expect(createFunction, isNot(contains('is_audio,')));
      expect(createFunction, contains('audio_url'));
      expect(createFunction, contains('space does not belong to tribe'));
      expect(createFunction, contains('private.existing_client_mutation'));
      expect(createFunction, contains('private.complete_client_mutation'));
      expect(createFunction, contains('SET search_path = public, pg_temp'));
      expect(createFunction, contains('p_poll_question TEXT DEFAULT NULL'));
      expect(createFunction, contains('INSERT INTO public.post_polls'));
      expect(createFunction, contains('INSERT INTO public.poll_options'));
    });

    test('legacy Plug ownership and posting features are repaired', () {
      expect(migration, contains('INSERT INTO public.tribe_members'));
      expect(migration, contains("DO UPDATE SET role = 'keeper'"));
      expect(migration, contains('guard_tribe_poll_write'));
      expect(migration, contains('polls_disabled_for_tribe'));
      expect(migration, contains("NOTIFY pgrst, 'reload schema'"));
    });

    test('creators can edit and soft-delete their own posts at any age', () {
      final editStart = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.edit_post',
      );
      final deleteStart = migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.delete_post',
      );
      final editFunction = migration.substring(editStart, deleteStart);

      expect(editFunction, contains('v_post.author_id <> v_me'));
      expect(editFunction, contains('edited_at = now()'));
      expect(editFunction, isNot(contains('15 minutes')));
      expect(migration, contains('deleted_at = COALESCE(deleted_at, now())'));
    });

    test('vent styles are validated and persisted atomically', () {
      final backend = File(
        'lib/data/services/supabase_backend.dart',
      ).readAsStringSync();
      final outbox = File('lib/data/services/outbox.dart').readAsStringSync();

      expect(styleMigration, contains('posts_card_background_color_check'));
      expect(styleMigration, contains('posts_card_text_color_check'));
      expect(
        styleMigration,
        contains('CREATE OR REPLACE FUNCTION public.create_post_idempotent_v2'),
      );
      expect(styleMigration, contains('p.card_background_color'));
      expect(styleMigration, contains('p.card_text_color'));
      expect(
        styleVisibilityMigration,
        contains('private.can_view_post_author(p.author_id)'),
      );
      expect(
        styleVisibilityMigration,
        isNot(contains('u.shadow_banned IS NOT TRUE')),
      );
      expect(backend, contains("'create_post_idempotent_v4'"));
      expect(backend, contains("'p_card_background_color'"));
      expect(backend, contains("'post.read_after_write_degraded'"));
      expect(
        backend,
        contains(
          'A transient feed-view or\n'
          '      // schema-cache failure must not queue the same mutation',
        ),
      );
      expect(outbox, contains("payload['cardBackgroundColor']"));
    });

    test('composer prevents overflow and partial poll posts', () {
      final composer = File(
        'lib/presentation/screens/compose/compose_screen.dart',
      ).readAsStringSync();
      final card = File(
        'lib/presentation/widgets/post_card.dart',
      ).readAsStringSync();

      expect(composer, contains('scrollDirection: Axis.horizontal'));
      expect(composer, contains('Polls are disabled in this Tribe.'));
      expect(composer, contains('pollQuestion: _includePoll'));
      expect(composer, isNot(contains('Posted, but poll failed')));
      expect(composer, contains('composeTargetSpaceProvider.notifier'));
      expect(card, contains('final next = nextContent.trim();'));
      expect(
        card,
        contains(
          'if (next.isEmpty && !post.hasImage && !post.hasAudio) return;',
        ),
      );
      expect(
        card,
        contains("throw StateError('The post update was not accepted.');"),
      );
      expect(
        card,
        contains("throw StateError('The post deletion was not accepted.');"),
      );
      expect(card, isNot(contains('15-minute edit window')));
    });

    testWidgets('composer stays composed on a compact phone', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = VentlyRepository(forceMock: true);
      final draftStore = await DraftStore.openWithStore(
        MemorySensitiveStore(),
        userId: 'post-author',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repository),
            sessionProvider.overrideWith((ref) => _TestSessionController()),
            draftStoreProvider.overrideWith((ref) async => draftStore),
            myPersonasProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: VentlyTheme.light(),
            home: const ComposeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('New Vent'), findsOneWidget);
      expect(find.text('Photo'), findsOneWidget);
      expect(find.text('Poll'), findsOneWidget);
      expect(find.text('Style'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('24h Story'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _TestSessionController extends SessionController {
  _TestSessionController() : super(VentlyRepository(forceMock: true)) {
    state = const AppUser(
      userId: 'post-author',
      anonymousPseudonym: 'SoftSignal',
      avatarSeed: 'soft-signal',
      currentMood: 'hopeful',
      userRole: 'normal',
      isVerified: true,
      safetyTier: 'standard',
      accountStatus: 'active',
      emailVerified: true,
    );
  }
}
