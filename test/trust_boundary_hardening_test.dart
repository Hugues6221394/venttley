import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/identity_service.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  test('AppUser copyWith preserves unknown/completed age unless explicit', () {
    const completed = AppUser(
      userId: 'age-user',
      anonymousPseudonym: 'AgeUser',
      avatarSeed: 'age-seed',
      currentMood: 'calm',
      userRole: 'normal',
      isVerified: false,
      safetyTier: 'restricted_minor',
      accountStatus: 'active',
      birthYear: 2010,
    );

    expect(completed.copyWith(currentMood: 'hopeful').birthYear, 2010);
    expect(completed.copyWith(birthYear: null).birthYear, isNull);
  });

  test(
    'recovery phrase opens the resealed new password after rotation',
    () async {
      final identity = IdentityService();
      const phrase =
          'anchor bamboo candle dawn ember forest gentle harbor island journey kindle lantern';

      final oldMaterial = await identity.sealPassword(
        password: 'old-password-123',
        phrase: phrase,
      );
      final newMaterial = await identity.sealPassword(
        password: 'new-password-456',
        phrase: phrase,
      );

      expect(
        await identity.openPassword(
          blob: oldMaterial.blob,
          salt: oldMaterial.salt,
          phrase: phrase,
        ),
        'old-password-123',
      );
      expect(
        await identity.openPassword(
          blob: newMaterial.blob,
          salt: newMaterial.salt,
          phrase: phrase,
        ),
        'new-password-456',
      );
      expect(
        await identity.openPassword(
          blob: newMaterial.blob,
          salt: newMaterial.salt,
          phrase: 'wrong phrase',
        ),
        isNull,
      );
    },
  );

  test('password mutation has rollback and recovery rotation steps', () {
    final repository = File(
      'lib/data/repositories/vently_repository.dart',
    ).readAsStringSync();
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();

    expect(repository, contains('await live.reauthenticate(currentPassword)'));
    expect(repository, contains('recoveredPassword != currentPassword'));
    expect(repository, contains('password: newPassword'));
    expect(repository, contains('await _setPasswordWithReadback('));
    expect(repository, contains('intendedPassword: newPassword'));
    expect(repository, contains('fallbackPassword: currentPassword'));
    expect(repository, contains('await live.rotateRecoveryMaterial('));
    expect(repository, contains('final rotationCommitted ='));
    expect(repository, contains('final oldMaterialIntact ='));
    expect(backend, contains("'rotate_my_recovery_material'"));
  });

  test('unknown-age sessions are routed to mandatory server completion', () {
    final router = File(
      'lib/presentation/router/app_router.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/presentation/screens/onboarding/age_completion_screen.dart',
    ).readAsStringSync();

    expect(router, contains('session.birthYear == null'));
    expect(router, contains("return '/onboarding/age'"));
    expect(screen, contains('.completeAgeVerification(birthDate)'));
    expect(screen, contains('We store only your birth year'));
    expect(screen, contains('Semantics('));
  });

  test('service workers require secrets, canonical reads, and kill switches', () {
    final config = File('supabase/config.toml').readAsStringSync();
    final fanout = File(
      'supabase/functions/notification-fanout/index.ts',
    ).readAsStringSync();
    final scan = File(
      'supabase/functions/media-scan/index.ts',
    ).readAsStringSync();
    final summary = File(
      'supabase/functions/space-summary-batch/index.ts',
    ).readAsStringSync();
    final email = File(
      'supabase/functions/email-dispatcher/index.ts',
    ).readAsStringSync();
    final payment = File(
      'supabase/functions/payment-webhook/index.ts',
    ).readAsStringSync();
    final purge = File(
      'supabase/functions/account-purge/index.ts',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260811222118_harden_trust_boundaries.sql',
    ).readAsStringSync();

    expect(config, contains('[functions.notification-fanout]'));
    expect(config, contains('[functions.space-summary-batch]'));
    expect(fanout, contains('envName: "WEBHOOK_SECRET"'));
    expect(fanout, contains('rolloutEnabled("PUSH_DELIVERY_ENABLED")'));
    expect(fanout, contains('supabase.rpc("enqueue_push_event"'));
    expect(fanout, isNot(contains('encrypted_payload')));
    expect(scan, contains('sb.auth.getUser(token)'));
    expect(scan, contains('storedRow.author_id !== callerId'));
    expect(scan, contains('storedRow.media_status !== "pending"'));
    expect(scan, contains('sb.rpc("claim_media_scan"'));
    expect(scan, contains('sb.rpc("complete_media_scan_verdict"'));
    expect(summary, contains('supabase.rpc("collect_space_mood_counts"'));
    expect(summary, isNot(contains('collect_space_vent_corpus')));
    expect(summary, isNot(contains('api.groq.com')));
    expect(email, contains('verifyInternalSecret(req'));
    expect(email, contains('claim_email_deliveries'));
    expect(email, contains('"Idempotency-Key"'));
    expect(payment, contains('constructEventAsync'));
    expect(payment, contains('apply_stripe_subscription_event'));
    expect(purge, contains('legal_hold_lookup_failed'));
    expect(
      migration.indexOf('CREATE TABLE IF NOT EXISTS public.media_scan_jobs'),
      lessThan(
        migration.indexOf(
          'CREATE OR REPLACE FUNCTION public.trust_boundary_health()',
        ),
      ),
      reason:
          'SQL-language functions must not reference a relation before it exists',
    );
  });

  test('staging promotion deploys the hardened privileged workers', () {
    final workflow = File(
      '.github/workflows/staging-supabase.yml',
    ).readAsStringSync();

    expect(
      workflow,
      contains('supabase functions deploy media-scan --use-api'),
    );
    expect(
      workflow,
      contains('supabase functions deploy notification-fanout --use-api'),
    );
    expect(workflow, contains('--no-verify-jwt'));
    expect(
      workflow,
      contains('supabase/functions/_shared/internal_auth_test.ts'),
    );
    expect(
      workflow,
      contains('supabase/functions/media-scan/ownership_test.ts'),
    );
  });

  test('production worker promotion is protected and revalidated', () {
    final workflow = File(
      '.github/workflows/production-supabase-functions.yml',
    ).readAsStringSync();

    expect(workflow, contains('environment: production'));
    expect(workflow, contains('DEPLOY HARDENED FUNCTIONS TO PRODUCTION'));
    expect(workflow, contains('secrets.SUPABASE_PRODUCTION_ACCESS_TOKEN'));
    expect(
      workflow,
      contains('supabase functions deploy media-scan --use-api'),
    );
    expect(
      workflow,
      contains('supabase functions deploy notification-fanout --use-api'),
    );
    expect(workflow, contains('--no-verify-jwt'));
    expect(
      workflow,
      contains('supabase/functions/_shared/internal_auth_test.ts'),
    );
    expect(
      workflow,
      contains('supabase/functions/media-scan/ownership_test.ts'),
    );
  });

  test('internal SECURITY DEFINER helpers are not public RPCs', () {
    final migration = File(
      'supabase/migrations/20260816001834_revoke_internal_security_definer_helpers.sql',
    ).readAsStringSync();
    final pgTap = File(
      'supabase/tests/database/0009_internal_helper_acl.test.sql',
    ).readAsStringSync();

    for (final helper in ['_notify', '_notify_mentions', '_writer_state']) {
      expect(migration, contains('public.$helper'));
      expect(pgTap, contains('public.$helper'));
    }
    expect(migration, contains('FROM PUBLIC, anon, authenticated'));
    expect(migration, contains('TO service_role'));
    expect(pgTap, contains("'authenticated'"));
    expect(pgTap, contains("'anon'"));
  });
}
