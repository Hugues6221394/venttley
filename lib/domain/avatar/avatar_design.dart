import 'package:flutter/material.dart';

/// The five customisation axes for the v2 anonymous avatar (social
/// spec §3). Every axis has a small enumerated set of options so the
/// space stays expressive without ever rendering a real human face.
///
/// Storage shape lives in `users.avatar_seed` (and `personas.avatar_seed`)
/// as `v2:silhouette=blob;palette=berry;hair=wave;accessory=glasses;aura=glow`.
/// Legacy seeds (e.g. "rose-orb-test1", random hash strings, or old
/// "default-orb") are still rendered via the legacy code path so nothing
/// in the existing dataset breaks.

enum AvatarSilhouette {
  orb,      // Rounded square — the legacy shape, kept as default
  blob,     // Organic rounded blob
  leaf,     // Pointed-tip leaf
  crescent, // Moon arc
  diamond,  // Soft diamond
  heart,    // Heart silhouette (anchors brand)
}

enum AvatarPalette {
  berry,    // brand pink-magenta
  rose,     // soft rose
  plum,     // deep purple
  sky,      // calm cyan
  teal,     // healing green
  amber,    // warm gold
  slate,    // muted neutrals
  midnight, // deep indigo
}

enum AvatarHair {
  none,
  wave,     // Soft top wave
  spike,    // Three short spikes
  bun,      // Top-knot circle
  curl,     // Twin curls on the sides
}

enum AvatarAccessory {
  none,
  glasses,  // Round eyeglass loops
  mask,     // Half-mask across the upper half
  bow,      // Small bow at the top
  earring,  // Stud on the side
}

enum AvatarAura {
  none,
  glow,     // Soft outer glow
  sparkle,  // 3-4 sparkle dots
  pulse,    // Single concentric ring
  shadow,   // Anchored bottom shadow
}

/// Immutable customisation snapshot.
class AvatarDesign {
  final AvatarSilhouette silhouette;
  final AvatarPalette palette;
  final AvatarHair hair;
  final AvatarAccessory accessory;
  final AvatarAura aura;

  const AvatarDesign({
    this.silhouette = AvatarSilhouette.orb,
    this.palette = AvatarPalette.berry,
    this.hair = AvatarHair.none,
    this.accessory = AvatarAccessory.none,
    this.aura = AvatarAura.none,
  });

  AvatarDesign copyWith({
    AvatarSilhouette? silhouette,
    AvatarPalette? palette,
    AvatarHair? hair,
    AvatarAccessory? accessory,
    AvatarAura? aura,
  }) =>
      AvatarDesign(
        silhouette: silhouette ?? this.silhouette,
        palette: palette ?? this.palette,
        hair: hair ?? this.hair,
        accessory: accessory ?? this.accessory,
        aura: aura ?? this.aura,
      );

  /// Serialise to the v2 seed format the DB stores.
  String toSeed() =>
      'v2:silhouette=${silhouette.name};palette=${palette.name};hair=${hair.name};accessory=${accessory.name};aura=${aura.name}';

  /// Parse a seed string into a design. Returns null when the seed
  /// isn't v2-shaped — caller should fall back to legacy rendering.
  static AvatarDesign? tryParse(String? seed) {
    if (seed == null || !seed.startsWith('v2:')) return null;
    final body = seed.substring(3);
    final map = <String, String>{};
    for (final part in body.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      map[part.substring(0, i)] = part.substring(i + 1);
    }
    T parse<T extends Enum>(List<T> values, String key, T fallback) {
      final raw = map[key];
      if (raw == null) return fallback;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return fallback;
    }

    return AvatarDesign(
      silhouette:
          parse(AvatarSilhouette.values, 'silhouette', AvatarSilhouette.orb),
      palette: parse(AvatarPalette.values, 'palette', AvatarPalette.berry),
      hair: parse(AvatarHair.values, 'hair', AvatarHair.none),
      accessory:
          parse(AvatarAccessory.values, 'accessory', AvatarAccessory.none),
      aura: parse(AvatarAura.values, 'aura', AvatarAura.none),
    );
  }
}

/// Two-tone palette: gradient base + accent for hair/accessory.
class AvatarColors {
  final Color base;
  final Color accent;
  final Color detail;
  const AvatarColors(this.base, this.accent, this.detail);

  static AvatarColors of(AvatarPalette p) {
    switch (p) {
      case AvatarPalette.berry:
        return const AvatarColors(
            Color(0xFFE5A1B4), Color(0xFFD12E65), Color(0xFF4A0E17));
      case AvatarPalette.rose:
        return const AvatarColors(
            Color(0xFFF4C5C8), Color(0xFFE07B89), Color(0xFF6B2E36));
      case AvatarPalette.plum:
        return const AvatarColors(
            Color(0xFFC3A5D7), Color(0xFF7C3AED), Color(0xFF35145C));
      case AvatarPalette.sky:
        return const AvatarColors(
            Color(0xFFA8D8F0), Color(0xFF0EA5E9), Color(0xFF0E3A55));
      case AvatarPalette.teal:
        return const AvatarColors(
            Color(0xFF8FD4C0), Color(0xFF10B981), Color(0xFF0F4035));
      case AvatarPalette.amber:
        return const AvatarColors(
            Color(0xFFF7D399), Color(0xFFF59E0B), Color(0xFF5C3E08));
      case AvatarPalette.slate:
        return const AvatarColors(
            Color(0xFFCBD5E1), Color(0xFF475569), Color(0xFF1E293B));
      case AvatarPalette.midnight:
        return const AvatarColors(
            Color(0xFF8B9DD8), Color(0xFF3B4D9C), Color(0xFF111639));
    }
  }
}

/// Display label / icon hints used by the builder UI.
extension AvatarSilhouetteUI on AvatarSilhouette {
  String get label => switch (this) {
        AvatarSilhouette.orb => 'Orb',
        AvatarSilhouette.blob => 'Blob',
        AvatarSilhouette.leaf => 'Leaf',
        AvatarSilhouette.crescent => 'Crescent',
        AvatarSilhouette.diamond => 'Diamond',
        AvatarSilhouette.heart => 'Heart',
      };
}

extension AvatarPaletteUI on AvatarPalette {
  String get label => switch (this) {
        AvatarPalette.berry => 'Berry',
        AvatarPalette.rose => 'Rose',
        AvatarPalette.plum => 'Plum',
        AvatarPalette.sky => 'Sky',
        AvatarPalette.teal => 'Teal',
        AvatarPalette.amber => 'Amber',
        AvatarPalette.slate => 'Slate',
        AvatarPalette.midnight => 'Midnight',
      };
}

extension AvatarHairUI on AvatarHair {
  String get label => switch (this) {
        AvatarHair.none => 'Bare',
        AvatarHair.wave => 'Wave',
        AvatarHair.spike => 'Spikes',
        AvatarHair.bun => 'Top knot',
        AvatarHair.curl => 'Curls',
      };
}

extension AvatarAccessoryUI on AvatarAccessory {
  String get label => switch (this) {
        AvatarAccessory.none => 'None',
        AvatarAccessory.glasses => 'Glasses',
        AvatarAccessory.mask => 'Mask',
        AvatarAccessory.bow => 'Bow',
        AvatarAccessory.earring => 'Earring',
      };
}

extension AvatarAuraUI on AvatarAura {
  String get label => switch (this) {
        AvatarAura.none => 'None',
        AvatarAura.glow => 'Glow',
        AvatarAura.sparkle => 'Sparkle',
        AvatarAura.pulse => 'Pulse',
        AvatarAura.shadow => 'Shadow',
      };
}
