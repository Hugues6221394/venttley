import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MFA login is single-flight and requires a restored session', () {
    final recovery = File(
      'lib/presentation/screens/onboarding/recover_screen.dart',
    ).readAsStringSync();
    final phone = File(
      'lib/presentation/screens/onboarding/phone_signin_screen.dart',
    ).readAsStringSync();
    final challenge = File(
      'lib/presentation/screens/onboarding/mfa_challenge_screen.dart',
    ).readAsStringSync();
    final router = File('lib/presentation/router/app_router.dart').readAsStringSync();

    expect(recovery, contains("context.go('/onboarding/mfa')"));
    expect(phone, contains("context.go('/onboarding/mfa')"));
    expect(router, contains("path: '/onboarding/mfa'"));
    expect(router, contains('pendingMfaFactorIdProvider'));
    expect(challenge, contains('var verifying = false'));
    expect(challenge, contains('onPressed: verifying'));
    expect(challenge, contains("ref.read(sessionProvider) == null"));
    expect(challenge, contains('your session could not be restored'));
    expect(challenge, contains('ModalTextControllerScope('));
  });

  test('onboarding async work cannot update disposed screens', () {
    final emailSignup = File(
      'lib/presentation/screens/onboarding/email_signup_screen.dart',
    ).readAsStringSync();
    final identity = File(
      'lib/presentation/screens/onboarding/identity_screen.dart',
    ).readAsStringSync();
    final verifyEmail = File(
      'lib/presentation/screens/onboarding/verify_email_screen.dart',
    ).readAsStringSync();

    expect(
      emailSignup,
      matches(
        RegExp(
          r'showDatePicker\([\s\S]*?if \(!mounted\) return;[\s\S]*?'
          r'setState\(\(\) => _birthDate = picked\)',
        ),
      ),
    );
    expect(
      identity,
      matches(
        RegExp(
          r'showDatePicker\([\s\S]*?if \(!mounted\) return;[\s\S]*?'
          r'setState\(\(\) => _birthDate = picked\)',
        ),
      ),
    );
    expect(verifyEmail, contains('if (mounted) _send(initial: true)'));
  });

  test('MFA enrollment verification is single-flight', () {
    final security = File(
      'lib/presentation/screens/profile/security_screen.dart',
    ).readAsStringSync();

    expect(security, contains('var verifying = false'));
    expect(security, contains('onPressed: verifying'));
    expect(security, contains('verifying = true'));
    expect(security, contains('ModalTextControllerScope('));
    expect(security, contains('useRootNavigator: true'));
  });

  test('admin password resets use the supported server-only Auth API', () {
    final adminUser = File(
      'admin/app/(dashboard)/users/[userId]/page.tsx',
    ).readAsStringSync();
    final server = File('admin/lib/supabase/server.ts').readAsStringSync();
    final migration = File(
      'supabase/migrations/'
      '20260728174036_retire_direct_auth_password_mutation.sql',
    ).readAsStringSync();

    final guards = File(
      'supabase/migrations/'
      '20261003090000_admin_aal2_and_session_revocation.sql',
    ).readAsStringSync();

    // GoTrue owns the password hash, so the mutation stays on the Auth Admin
    // API and must never go back to direct SQL.
    expect(adminUser, contains('createRequiredAuthAdminClient()'));
    expect(adminUser, contains('auth.admin.updateUserById(id'));
    expect(adminUser, isNot(contains('rpc("admin_reset_user_password"')));
    expect(server, contains('SUPABASE_SERVICE_ROLE_KEY'));
    expect(server, contains('detectSessionInUrl: false'));
    expect(
      migration,
      contains('FROM PUBLIC, anon, authenticated, service_role'),
    );

    // The Server Action authorizes through the database and records the
    // result there, rather than deciding for itself.
    expect(adminUser, contains('rpc("admin_authorize_password_reset"'));
    expect(adminUser, contains('rpc("admin_finalize_password_reset"'));

    // These guards used to be inline TypeScript in the Server Action, and
    // this test pinned them there. They now live in the RPC, which binds
    // every caller rather than only this one form — so assert them where
    // they are actually enforced. A guard checked in the page is a guard a
    // direct PostgREST call skips.
    expect(guards, contains("is_staff(auth.uid(), ARRAY['super_admin'])"));
    expect(guards, contains('private.require_aal2()'));
    expect(guards, contains('recovery_blob IS NOT NULL'));
    expect(guards, contains('protected by a recovery phrase'));

    // The 12-character minimum is enforced in the Server Action and nowhere
    // else. It cannot move into admin_authorize_password_reset, because that
    // RPC deliberately never receives the password — passing plaintext into
    // Postgres would put it in statement parameters and logs. GoTrue's own
    // floor (config.toml minimum_password_length) is 8, so 12 is this
    // console's policy rather than a platform guarantee. Raising the GoTrue
    // floor would bind every path including signup, which is a product
    // decision, not a side effect of an admin refactor.
    expect(adminUser, contains('pw.length < 12'));
    expect(adminUser, contains('pw.length > 200'));
  });
}
