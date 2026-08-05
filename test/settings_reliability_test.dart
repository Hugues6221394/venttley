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
    expect(
      'useRootNavigator: true'.allMatches(passwordSecurity).length,
      3,
    );
    expect(
      'SingleChildScrollView('.allMatches(passwordSecurity).length,
      greaterThanOrEqualTo(3),
    );
    expect(
      'ModalTextControllerScope('.allMatches(passwordSecurity).length,
      3,
    );
    expect(controllerScope, contains('controller.dispose()'));
    expect(settings, contains('useRootNavigator: true'));
    expect(blockedAccounts, contains('useRootNavigator: true'));
  });
}
