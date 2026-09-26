import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two screens asked to look professional, and the decisions that got them
/// there. Source checks: both are composed of private widgets behind four
/// providers each, and what changed is arrangement — which is exactly what a
/// pumped test measures badly and a reader measures well.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('your own profile', () {
    late final String src = read(
      'lib/presentation/screens/profile/profile_overview.dart',
    );

    test('wears the same header as everyone else', () {
      // Same person, same information, so the same arrangement a visitor
      // sees: a full-width cover, the avatar on its seam, three numbers in
      // its row, then one left margin.
      expect(src, contains('class _OwnProfileCover'));
      expect(
        src,
        contains('height: banner.isNotEmpty || photo.isNotEmpty ? 190 : 140'),
      );
      expect(src, contains('class _OwnStat'));
    });

    test('the avatar stopped glowing', () {
      // A magenta gradient ring with a 22px coloured shadow is a
      // notification, not a frame.
      expect(
        src,
        isNot(contains('blurRadius: 22')),
        reason: 'the glow ring is gone',
      );
    });

    test('the invented trust score is gone', () {
      // It was `72 + karma/20`, shown as a percentage captioned "Building",
      // at the same size as the posts the person actually wrote.
      expect(src, isNot(contains('int _trust()')));
      expect(src, isNot(contains('Trust Score')));
    });

    test('and the row of actions has no unlabelled duplicate in it', () {
      // The glowing mark in the middle opened /compose — the same screen as
      // Drop, two buttons to its left.
      expect(src, isNot(contains('class _CenterAction')));
    });
  });

  group('keeper studio', () {
    late final String src = read(
      'lib/presentation/screens/home/keeper_home_screen.dart',
    );

    test('one grid for making things, one list for going places', () {
      expect(src, contains('class _LinkRows'));
      expect(
        src,
        isNot(contains("title: 'Set up'")),
        reason: "setup is the tribe's own settings screen, one tap above",
      );
    });

    test('Manage Tribe is a row, not a billboard', () {
      // It was a filled 54pt bar in the brand colour — the loudest element on
      // a screen whose urgent things are quiet numbers above it.
      expect(
        src,
        isNot(contains('FilledButton.styleFrom')),
        reason: 'no filled brand-colour bar on this screen any more',
      );
      expect(src, contains("ValueKey('plug-studio-primary-manage-tribe')"));
      expect(src, contains("'Manage Tribe'"));
    });

    test('the tribe is the headline, not the word Studio', () {
      expect(src, contains("'Keeper Studio'"));
      expect(
        src,
        isNot(
          contains('''
                    color: VentlyColors.berryMagenta,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,'''),
        ),
        reason: 'the chrome title is no longer 22pt magenta',
      );
    });
  });
}
