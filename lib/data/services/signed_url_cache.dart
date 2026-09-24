import 'dart:async';

/// Signed URLs for private storage, minted once and reused until they expire.
///
/// A chat photo lives in a private bucket, so rendering it needs a signed URL.
/// Every bubble minted its own, in initState, on every mount — so scrolling a
/// conversation issued a network round trip per image before anything could be
/// drawn.
///
/// The round trip was the smaller half. A signed URL carries an issued-at
/// stamp and a signature, so two calls a second apart return two different
/// strings for the same object. CachedNetworkImage keys its cache on the URL
/// unless told otherwise — so every mount produced a new key, missed the
/// cache, and downloaded the whole image again. The byte cache had never once
/// been hit for chat media. That is what "even when they were viewed before
/// they really take long to load" is.
///
/// This fixes the round trip. The cache key is fixed separately, at each call
/// site, by passing the storage path as `cacheKey` — both halves are needed
/// and neither is sufficient.
class SignedUrlCache {
  SignedUrlCache({
    required Future<String> Function(String path) mint,
    Duration ttl = const Duration(hours: 1),
    Duration safetyMargin = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _mint = mint,
       _ttl = ttl,
       _margin = safetyMargin,
       _now = clock ?? DateTime.now;

  final Future<String> Function(String path) _mint;
  final Duration _ttl;

  /// Retired this far before the real expiry.
  ///
  /// A URL handed out at 59 minutes is valid when the widget builds and dead
  /// by the time a slow connection finishes fetching it, which reads as a
  /// broken image rather than an expired link.
  final Duration _margin;

  final DateTime Function() _now;

  final Map<String, _Entry> _entries = {};

  /// In-flight mints, so ten bubbles appearing at once ask once.
  final Map<String, Future<String>> _pending = {};

  Future<String> urlFor(String path) {
    final cached = _entries[path];
    if (cached != null && cached.expiresAt.isAfter(_now())) {
      return Future.value(cached.url);
    }

    final inFlight = _pending[path];
    if (inFlight != null) return inFlight;

    final future = _mint(path)
        .then((url) {
          _entries[path] = _Entry(
            url: url,
            expiresAt: _now().add(_ttl - _margin),
          );
          return url;
        })
        // A block body, not an arrow. Map.remove returns the value it removed
        // — here, this very future — and whenComplete waits on a future its
        // callback returns. The arrow form made every call wait on its own
        // completion and hang forever.
        .whenComplete(() {
          _pending.remove(path);
        });

    _pending[path] = future;
    return future;
  }

  /// The URL if one is already held, without going to the network.
  ///
  /// Lets a widget paint on its first frame instead of flashing a spinner for
  /// an image it has the address of.
  String? cachedUrlFor(String path) {
    final cached = _entries[path];
    if (cached == null || !cached.expiresAt.isAfter(_now())) return null;
    return cached.url;
  }

  void clear() {
    _entries.clear();
    _pending.clear();
  }

  int get length => _entries.length;
}

class _Entry {
  const _Entry({required this.url, required this.expiresAt});
  final String url;
  final DateTime expiresAt;
}
