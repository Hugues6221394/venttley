import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MFA login is single-flight and requires a restored session', () {
    final recovery = File(
      'lib/presentation/screens/onboarding/recover_screen.dart',
    ).readAsStringSync();

    expect(recovery, contains('var verifying = false'));
    expect(recovery, contains('onPressed: verifying'));
    expect(recovery, contains("ref.read(sessionProvider) == null"));
    expect(recovery, contains('your session could not be restored'));
    expect(recovery, contains('ModalTextControllerScope('));
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

    expect(adminUser, contains('createRequiredAuthAdminClient()'));
    expect(adminUser, contains('auth.admin.updateUserById(id'));
    expect(adminUser, contains('actorProfile?.user_role !== "super_admin"'));
    expect(adminUser, contains('actorProfile.account_status !== "active"'));
    expect(adminUser, contains('if (pw.length < 12)'));
    expect(adminUser, contains('.select("recovery_blob")'));
    expect(adminUser, contains('recoveryState.recovery_blob'));
    expect(adminUser, contains('protected by a recovery phrase'));
    expect(adminUser, isNot(contains('rpc("admin_reset_user_password"')));
    expect(server, contains('SUPABASE_SERVICE_ROLE_KEY'));
    expect(server, contains('detectSessionInUrl: false'));
    expect(
      migration,
      contains('FROM PUBLIC, anon, authenticated, service_role'),
    );
  });
}
