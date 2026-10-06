
/// The avatars somebody can choose, and where they live.
///
/// Ten characters across ages and genders, drawn by CODAFRIQA in the same
/// language as the welcome screen. They replace a letter on a hashed colour —
/// "W on teal" is not recognisably a person, and it was the first thing a
/// reader saw beside every vent in the feed.
///
/// The ids are what the database stores, so they must never be renumbered: an
/// account that chose a07 keeps a07 forever. New characters get new ids on the
/// end.
class AvatarPresets {
  const AvatarPresets._();

  static const ids = <String>[
    'a01',
    'a02',
    'a03',
    'a04',
    'a05',
    'a06',
    'a07',
    'a08',
    'a09',
    'a10',
  ];

  static String asset(String id) => 'assets/images/avatars/$id.webp';

  static bool isPreset(String? id) => id != null && ids.contains(id);

  /// The bundled file is what the app draws. The copy in storage is what the
  /// rest of the world sees — a feed row resolves an author's avatar through
  /// profile_photo_url, and a reader cannot read another person's bundle.
  ///
  /// One shared file per preset rather than a copy per account: ten objects in
  /// the bucket however many people pick them.
  static String publicUrl(String supabaseUrl, String id) =>
      '$supabaseUrl/storage/v1/object/public/profile-photos/presets/$id.webp';

  /// Which preset a stored photo URL is, if it is one at all.
  ///
  /// Read back out of the URL rather than from a new column, so the picker can
  /// show what somebody already chose without touching the user select — that
  /// select is a deliberate ladder of fallbacks for databases a migration or
  /// two behind, and adding a rung to it to pre-tick a tile is not a trade
  /// worth making.
  static String? fromUrl(String? url) {
    if (url == null) return null;
    final m = RegExp(r'/presets/(a\d{2})\.webp$').firstMatch(url);
    final id = m?.group(1);
    return isPreset(id) ? id : null;
  }
}
