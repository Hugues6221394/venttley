/// What makes a password acceptable, said in advance rather than after.
///
/// These rules mirror what Supabase Auth enforces on the project (twelve
/// characters, with lower case, upper case, digits and symbols). Duplicating
/// them here is not the client deciding security policy — the server still
/// refuses anything that does not comply. It is so that somebody typing a
/// password is told what is wrong while they are typing it, instead of filling
/// in a whole sign-up form and being handed "Password is too weak" by an API.
///
/// The weak-base check is the part the class rules cannot do. "Password123!"
/// satisfies every rule above and is among the first things any
/// credential-stuffing list tries. Stripping the decoration and looking at the
/// word underneath catches it, and catches "p@ssw0rd!!1" with it.
library;

class PasswordPolicy {
  const PasswordPolicy._();

  /// Matches the project's Supabase setting. Changing one without the other
  /// puts the app back to guessing what the server will accept.
  static const int minLength = 12;

  /// The alphabetic cores of a password — plain, and with leetspeak undone.
  ///
  /// Two, not one, because a single pass cannot do both jobs. Stripping
  /// non-letters reduces "Password123!" to "password" but leaves "p@ssw0rd"
  /// as "psswrd". Substituting digits for letters first fixes "p@ssw0rd" but
  /// turns the trailing "123!" of "Password123!" into letters, giving
  /// "passwordiei" — which matches nothing.
  ///
  /// So both readings are produced and either one matching is enough. Crude on
  /// purpose: this is meant to catch the handful of shapes behind most
  /// guessable passwords, not to be a cracker.
  static Set<String> cores(String password) {
    final lower = password.toLowerCase();

    // Reading one: drop everything that is not a letter. Catches the common
    // shape of a word with digits and symbols bolted on the end.
    final plain = lower.replaceAll(RegExp('[^a-z]'), '');

    // Reading two: shave the decoration off each end FIRST, then undo the
    // letter/number substitutions in what is left. Un-leeting the whole string
    // would turn a trailing "2026!" into letters and leave "passwordo", which
    // matches nothing — the substitutions are only meaningful inside the word.
    final trimmed = lower
        .replaceAll(RegExp('^[^a-z]+'), '')
        .replaceAll(RegExp(r'[^a-z]+$'), '');
    final unLeet = trimmed
        .replaceAll('@', 'a')
        .replaceAll('4', 'a')
        .replaceAll('3', 'e')
        .replaceAll('1', 'i')
        .replaceAll('0', 'o')
        .replaceAll(r'$', 's')
        .replaceAll('5', 's')
        .replaceAll('7', 't')
        .replaceAll(RegExp('[^a-z]'), '');

    return {plain, unLeet}..removeWhere((c) => c.length < 3);
  }

  /// The first problem with [password], or null when it is acceptable.
  ///
  /// One problem at a time, and the most basic first: a list of five
  /// complaints is a wall someone gives up on, where "needs a symbol" is
  /// something they can act on.
  static String? problem(String password, {Set<String> weakBases = const {}}) {
    if (password.length < minLength) {
      return 'Use at least $minLength characters.';
    }
    if (!password.contains(RegExp('[a-z]'))) {
      return 'Add a lower case letter.';
    }
    if (!password.contains(RegExp('[A-Z]'))) {
      return 'Add a capital letter.';
    }
    if (!password.contains(RegExp('[0-9]'))) {
      return 'Add a number.';
    }
    if (!password.contains(RegExp(r'[^A-Za-z0-9]'))) {
      return 'Add a symbol, like ! or ?';
    }

    if (cores(password).any(weakBases.contains)) {
      // Named rather than vague. "Too weak" leaves someone adding another
      // exclamation mark to a password that will still be guessed.
      return 'This is a very common password underneath — try words that '
          'mean something only to you.';
    }

    if (_isSingleRepeatedCharacter(password)) {
      return 'Try something less repetitive.';
    }

    return null;
  }

  static bool _isSingleRepeatedCharacter(String password) {
    if (password.isEmpty) return false;
    final first = password[0];
    return password.split('').every((c) => c == first);
  }
}
