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
}

class TimeoutException implements Exception {
  @override
  String toString() => 'TimeoutException: offline';
}
