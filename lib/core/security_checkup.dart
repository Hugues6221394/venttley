/// Facts the Security Center checkup can show, derived from real account
/// state rather than a static "password is always OK".
class SecurityCheckup {
  const SecurityCheckup({
    required this.passwordChangedAt,
    required this.twoFactorOn,
    required this.hasRealEmail,
    required this.emailVerified,
  });

  final DateTime? passwordChangedAt;
  final bool twoFactorOn;
  final bool hasRealEmail;
  final bool emailVerified;

  bool get passwordRotated => passwordChangedAt != null;
  bool get recoveryOk => hasRealEmail && emailVerified;

  String get passwordLabel => passwordRotated
      ? 'Password has been rotated'
      : 'Password has never been rotated';

  String get twoFactorLabel => twoFactorOn
      ? 'Two-factor authentication is on'
      : 'Turn on two-factor authentication';

  String get recoveryLabel => recoveryOk
      ? 'Recovery email verified'
      : hasRealEmail
      ? 'Confirm your recovery email'
      : 'Add a recovery email';

  int get coveredCount =>
      (passwordRotated ? 1 : 0) + (twoFactorOn ? 1 : 0) + (recoveryOk ? 1 : 0);

  static const int totalSteps = 3;
}
