import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// An avatar somebody built, piece by piece.
///
/// What this replaces: a letter on a colour derived from a hash, then ten
/// fixed portraits. The portraits are still there — somebody in a hurry picks
/// one and is done — but a fixed portrait is somebody else's face. This is the
/// one you make.
///
/// The ids are what the database stores inside `users.avatar_config`, so they
/// must never be renumbered: an account wearing hair_04 keeps hair_04 forever.
/// New art gets new ids on the end.
///
/// Skin is six baked files rather than a tint, because the lighting is painted
/// into the art — scaling a warm mid-brown up without pulling the saturation
/// down turns it orange, and no colour filter can know to do that. Hair,
/// beards and tops ship as normalised greyscale and are tinted at draw time,
/// which is what turns twelve hairstyles into seventy-two.
class AvatarLayers {
  const AvatarLayers._();

  /// Deepest to fairest. The order is the order they appear in the studio.
  static const skins = <String>['s01', 's02', 's03', 's04', 's05', 's06'];

  /// hair_01..05 and 11..12 are cropped and faded; 06..10 are longer.
  static const hair = <String>[
    'hair_01',
    'hair_02',
    'hair_03',
    'hair_04',
    'hair_05',
    'hair_06',
    'hair_07',
    'hair_08',
    'hair_09',
    'hair_10',
    'hair_11',
    'hair_12',
  ];

  /// beard_02 and beard_03 are moustaches; the rest take in the jaw.
  static const beards = <String>[
    'beard_01',
    'beard_02',
    'beard_03',
    'beard_04',
    'beard_05',
    'beard_06',
    'beard_07',
    'beard_08',
    'beard_09',
    'beard_10',
  ];

  static const tops = <String>['top_01', 'top_02'];

  static const dir = 'assets/images/avatars/layers';

  static String asset(String id) => '$dir/$id.webp';

  static String skinAsset(String skin) => asset('base_$skin');

  static bool isSkin(String? id) => id != null && skins.contains(id);
  static bool isHair(String? id) => id != null && hair.contains(id);
  static bool isBeard(String? id) => id != null && beards.contains(id);
  static bool isTop(String? id) => id != null && tops.contains(id);
}

/// The colours a piece can be tinted.
///
/// Small deliberate sets. A full colour wheel sounds generous and produces
/// avatars with turquoise beards; these are the colours hair and clothes
/// actually come in, and every one of them was checked against all six skins.
class AvatarPalettes {
  const AvatarPalettes._();

  static const hair = <String, Color>{
    'black': Color(0xFF362C2A),
    'darkbrown': Color(0xFF5C3E2E),
    'brown': Color(0xFF8C6240),
    'auburn': Color(0xFF9C5030),
    'blonde': Color(0xFFE4BE7C),
    'grey': Color(0xFFB2AEAC),
  };

  static const garment = <String, Color>{
    'white': Color(0xFFF6F6F8),
    'ink': Color(0xFF2C2C34),
    'berry': Color(0xFFC92F7A),
    'sky': Color(0xFF5696D6),
    'moss': Color(0xFF5C8A68),
    'sand': Color(0xFFD6BA96),
  };

