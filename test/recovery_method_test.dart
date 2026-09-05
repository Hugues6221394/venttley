import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// The row shape here comes from my_recovery_methods, and PostgREST hands back
/// a plain map — a column the server does not return is simply an absent key,
/// indistinguishable from a real null. That has caused several bugs in this
/// project, so every reading below is pinned against a partial payload rather
/// than a complete one.
void main() {
  group('RecoveryMethod reads a partial payload safely', () {
    test('an older server with no address still reports "configured"', () {
      // Before 20260913090000 the server only sent the masked form. If isEmpty
      // keyed on address alone, this row would claim the account has no
      // recovery method at all — a frightening and wrong thing to display.
      final method = RecoveryMethod.fromJson({
        'masked': 'do***@gmail.com',
        'verified': true,
      });
      expect(method.isEmpty, isFalse);
      expect(method.display, 'do***@gmail.com');
      expect(method.verified, isTrue);
    });

    test('the full address wins over the masked one when both arrive', () {
      final method = RecoveryMethod.fromJson({
        'address': 'do.real@gmail.com',
        'masked': 'do***@gmail.com',
        'verified': true,
      });
      expect(method.display, 'do.real@gmail.com');
    });

    test('a genuinely unset method is empty', () {
      final method = RecoveryMethod.fromJson({
        'address': null,
        'masked': null,
        'verified': false,
      });
      expect(method.isEmpty, isTrue);
      expect(method.display, isNull);
    });

    test('an absent verified key is not verified', () {
      // The safe reading of a missing key for anything security-shaped is the
      // one that grants nothing.
      final method = RecoveryMethod.fromJson({'address': 'a@b.com'});
      expect(method.verified, isFalse);
    });

    test('a pending change is carried separately from the live address', () {
      // The two must never collapse into one field. That collapse is exactly
      // what let a requested change overwrite a verified address.
      final method = RecoveryMethod.fromJson({
        'address': 'do.real@gmail.com',
        'masked': 'do***@gmail.com',
        'verified': true,
        'pending_address': 'co.new@gmail.com',
        'pending': true,
      });
      expect(method.address, 'do.real@gmail.com');
      expect(method.verified, isTrue, reason: 'the working route survives');
      expect(method.pendingAddress, 'co.new@gmail.com');
      expect(method.display, 'do.real@gmail.com');
    });

    test('no pending change leaves pendingAddress null', () {
      final method = RecoveryMethod.fromJson({
        'address': 'do.real@gmail.com',
        'verified': true,
      });
      expect(method.pendingAddress, isNull);
    });
  });

  group('RecoveryMethods counts only what actually recovers an account', () {
    test('verified email and unverified phone counts one', () {
      final methods = RecoveryMethods.fromJson({
        'email': {'address': 'a@b.com', 'verified': true},
        'phone': {'address': '+250788123456', 'verified': false},
      });
      expect(methods.verifiedCount, 1);
    });

    test('a pending change does not add a route', () {
      final methods = RecoveryMethods.fromJson({
        'email': {
          'address': 'a@b.com',
          'verified': true,
          'pending_address': 'c@d.com',
        },
        'phone': const <String, Object?>{},
      });
      expect(methods.verifiedCount, 1);
    });

    test('missing sections do not throw', () {
      final methods = RecoveryMethods.fromJson(const <String, Object?>{});
      expect(methods.verifiedCount, 0);
      expect(methods.email.isEmpty, isTrue);
      expect(methods.phone.isEmpty, isTrue);
    });
  });
}
