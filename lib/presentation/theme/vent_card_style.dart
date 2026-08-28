import 'package:flutter/material.dart';

class VentCardStyle {
  const VentCardStyle._();

  static const backgrounds = <String?>[
    null,
    '#FFF7FA',
    '#FFE6EF',
    '#F1EAFF',
    '#E7F6F1',
    '#FFF1D6',
    '#231820',
  ];

  static const textColors = <String?>[
    null,
    '#21161B',
    '#FFFFFF',
    '#B91452',
    '#5A3FA3',
    '#176C61',
  ];

  static const _darkBackgrounds = {'#231820'};

  static Color? parse(String? hex) {
    if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
    final value = int.tryParse(hex.substring(1), radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  static String? readableTextFor(String? background, String? requested) {
    if (background == null) return requested;
    final dark = _darkBackgrounds.contains(background);
    if (requested == null) return dark ? '#FFFFFF' : '#21161B';
    if (dark) return requested == '#FFFFFF' ? requested : '#FFFFFF';
    return requested == '#FFFFFF' ? '#21161B' : requested;
  }

  static String backgroundLabel(String? value) => switch (value) {
        null => 'Default',
        '#FFF7FA' => 'Blush',
        '#FFE6EF' => 'Rose',
        '#F1EAFF' => 'Lavender',
        '#E7F6F1' => 'Mint',
        '#FFF1D6' => 'Sunlight',
        '#231820' => 'Midnight',
        _ => 'Custom',
      };

  static String textLabel(String? value) => switch (value) {
        null => 'Auto',
        '#21161B' => 'Ink',
        '#FFFFFF' => 'White',
        '#B91452' => 'Berry',
        '#5A3FA3' => 'Violet',
        '#176C61' => 'Teal',
        _ => 'Custom',
      };
}
