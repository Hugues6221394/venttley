import '../domain/entities/entities.dart';

/// Facts the Security Center checkup can show, derived from real account
/// state rather than a static "password is always OK".
///
/// The recovery step deliberately does NOT look at the account's login email.
/// Every anonymous account signs in with a synthetic `@id.venttly.app` address,
/// so a checkup keyed on that can never be satisfied — it told people to "add a
/// recovery email" while the row directly beneath it said one was verified.
/// What the step is really asking is "if you lost this password, is there a way
/// back in?", and the answer to that lives in the recovery methods.
class SecurityCheckup {
  const SecurityCheckup({
    required this.passwordChangedAt,
    required this.twoFactorOn,
    required this.recovery,
  });

  final DateTime? passwordChangedAt;
  final bool twoFactorOn;

  /// Null while the first load is still in flight. Treated as "not yet
  /// covered" for counting, but the labels stay neutral so the card does not
  /// accuse someone of having no recovery route before we have asked.
  final RecoveryMethods? recovery;

  bool get passwordRotated => passwordChangedAt != null;

  /// One verified route is enough to recover an account, so one is enough to
  /// clear the step. A pending address recovers nothing and does not count.
  bool get recoveryOk => (recovery?.verifiedCount ?? 0) > 0;

  bool get _recoveryPending =>
      recovery != null &&
      !recoveryOk &&
      (!recovery!.email.isEmpty || !recovery!.phone.isEmpty);

  String get passwordLabel => passwordRotated
      ? 'Password has been rotated'
      : 'Password has never been rotated';

  String get twoFactorLabel => twoFactorOn
      ? 'Two-factor authentication is on'
      : 'Turn on two-factor authentication';

  String get recoveryLabel {
    final methods = recovery;
    if (methods == null) return 'Add a recovery email';

    final email = methods.email.verified;
    final phone = methods.phone.verified;
    if (email && phone) return 'Recovery email and phone verified';
    if (email) return 'Recovery email verified';
    if (phone) return 'Recovery phone verified';

    if (_recoveryPending) {
      // Something was entered but never confirmed. Say which, because the
      // remaining action is to go and type a code, not to add an address.
      if (!methods.email.isEmpty) return 'Confirm your recovery email';
      return 'Confirm your recovery phone';
    }
    return 'Add a recovery email';
  }

  int get coveredCount =>
      (passwordRotated ? 1 : 0) + (twoFactorOn ? 1 : 0) + (recoveryOk ? 1 : 0);

  static const int totalSteps = 3;
}