  /// Multiply a normalised greyscale layer by a colour, leaving alpha alone.
  ///
  /// The layer arrives with R == G == B == luminance, so one column of the
  /// matrix does the whole job: R' = r·L, G' = g·L, B' = b·L, A' = A. Written
  /// as a matrix rather than [BlendMode.modulate] on purpose — modulate
  /// multiplies alpha too, and Impeller and Skia disagree about what that
  /// means for a semi-transparent filter colour. A diagonal matrix gives the
  /// same answer whether the engine hands it premultiplied colour or not.
  static ColorFilter multiply(Color c) => ColorFilter.matrix(<double>[
    c.r, 0, 0, 0, 0, //
    c.g, 0, 0, 0, 0, //
    c.b, 0, 0, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  static Color hairColour(String? key) =>
      hair[key] ?? hair['black'] ?? const Color(0xFF362C2A);

  static Color garmentColour(String? key) =>
      garment[key] ?? garment['white'] ?? const Color(0xFFF6F6F8);
}

/// One person's avatar, as a set of choices rather than a picture.
///
/// Stored as intent, not as a filename, which is what lets the art change
/// under everybody without a migration: redraw hair_04 and every account
/// wearing it gets the new one next time their avatar is baked.
@immutable
class AvatarLook {
  const AvatarLook({
    required this.skin,
    this.hair,
    this.hairTint = 'black',
    this.beard,
    this.top = 'top_01',
    this.topTint = 'white',
  });

  /// Where somebody lands before they have touched anything. Mid skin, a short
  /// cut, a plain tee — recognisably a person, and nothing that reads as a
  /// default nobody chose.
  static const starting = AvatarLook(skin: 's03', hair: 'hair_02');

  final String skin;

  /// Null is bald, which is a haircut.
  final String? hair;
  final String hairTint;

  /// Null is clean-shaven.
  final String? beard;
  final String top;
  final String topTint;

  AvatarLook copyWith({
    String? skin,
    String? hair,
    bool clearHair = false,
    String? hairTint,
    String? beard,
    bool clearBeard = false,
    String? top,
    String? topTint,
  }) => AvatarLook(
    skin: skin ?? this.skin,
    hair: clearHair ? null : (hair ?? this.hair),
    hairTint: hairTint ?? this.hairTint,
    beard: clearBeard ? null : (beard ?? this.beard),
    top: top ?? this.top,
    topTint: topTint ?? this.topTint,
  );

  /// What goes into `users.avatar_config`. The server shape-checks this, so
  /// the key names here and the regexes in the migration move together.
  Map<String, dynamic> toConfig() => <String, dynamic>{
    'kind': 'custom',
    'v': 1,
    'skin': skin,
    'hair': hair,
    'hair_tint': hairTint,
    'beard': beard,
    'top': top,
    'top_tint': topTint,
  };

  /// Read a stored config back, or null if it is a preset, a legacy seed, or
  /// anything else this version does not understand.
  ///
  /// Unknown ids fall back rather than throw: a config written by a newer
  /// build that names hair_14 should still open in the studio as *something*,
  /// so somebody on an old version can edit their avatar instead of meeting a
  /// crash. They lose the piece the old build cannot draw, and only if they
  /// save.
  static AvatarLook? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['kind'] != 'custom') return null;
    final skin = raw['skin'];
    if (!AvatarLayers.isSkin(skin is String ? skin : null)) return null;
    final hair = raw['hair'];
    final beard = raw['beard'];
    final top = raw['top'];
    final hairTint = raw['hair_tint'];
    final topTint = raw['top_tint'];
    return AvatarLook(
      skin: skin as String,
      hair: AvatarLayers.isHair(hair is String ? hair : null)
          ? hair as String
          : null,
      hairTint: AvatarPalettes.hair.containsKey(hairTint)
          ? hairTint as String
          : 'black',
      beard: AvatarLayers.isBeard(beard is String ? beard : null)
          ? beard as String
          : null,
      top: AvatarLayers.isTop(top is String ? top : null)
          ? top as String
          : 'top_01',
      topTint: AvatarPalettes.garment.containsKey(topTint)
          ? topTint as String
          : 'white',
    );
  }

  /// Bottom to top. Hair goes over the beard so a fringe falls in front of a
  /// sideburn, and the top goes under both so a collar sits behind a jaw.
  List<({String asset, Color? tint})> get layers => <({String asset, Color? tint})>[
    (asset: AvatarLayers.skinAsset(skin), tint: null),
    (
      asset: AvatarLayers.asset(top),
      tint: AvatarPalettes.garmentColour(topTint),
    ),
    if (beard != null)
      (
        asset: AvatarLayers.asset(beard!),
        tint: AvatarPalettes.hairColour(hairTint),
      ),
    if (hair != null)
      (
        asset: AvatarLayers.asset(hair!),
        tint: AvatarPalettes.hairColour(hairTint),
      ),
  ];

  @override
  bool operator ==(Object other) =>
      other is AvatarLook &&
      other.skin == skin &&
      other.hair == hair &&
      other.hairTint == hairTint &&
      other.beard == beard &&
      other.top == top &&
      other.topTint == topTint;

  @override
  int get hashCode => Object.hash(skin, hair, hairTint, beard, top, topTint);
}
