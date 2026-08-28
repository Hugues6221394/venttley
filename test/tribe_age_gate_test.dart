import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// The 18+ floor on Tribe creation is a child-safety boundary: it decides who
/// gets authority over a space 13–17 year olds are in. The decision itself is
/// the server's — private.tribe_creation_age_status — and these tests pin the
/// contract the client depends on, plus the one property that matters most:
/// nothing except an explicit 'adult' is ever treated as permission.
void main() {
  group('TribeCreationEligibility', () {
    test('only an explicit adult may create', () {
      expect(
        const TribeCreationEligibility(
          status: 'adult',
          tribesKept: 0,
        ).canCreate,
        isTrue,
      );
      for (final status in ['minor', 'month_required']) {
        expect(
          TribeCreationEligibility(status: status, tribesKept: 0).canCreate,
          isFalse,
          reason: '$status must not be treated as permission',
        );
      }
    });

    test('an unrecognised status is a refusal, not an allowance', () {
      // If the server ever grows a fourth status, the client must fail closed.
      // Defaulting the other way would open the floor by accident.
      for (final status in ['', 'unknown', 'pending', 'ADULT']) {
        expect(
          TribeCreationEligibility(status: status, tribesKept: 0).canCreate,
          isFalse,
          reason: '"$status" must not read as adult',
        );
      }
    });

    test('only month_required asks the extra question', () {
      expect(
        const TribeCreationEligibility(
          status: 'month_required',
          tribesKept: 0,
        ).needsBirthMonth,
        isTrue,
      );
      // A minor must never be shown the month sheet: answering it cannot help,
      // and asking implies the refusal is negotiable.
      expect(
        const TribeCreationEligibility(
          status: 'minor',
          tribesKept: 0,
        ).needsBirthMonth,
        isFalse,
      );
      expect(
        const TribeCreationEligibility(
          status: 'adult',
          tribesKept: 0,
        ).needsBirthMonth,
        isFalse,
      );
    });

    test('keeping Tribes already does not bypass the floor', () {
      // is_keeper_mode counts owned Tribes, so an account that somehow holds
      // one must still be judged on age for the next.
      expect(
        const TribeCreationEligibility(
          status: 'minor',
          tribesKept: 3,
        ).canCreate,
        isFalse,
      );
    });
  });
}
