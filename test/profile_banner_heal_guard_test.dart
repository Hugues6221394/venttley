import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/supabase_backend.dart';

/// The self-heal for a dangling `profile_banner_url` deletes a row's column, so
/// the predicate that authorises it is the whole safety story. It must fire on a
/// provably absent object and on nothing else — a transient 403 or a 502 that
/// cleared someone's background would be a silent data loss they never asked
/// for and cannot undo.
void main() {
  group('isMissingStorageObject', () {
    test('accepts the shape Supabase actually returns for a missing key', () {
      // Real body, captured from the failing banner that prompted this guard.
      const body =
          '{"statusCode":"404","error":"not_found",'
          '"message":"Object not found","code":"NoSuchKey"}';
      expect(SupabaseBackend.isMissingStorageObject(400, body), isTrue);
    });

    test('accepts a literal 404 whatever the body says', () {
      expect(SupabaseBackend.isMissingStorageObject(404, ''), isTrue);
      expect(SupabaseBackend.isMissingStorageObject(404, 'not json'), isTrue);
    });

    test('is case-insensitive about the marker', () {
      expect(
        SupabaseBackend.isMissingStorageObject(400, '{"code":"nosuchkey"}'),
        isTrue,
      );
    });

    test('refuses a bare 400 with no missing-object marker', () {
      // A 400 alone proves nothing — malformed request, bad bucket name, a
      // gateway rewriting the response.
      expect(SupabaseBackend.isMissingStorageObject(400, ''), isFalse);
      expect(
        SupabaseBackend.isMissingStorageObject(400, '{"error":"bad_request"}'),
        isFalse,
      );
    });

    test('refuses every not-authorised answer', () {
      // The dangerous case: a bucket policy change or an expired token would
      // otherwise wipe the background of every user who opened their profile.
      for (final status in [401, 403]) {
        expect(
          SupabaseBackend.isMissingStorageObject(
            status,
            '{"error":"not_found"}',
          ),
          isFalse,
          reason: '$status must never authorise a clear',
        );
      }
    });

    test('refuses server errors and redirects', () {
      for (final status in [301, 302, 429, 500, 502, 503, 504]) {
        expect(
          SupabaseBackend.isMissingStorageObject(status, 'NoSuchKey'),
          isFalse,
          reason: '$status must never authorise a clear',
        );
      }
    });

    test('refuses success', () {
      expect(SupabaseBackend.isMissingStorageObject(200, ''), isFalse);
      // Even if the bytes happen to contain the marker text.
      expect(
        SupabaseBackend.isMissingStorageObject(200, 'NoSuchKey'),
        isFalse,
      );
    });
  });
}
