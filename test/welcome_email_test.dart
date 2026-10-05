import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The welcome email had a template and no sender.
///
/// email-dispatcher has carried a `welcome` template since it was written, and
/// not one had ever been sent: queue_email is an RPC the client calls, and no
/// signup screen called it. The template was real, the sender was configured,
/// and the feature did not exist. These hold both halves together.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final dispatcher = read('supabase/functions/email-dispatcher/index.ts');
  final migration = read(
    'supabase/migrations/20261076090000_a_welcome_worth_reading.sql',
  );

  group('something actually queues it', () {
    test('a trigger on auth.users queues the welcome template', () {
      expect(migration, contains("'welcome'"));
      expect(migration, contains('public.email_outbox'));
      expect(migration, contains('CREATE TRIGGER on_auth_welcome_email'));
    });

    test('it covers the confirmed-at-insert and confirmed-later edges', () {
      // A provider sign-in arrives already confirmed; an email signup is
      // confirmed minutes later, often in a mail client with the app closed.
      expect(migration, contains('AFTER INSERT OR UPDATE OF email_confirmed_at'));
    });

    test('it never mails a synthetic handle', () {
      // The anonymous flow signs in as <handle>@id.venttly.app, which has no
      // inbox — and the outbox CHECK refuses that domain, so queueing one
      // would turn a welcome into a failed insert on somebody's signup.
      expect(migration, contains('@id.venttly.app'));
    });

    test('it sends once per account, ever', () {
      expect(migration, contains('EXISTS'));
      expect(migration, contains("template = 'welcome'"));
    });

    test('and does not mail everybody who is already here', () {
      expect(
        migration.toLowerCase(),
        contains('no backfill'),
        reason: 'a backfill would welcome accounts weeks old, and 45 seeded '
            'community rows at addresses that do not exist',
      );
    });
  });

  group('the mail looks like Venttly', () {
    test('every template goes through the one branded shell', () {
      // Six templates, one set of colours and one footer. A second hand-rolled
      // layout is how the set drifts apart.
      final templates = [
        'welcome',
        'verify_email',
        'password_reset',
        'security_alert',
        'security_account_change',
        'weekly_digest',
      ];
      for (final name in templates) {
        final start = dispatcher.indexOf('  $name: {');
        expect(start, greaterThan(-1), reason: '$name is gone');
        final body = dispatcher.substring(start, start + 2200);
        expect(
          body,
          contains('shell({'),
          reason: '$name does not use the branded shell',
        );
      }
    });

    test('the brand colours are the app’s brand colours', () {
      // lib/presentation/theme/colors.dart. Literals rather than an import,
      // because this runs in Deno nowhere near the Flutter app — so a test is
      // what keeps them in step.
      final colours = read('lib/presentation/theme/colors.dart');
      for (final hex in ['E0245E', 'A81145', 'FDF8FA', 'FBE9F0', 'F3E4EA']) {
        expect(dispatcher, contains(hex), reason: 'email lost $hex');
        expect(colours, contains(hex), reason: 'the app lost $hex');
      }
    });

    test('the wordmark is text, not an image', () {
      // Mail clients block remote images by default. A brand that only exists
      // in an <img> is a brand most recipients never see.
      expect(dispatcher, contains('>Venttly</div>'));
      expect(dispatcher, contains('BRAND_LOGO_URL'));
    });

    test('every email says why it arrived, and says something true', () {
      // One shared footer claimed "somebody created an account with this
      // address" on all six, which is false on a security alert.
      expect(dispatcher, contains('options.reason'));
      expect(
        dispatcher,
        contains('cannot be switched off'),
        reason: 'security mail must not imply it is optional',
      );
    });

    test('it ships a text part as well as HTML', () {
      expect(dispatcher, contains('text: (v) =>'));
    });

    test('the welcome email carries the thing it is for', () {
      final start = dispatcher.indexOf('  welcome: {');
      final body = dispatcher.substring(start, start + 4000);
      expect(body, contains('kindness'));
      expect(body.toLowerCase(), contains('worst day'));
    });
  });
}
