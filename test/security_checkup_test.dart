import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/security_checkup.dart';

void main() {
  test('an unrotated password is not a completed checkup item', () {
    const checkup = SecurityCheckup(
      passwordChangedAt: null,
      twoFactorOn: true,
      hasRealEmail: true,
      emailVerified: true,
    );
    expect(checkup.passwordRotated, isFalse);
    expect(checkup.passwordLabel, 'Password has never been rotated');
    expect(checkup.coveredCount, 2);
  });

  test('a rotation stamp counts, and the three doors are independent', () {
    final checkup = SecurityCheckup(
      passwordChangedAt: DateTime.utc(2026, 8, 29),
      twoFactorOn: false,
      hasRealEmail: false,
      emailVerified: false,
    );
    expect(checkup.passwordRotated, isTrue);
    expect(checkup.passwordLabel, 'Password has been rotated');
    expect(checkup.twoFactorOn, isFalse);
    expect(checkup.recoveryOk, isFalse);
    expect(checkup.coveredCount, 1);
  });
}
