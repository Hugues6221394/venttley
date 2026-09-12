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
    expect(
      UserFriendlyErrors.message(error),
      isNot(contains('try again.')),
    );
  });
}

class TimeoutException implements Exception {
  @override
  String toString() => 'TimeoutException: offline';
}
