import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/password_policy.dart';

void main() {
  const bases = {'password', 'venttly', 'iloveyou', 'letmein'};

  group('PasswordPolicy.cores', () {
    test('strips decoration down to the word underneath', () {
      expect(PasswordPolicy.cores('Password123!'), contains('password'));
      expect(PasswordPolicy.cores('VENTTLY_2026'), contains('venttly'));
      expect(PasswordPolicy.cores('  i Love You !! '), contains('iloveyou'));
    });

    test('a trailing year does not pollute the de-leeted reading', () {
      // "P@ssword2026!" un-leeted whole becomes "passwordo" — the 0 in 2026
      // turns into a letter. Trimming the ends first is what keeps it
      // reducing to "password".
      expect(PasswordPolicy.cores('P@ssword2026!'), contains('password'));
      expect(PasswordPolicy.cores('P@ssw0rd!!12'), contains('password'));
    });

    test('undoes the common letter/number substitutions', () {
      // Without this, p@ssw0rd reduces to "psswrd" and slips past the list —
      // which is precisely the password the list exists to catch.
      expect(PasswordPolicy.cores('P@ssw0rd'), contains('password'));
      expect(PasswordPolicy.cores('l3tm31n'), contains('letmein'));
    });

    test('both readings are kept when they disagree', () {
      // "P@ssw0rd!!12" reads as "psswrd" plainly and "password" de-leeted.
      // Only the second matches, so keeping just one reading would miss it.
      final result = PasswordPolicy.cores('P@ssw0rd!!12');
      expect(result, containsAll(<String>['psswrd', 'password']));
    });

    test('one reading is enough when they agree', () {
      // "Password123!" needs no substitution, so both readings land on the
      // same word and the set collapses. Nothing is lost.
      expect(PasswordPolicy.cores('Password123!'), {'password'});
    });
  });

  group('PasswordPolicy.problem', () {
    test('mirrors the server rules, one complaint at a time', () {
      expect(PasswordPolicy.problem('short'), 'Use at least 12 characters.');
      expect(
        PasswordPolicy.problem('ALLUPPERCASE1!'),
        'Add a lower case letter.',
      );
      expect(PasswordPolicy.problem('alllowercase1!'), 'Add a capital letter.');
      expect(PasswordPolicy.problem('NoDigitsHere!!'), 'Add a number.');
      expect(
        PasswordPolicy.problem('NoSymbolsHere1'),
        'Add a symbol, like ! or ?',
      );
    });

    test('rejects a common word however it is dressed up', () {
      // Each of these satisfies every length and character-class rule, which
      // is the whole reason this check exists.
      for (final candidate in [
        'Password123!', // decoration on the end
        'P@ssw0rd!!12', // leetspeak inside, decoration outside
        'Venttly2026!', // the product's own name
        'P@ssword2026!', // both at once
      ]) {
        expect(
          PasswordPolicy.problem(candidate, weakBases: bases),
          contains('very common'),
          reason: '$candidate should have been refused',
        );
      }
    });

    test('accepts a genuinely unusual password', () {
      expect(
        PasswordPolicy.problem('Rusizi-Ferry-9pm!', weakBases: bases),
        isNull,
      );
    });

    test('an unreachable wordlist does not block sign-up', () {
      // The list is fetched over the network and may not arrive. When it does
      // not, everything else must still apply and a good password must still
      // be accepted — never a hard failure at the moment someone joins.
      expect(PasswordPolicy.problem('Rusizi-Ferry-9pm!'), isNull);
      expect(PasswordPolicy.problem('Password123!'), isNull);
    });

    test('catches a single repeated character that passes nothing else', () {
      expect(PasswordPolicy.problem('aaaaaaaaaaaa'), isNotNull);
    });
  });
}
