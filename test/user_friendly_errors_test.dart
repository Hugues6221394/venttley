import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/user_friendly_errors.dart';

void main() {
  test('a block refusal is explained, not retried', () {
    const error = 'PostgrestException(message: blocked_by_user, code: P0001)';

    expect(UserFriendlyErrors.isPermanent(error), isTrue);
    expect(
      UserFriendlyErrors.message(error),
      'You can\'t contact this person. One of you has blocked the other.',
    );
    expect(UserFriendlyErrors.isPermanent(TimeoutException()), isFalse);
  });

  test('a fake image is explained and not retried', () {
    const error =
        'UnsupportedImageFormatException: That file is not a JPEG, PNG, GIF, WebP or HEIC image.';
    expect(UserFriendlyErrors.isPermanent(error), isTrue);
    expect(
      UserFriendlyErrors.message(error),
      'That file is not a JPEG, PNG, GIF, WebP or HEIC image.',
    );
  });

  test('a missing Keeper agreement says what to do about it', () {
    // Raised by create_managed_tribe_idempotent when p_keeper_attested is not
    // true. The bare identifier is what actually reaches the client.
    expect(
      UserFriendlyErrors.message(
        Exception('PostgrestException(message: keeper_attestation_required)'),
      ),
      'Please confirm the Keeper agreement before creating your Tribe.',
    );
  });

  test('an app newer than its database does not say "try again"', () {
    // PGRST202 means PostgREST found no function of that shape — the app is
    // ahead of the migrations. The generic fallback invited people to keep
    // pressing a button that could not work until somebody deployed, which is
    // exactly what happened when the Keeper agreement added two parameters to
    // create_managed_tribe_idempotent.
    const error =
        'PostgrestException(message: Could not find the function '
        'public.create_managed_tribe_idempotent(...) in the schema cache, '
        'code: PGRST202)';
    expect(
      UserFriendlyErrors.message(error),
      'Venttly is being updated right now. Please try again in a few minutes.',
    );
    // And it must win over the generic fallback rather than land on it.
    expect(UserFriendlyErrors.message(error), isNot(contains('try again.')));
  });
  // ---- Sign-up and sign-in -------------------------------------------
  //
  // The two strings below were copied off a simulator, not invented. They
  // are what a stranger creating an account actually read.

  test('a short password is a sentence, not an exception', () {
    const error =
        'AuthWeakPasswordException(message: Password should be at least 12 '
        'characters., statusCode: 422, reasons: [length])';
    expect(
      UserFriendlyErrors.message(error),
      'Please choose a longer password — at least 12 characters.',
    );
  });

  test('the password length comes from the server, not from us', () {
    // Raising the minimum in the Supabase dashboard must not need a release.
    const error =
        'AuthWeakPasswordException(message: Password should be at least 16 '
        'characters., statusCode: 422, reasons: [length])';
    expect(UserFriendlyErrors.message(error), contains('16 characters'));
  });

  // The three below are the responses production actually returns, captured
  // by posting to /auth/v1/signup with a handle that exists. Written from the
  // wire rather than from what the error was assumed to be: the first version
  // of this mapper read "Database error saving new user" as a taken handle,
  // which would have told a twelve-year-old to pick another name.

  test('a handle lost in the race says so', () {
    const error =
        'AuthApiException(message: {"code":"23505","message":"duplicate key '
        'value violates unique constraint '
        '\\"users_pseudonym_lower_unique\\"","detail":"Key '
        '(lower(anonymous_pseudonym::text))=(first_light) already exists."}, '
        'statusCode: 500)';
    expect(
      UserFriendlyErrors.message(error),
      'That handle was taken a moment ago. Pick another and try again.',
    );
    // And the handle is not read back out of a Postgres detail line.
    expect(UserFriendlyErrors.message(error), isNot(contains('lower(')));
  });

  test('…and still says so once the database stops naming its constraint', () {
    // What migration 20261076090000 raises instead. The app has to read both,
    // because it ships ahead of the database it talks to.
    expect(
      UserFriendlyErrors.message(
        'AuthApiException(message: {"code":"P0001","message":'
        '"pseudonym_taken","hint":"That handle is already in use."}, '
        'statusCode: 500)',
      ),
      'That handle was taken a moment ago. Pick another and try again.',
    );
  });

  test('the age floor is not reported as a naming problem', () {
    const error =
        'AuthApiException(message: {"code":"P0001","message":'
        '"age_below_minimum","hint":"Venttly is not available under 13."}, '
        'statusCode: 500)';
    expect(
      UserFriendlyErrors.message(error),
      'Venttly is for members aged 13 and over.',
    );
    expect(UserFriendlyErrors.message(error), isNot(contains('handle')));
  });

  test('GoTrue\'s own wrapper does not claim to know what went wrong', () {
    // This message replaces the database's, so it cannot be read as any
    // particular cause -- only as "the write failed".
    const error =
        'AuthRetryableFetchException(message: {"code":"unexpected_failure",'
        '"message":"Database error saving new user"}, statusCode: 500)';
    final message = UserFriendlyErrors.message(error);
    expect(message, contains('try again'));
    expect(message, isNot(contains('handle')));
    expect(message, isNot(contains('13')));
  });

  test('a database grant is not a microphone', () {
    // This rule used to match a bare "permission", so Postgres's "permission
    // denied for table profiles" sent somebody to the iOS Settings app to
    // grant a microphone they had never been asked for.
    const error =
        'PostgrestException(message: permission denied for table profiles, '
        'code: 42501)';
    final message = UserFriendlyErrors.message(error);
    expect(message, isNot(contains('Settings')));
    expect(message, contains('permission'));
  });

  test('a half-finished signup does not blame the person\'s account', () {
    // Authentication succeeds, the profile row is missing because the trigger
    // never ran. Read as a permission problem this sends somebody to check an
    // account that is not what is wrong.
    expect(
      UserFriendlyErrors.message(
        StateError('Signed in but no matching profile row'),
      ),
      contains('didn\'t finish'),
    );
  });

  test('a taken email points at signing in', () {
    expect(
      UserFriendlyErrors.message(
        'AuthApiException(message: User already registered, statusCode: 422)',
      ),
      contains('Sign in instead'),
    );
  });

  test('wrong credentials do not read as a permissions problem', () {
    expect(
      UserFriendlyErrors.message(
        'AuthApiException(message: Invalid login credentials, '
        'statusCode: 400)',
      ),
      'That username or password didn\'t work. Double-check and try again.',
    );
  });

  // The guard that matters most: whatever the backend says, none of its
  // vocabulary reaches a person. Every string here is one a real client can
  // raise, and the test is deliberately about shape rather than wording, so
  // it keeps holding as the copy is edited.
  test('no backend vocabulary ever reaches a person', () {
    const raws = [
      'AuthWeakPasswordException(message: Password should be at least 12 '
          'characters., statusCode: 422, reasons: [length])',
      'AuthRetryableFetchException(message: {"code":"unexpected_failure",'
          '"message":"Database error saving new user"}, statusCode: 500)',
      'AuthApiException(message: Invalid login credentials, statusCode: 400)',
      'PostgrestException(message: permission denied for table profiles, '
          'code: 42501)',
      'PostgrestException(message: new row violates row-level security '
          'policy, code: 42501)',
      'SocketException: Failed host lookup',
      'AuthApiException(message: Email not confirmed, statusCode: 400)',
      'AuthApiException(message: Token has expired or is invalid, '
          'statusCode: 403)',
    ];
    for (final raw in raws) {
      final message = UserFriendlyErrors.message(raw);
      expect(message, isNot(contains('Exception')), reason: raw);
      expect(message, isNot(contains('statusCode')), reason: raw);
      expect(message, isNot(contains('code:')), reason: raw);
      expect(message, isNot(contains('{')), reason: raw);
      // Something was actually said, rather than an empty box.
      expect(message.length, greaterThan(12), reason: raw);
    }
  });
}

class TimeoutException implements Exception {
  @override
  String toString() => 'TimeoutException: offline';
}
