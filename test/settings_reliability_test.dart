import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings use live identity data and role-aware owner access', () {
    final settings = File(
      'lib/presentation/screens/settings/settings_screen.dart',
    ).readAsStringSync();
    final providers = File('lib/core/providers.dart').readAsStringSync();
    final passwordSecurity = File(
      'lib/presentation/screens/profile/password_security_screen.dart',
    ).readAsStringSync();
    final blockedAccounts = File(
      'lib/presentation/widgets/blocked_accounts_sheet.dart',
    ).readAsStringSync();
    final controllerScope = File(
      'lib/presentation/widgets/modal_text_controller_scope.dart',
    ).readAsStringSync();

    expect(settings, contains('profilePhotoUrl: me.profilePhotoUrl'));
    expect(settings, contains('me?.isPlug == true'));
    expect(settings, contains("'Super Admin'"));
    expect(
      settings,
      isNot(contains("if (me?.userRole == 'plug')")),
    );
    expect(
      providers,
      matches(RegExp(r'try \{\s+await _repo\.logout\(\);\s+\} finally \{')),
    );
    expect(
      providers,
      matches(
        RegExp(
          r'try \{\s+await _repo\.signOutEverywhere\(\);\s+\} finally \{',
        ),
      ),
    );
    expect(
      passwordSecurity,
      contains("Couldn\\'t verify that code. Check your connection"),
    );
    // These were counts — "3 sheets, 3 scopes" — which described a structure
    // rather than a requirement, and broke the moment three near-identical
    // sheets were consolidated into one. What actually matters is asserted
    // directly instead, and it holds however the screen is arranged.

    // Every sheet clears the floating nav. HomeShell paints its pill over the
    // branch, so a sheet on the branch navigator has its lower rows swallowed.
    expect(
      'useRootNavigator: true'.allMatches(passwordSecurity).length,
      'showModalBottomSheet'.allMatches(passwordSecurity).length,
      reason: 'every bottom sheet must use the root navigator',
    );

    // No controller is created by hand, so every one of them comes from
    // ModalTextControllerScope and is therefore disposed. Stronger than
    // counting scopes: it forbids the bypass rather than counting the fix.
    expect(
      'TextEditingController('.allMatches(passwordSecurity).length,
      0,
      reason: 'text controllers must come from ModalTextControllerScope',
    );

    // Every sheet that takes text is scrollable, or the keyboard overflows it
    // on a small screen.
    expect(
      'SingleChildScrollView('.allMatches(passwordSecurity).length,
      greaterThanOrEqualTo(
        'ModalTextControllerScope('.allMatches(passwordSecurity).length,
      ),
      reason: 'each text-entry sheet must scroll with the keyboard up',
    );
    expect(controllerScope, contains('controller.dispose()'));
    expect(settings, contains('useRootNavigator: true'));
    expect(blockedAccounts, contains('useRootNavigator: true'));
  });
}
