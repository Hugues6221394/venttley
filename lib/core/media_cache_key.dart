/// A cache key that stays the same when the URL does not.
///
/// Private storage is read through a signed URL, and a signed URL carries an
/// issued-at stamp and a signature — so two mints a second apart are two
/// different strings for the same object. CachedNetworkImage keys on the URL
/// unless told otherwise, which made every mount a new key, a guaranteed miss
/// and a full re-download. The byte cache had never once been hit for a chat
/// photo or a group avatar.
///
/// Only signed URLs are rewritten. A public URL is left exactly as it is,
/// because `_bustedPublicUrl` deliberately appends `?v=<stamp>` so that a
/// replaced tribe image is re-fetched rather than served from the old bytes —
/// stripping the query there would reintroduce the bug it exists to prevent.
String stableMediaCacheKey(String url) {
  // Supabase signs at /storage/v1/object/sign/<bucket>/<path>?token=...
  if (!url.contains('/object/sign/')) return url;
  final q = url.indexOf('?');
  return q < 0 ? url : url.substring(0, q);
}
