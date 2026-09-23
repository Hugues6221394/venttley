import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Applying for verification, and being told when it lands.
///
/// Two faults, reported together.
///
/// The affordance somebody actually finds — the pill on their own profile —
/// opened a bottom sheet with one free-text box. VerificationApplyScreen, with
/// a category picker, public links and a private evidence field, already
/// existed and was reachable only from Settings. So the route people took
/// submitted the weakest possible application: a paragraph, where the form
/// would have given the reviewer a category and a link to check.
///
/// And an approval changed users.is_verified server-side while AppUser stayed
/// as it was loaded at sign-in, so the badge did not appear until the next
/// cold start. Somebody was told they were verified and could not see it
/// anywhere, which reads as the approval not having worked.
void main() {
  final profile = File(
    'lib/presentation/screens/profile/profile_overview.dart',
  ).readAsStringSync();
  final form = File(
    'lib/presentation/screens/settings/verification_screen.dart',
  ).readAsStringSync();
  final listener = File(
    'lib/presentation/widgets/notification_foreground_listener.dart',
  ).readAsStringSync();

  test('the profile pill opens the full form, not a one-field sheet', () {
    expect(
      profile,
      contains('VerificationApplyScreen()'),
      reason: 'the pill should reach the same form Settings does',
    );
    expect(
      profile,
      isNot(contains('showModalBottomSheet<void>(\n      context: context,\n      useRootNavigator: true,\n      useSafeArea: true,\n      isScrollControlled: true,\n      backgroundColor: Theme.of(context).colorScheme.surface,\n      shape: const RoundedRectangleBorder(\n        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),\n      ),\n      builder: (ctx) => ModalTextControllerScope(')),
      reason: 'the one-field apply sheet should be gone, not merely bypassed',
    );
  });

  test('the form asks for structure, and the free text is optional', () {
    // A category picker, links and private evidence are what a reviewer can
    // act on. The note is where you say what those cannot.
    for (final field in const [
      'Which of these fits best?',
      'Public links',
      'Anything private that supports it',
    ]) {
      expect(form, contains(field), reason: '$field is missing from the form');
    }

    expect(
      form,
      contains("hint: 'Optional. The reviewer reads this first.'"),
      reason: 'the note should be optional',
    );
    expect(
      form,
      isNot(contains('_note.text.trim().length < 20')),
      reason:
          'a 20-character floor turns the one free-form field into another '
          'required one, and an application whose case is a link has nothing '
          'to write there',
    );

    // Something has to be submitted, though — a bare category is not an
    // application, it is a checkbox.
    expect(form, contains('_linkList.isEmpty &&'));
  });

  test('an approval refreshes the badge without a restart', () {
    expect(
      listener,
      contains("n.payload['action'] == 'verification_approved'"),
      reason: 'nothing notices the approval, so the badge waits for a restart',
    );
    expect(
      listener,
      contains('sessionProvider.notifier).restore()'),
      reason: 'is_verified lives on the session, so the session must reload',
    );
    expect(
      listener,
      contains('myVerificationStatusProvider'),
      reason: 'the application state has its own providers to invalidate',
    );
  });
}
