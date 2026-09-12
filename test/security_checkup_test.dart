import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/security_checkup.dart';
import 'package:vently_app/domain/entities/entities.dart';

RecoveryMethods _methods({
  bool emailVerified = false,
  bool emailSet = false,
  bool phoneVerified = false,
  bool phoneSet = false,
}) => RecoveryMethods(
  email: RecoveryMethod(
    masked: (emailSet || emailVerified) ? 'do***@gmail.com' : null,
    verified: emailVerified,
    pending: emailSet && !emailVerified,
  ),
  phone: RecoveryMethod(
    masked: (phoneSet || phoneVerified) ? '+250 ** *** 891' : null,
    verified: phoneVerified,
    pending: phoneSet && !phoneVerified,
  ),
);

void main() {
  test('an unrotated password is not a completed checkup item', () {
    final checkup = SecurityCheckup(
      passwordChangedAt: null,
      twoFactorOn: true,
      recovery: _methods(emailVerified: true),
    );
    expect(checkup.passwordRotated, isFalse);
    expect(checkup.passwordLabel, 'Password has never been rotated');
    expect(checkup.coveredCount, 2);
  });

  test('a rotation stamp counts, and the three doors are independent', () {
    final checkup = SecurityCheckup(
      passwordChangedAt: DateTime.utc(2026, 8, 29),
      twoFactorOn: false,
      recovery: _methods(),
    );
    expect(checkup.passwordRotated, isTrue);
    expect(checkup.passwordLabel, 'Password has been rotated');
    expect(checkup.twoFactorOn, isFalse);
    expect(checkup.recoveryOk, isFalse);
    expect(checkup.coveredCount, 1);
  });

  // The bug this group exists for: the checkup used to read the account's login
  // email, which for an anonymous account is a synthetic @id.venttly.app
  // address. So the card said "Add a recovery email" and counted zero while the
  // row beneath it said do***@gmail.com was verified. Two parts of one screen
  // disagreeing about the same fact reads as a broken app.
  group('the recovery step follows the recovery methods, not the login email', () {
    test('a verified recovery email clears the step', () {
      final checkup = SecurityCheckup(
        passwordChangedAt: null,
        twoFactorOn: false,
        recovery: _methods(emailVerified: true),
      );
      expect(checkup.recoveryOk, isTrue);
      expect(checkup.recoveryLabel, 'Recovery email verified');
      expect(checkup.coveredCount, 1);
    });

    test('a verified phone alone also clears it — one route is enough', () {
      final checkup = SecurityCheckup(
        passwordChangedAt: null,
        twoFactorOn: false,
        recovery: _methods(phoneVerified: true),
      );
      expect(checkup.recoveryOk, isTrue);
      expect(checkup.recoveryLabel, 'Recovery phone verified');
    });

    test('both verified is still one step, not two', () {
      final checkup = SecurityCheckup(
        passwordChangedAt: null,
        twoFactorOn: false,
        recovery: _methods(emailVerified: true, phoneVerified: true),
      );
      expect(checkup.coveredCount, 1);
      expect(checkup.recoveryLabel, 'Recovery email and phone verified');
    });

    test('an unconfirmed address does not count and says so', () {
      final checkup = SecurityCheckup(
        passwordChangedAt: null,
        twoFactorOn: false,
        recovery: _methods(emailSet: true),
      );
      expect(checkup.recoveryOk, isFalse);
      expect(checkup.recoveryLabel, 'Confirm your recovery email');
      expect(checkup.coveredCount, 0);
    });

    test('an unconfirmed phone names the phone, not the email', () {
      final checkup = SecurityCheckup(
        passwordChangedAt: null,
        twoFactorOn: false,
        recovery: _methods(phoneSet: true),
      );
      expect(checkup.recoveryLabel, 'Confirm your recovery phone');
    });

    test('before the load answers, the step is neutral and uncounted', () {
      // Null means "we have not asked yet". It must not be counted as covered,
      // and must not claim anything about what the person has configured.
      const checkup = SecurityCheckup(
        passwordChangedAt: null,
        twoFactorOn: false,
        recovery: null,
      );
      expect(checkup.recoveryOk, isFalse);
      expect(checkup.coveredCount, 0);
      expect(checkup.recoveryLabel, 'Add a recovery email');
    });
  });
}
