import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/media_cache_key.dart';
import 'package:vently_app/data/services/signed_url_cache.dart';

/// Why a photo you had already seen took as long the second time.
///
/// Chat media lives in a private bucket, so rendering it needs a signed URL,
/// and a signed URL carries an issued-at stamp and a signature — two mints a
/// second apart are two different strings for the same object. Confirmed
/// against the local stack: signing the same file twice returned tokens ending
/// ...725 and ...727, with entirely different signatures.
///
/// CachedNetworkImage keys its cache on the URL unless told otherwise. So
/// every mount produced a new key, missed, and downloaded the whole image
/// again. The byte cache had never been hit once.
///
/// Two halves, and neither is sufficient alone: a stable cache key so the
/// bytes are found, and a URL cache so finding them does not need a round trip
/// first.
void main() {
  group('the cache key', () {
    test('a signed URL keys on the object, not the token', () {
      const a =
          'https://x.supabase.co/storage/v1/object/sign/chat-media/room/a.jpg'
          '?token=eyJhbGciOi.FIRST';
      const b =
          'https://x.supabase.co/storage/v1/object/sign/chat-media/room/a.jpg'
          '?token=eyJhbGciOi.SECOND';

      expect(a, isNot(b), reason: 'the URLs genuinely differ');
      expect(
        stableMediaCacheKey(a),
        stableMediaCacheKey(b),
        reason: 'but they are the same photo, so they must share a key',
      );
    });

    test('and a busted public URL is left alone', () {
      // _bustedPublicUrl appends ?v=<stamp> on purpose, so that replacing a
      // tribe image actually re-fetches it. Stripping the query here would
      // reintroduce the exact bug that exists to prevent.
      const first =
          'https://x.supabase.co/storage/v1/object/public/post-media/t.jpg'
          '?v=111';
      const second =
          'https://x.supabase.co/storage/v1/object/public/post-media/t.jpg'
          '?v=222';

      expect(stableMediaCacheKey(first), first);
      expect(
        stableMediaCacheKey(first),
        isNot(stableMediaCacheKey(second)),
        reason: 'a replaced image must still be re-fetched',
      );
    });

    test('a plain URL is returned unchanged', () {
      const url = 'https://example.test/a.png';
      expect(stableMediaCacheKey(url), url);
    });
  });

  group('the URL cache', () {
    test('mints once and reuses', () async {
      var mints = 0;
      final cache = SignedUrlCache(
        mint: (path) async {
          mints++;
          return '$path?token=$mints';
        },
      );

      expect(await cache.urlFor('room/a.jpg'), 'room/a.jpg?token=1');
      expect(await cache.urlFor('room/a.jpg'), 'room/a.jpg?token=1');
      expect(mints, 1, reason: 'the second bubble must not go to the network');
    });

    test('ten bubbles appearing at once ask once', () async {
      // Opening a conversation mounts every visible image in the same frame.
      var mints = 0;
      final cache = SignedUrlCache(
        mint: (path) async {
          mints++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return '$path?token=$mints';
        },
      );

      final urls = await Future.wait(
        List.generate(10, (_) => cache.urlFor('room/a.jpg')),
      );

      expect(mints, 1);
      expect(urls.toSet(), hasLength(1));
    });

    test('a URL close to expiry is replaced rather than handed out', () async {
      // A link valid when the widget builds and dead before a slow connection
      // finishes fetching it reads as a broken image, not an expired link.
      var now = DateTime(2026, 3, 1, 12);
      var mints = 0;
      final cache = SignedUrlCache(
        mint: (path) async {
          mints++;
          return '$path?token=$mints';
        },
        ttl: const Duration(hours: 1),
        safetyMargin: const Duration(minutes: 10),
        clock: () => now,
      );

      await cache.urlFor('room/a.jpg');
      now = now.add(const Duration(minutes: 45));
      expect(await cache.urlFor('room/a.jpg'), 'room/a.jpg?token=1');

      // Past 50 minutes: still valid to the server, but retired here.
      now = now.add(const Duration(minutes: 10));
      expect(await cache.urlFor('room/a.jpg'), 'room/a.jpg?token=2');
      expect(mints, 2);
    });

    test('a known URL is available without waiting', () async {
      // Lets the bubble paint on its first frame instead of flashing a
      // spinner for an image it already has the address of.
      final cache = SignedUrlCache(mint: (path) async => '$path?token=x');

      expect(cache.cachedUrlFor('room/a.jpg'), isNull);
      await cache.urlFor('room/a.jpg');
      expect(cache.cachedUrlFor('room/a.jpg'), 'room/a.jpg?token=x');
    });

    test('different objects do not share an entry', () async {
      final cache = SignedUrlCache(mint: (path) async => '$path?token=x');

      await cache.urlFor('room/a.jpg');
      await cache.urlFor('room/b.jpg');

      expect(cache.length, 2);
      expect(cache.cachedUrlFor('room/b.jpg'), 'room/b.jpg?token=x');
    });
  });
}
