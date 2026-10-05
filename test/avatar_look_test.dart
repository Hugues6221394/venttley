import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/avatar/avatar_look.dart';

/// The avatar studio is art, a build script, a Dart catalogue and a Postgres
/// regex that all have to agree about the same twenty-odd ids. Nothing in the
/// type system holds them together, so these do.
void main() {
  group('AvatarLook', () {
    test('round-trips through the config it stores', () {
      const look = AvatarLook(
        skin: 's05',
        hair: 'hair_09',
        hairTint: 'auburn',
        beard: 'beard_04',
        top: 'top_02',
        topTint: 'berry',
      );
      expect(AvatarLook.tryParse(look.toConfig()), look);
    });

    test('bald and clean-shaven survive the round trip', () {
      const look = AvatarLook(skin: 's01', hair: null, beard: null);
      final parsed = AvatarLook.tryParse(look.toConfig());
      expect(parsed, isNotNull);
      expect(parsed!.hair, isNull);
      expect(parsed.beard, isNull);
    });

    test('refuses a preset config and anything that is not a map', () {
      expect(AvatarLook.tryParse({'kind': 'preset', 'preset': 'a07'}), isNull);
      expect(AvatarLook.tryParse('hair_01'), isNull);
      expect(AvatarLook.tryParse(null), isNull);
    });

    test('falls back rather than throwing on ids it does not know', () {
      // Written by a future build. An old app should still open the studio.
      final parsed = AvatarLook.tryParse({
        'kind': 'custom',
        'skin': 's02',
        'hair': 'hair_99',
        'hair_tint': 'turquoise',
        'beard': 'beard_99',
        'top': 'top_99',
        'top_tint': 'neon',
      });
      expect(parsed, isNotNull);
      expect(parsed!.skin, 's02');
      expect(parsed.hair, isNull);
      expect(parsed.beard, isNull);
      expect(parsed.hairTint, 'black');
      expect(parsed.top, 'top_01');
      expect(parsed.topTint, 'white');
    });

    test('draws the base first and the hair last', () {
      const look = AvatarLook(
        skin: 's03',
        hair: 'hair_01',
        beard: 'beard_01',
        top: 'top_01',
      );
      final assets = look.layers.map((l) => l.asset).toList();
      expect(assets.first, contains('base_s03'));
      expect(assets.last, contains('hair_01'));
      expect(assets[1], contains('top_01'));
      // The base is the only layer drawn in its own colours.
      expect(look.layers.first.tint, isNull);
      expect(look.layers.skip(1).every((l) => l.tint != null), isTrue);
    });
  });

  group('the art the catalogue promises', () {
    final ids = <String>[
      ...AvatarLayers.skins.map((s) => 'base_$s'),
      ...AvatarLayers.hair,
      ...AvatarLayers.beards,
      ...AvatarLayers.tops,
    ];

    test('every layer exists on disk', () {
      final missing = ids
          .where((id) => !File('${AvatarLayers.dir}/$id.webp').existsSync())
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'Re-run scripts/avatars/build_layers.py — these ids have no file.',
      );
    });

    test('the exported manifest and the catalogue agree', () {
      final file = File('${AvatarLayers.dir}/manifest.json');
      expect(file.existsSync(), isTrue);
      final manifest =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((manifest['skins'] as List).cast<String>(), AvatarLayers.skins);
      expect((manifest['hair'] as List).cast<String>(), AvatarLayers.hair);
      expect((manifest['beards'] as List).cast<String>(), AvatarLayers.beards);
      expect((manifest['tops'] as List).cast<String>(), AvatarLayers.tops);
    });

    test('pubspec bundles the layers directory', () {
      // Flutter asset globs do not recurse. Listing assets/images/avatars/
      // ships the ten presets and silently leaves every layer out of the
      // bundle, which looks exactly like the art being broken.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- ${AvatarLayers.dir}/'));
    });
  });

  group('the server agrees with the client', () {
    final sql = File(
      'supabase/migrations/20261074090000_an_avatar_you_made.sql',
    ).readAsStringSync();

    test('validates every key the client writes', () {
      const look = AvatarLook(skin: 's01', hair: 'hair_01', beard: 'beard_01');
      for (final key in look.toConfig().keys) {
        if (key == 'kind' || key == 'v') continue;
        expect(
          sql,
          contains("'$key'"),
          reason:
              'set_avatar_config does not mention $key, so anything at all '
              'could be stored in it.',
        );
      }
    });

    test('its id patterns match the ids actually shipped', () {
      final patterns = <RegExp, List<String>>{
        RegExp(r'^s[0-9]{2}$'): AvatarLayers.skins,
        RegExp(r'^hair_[0-9]{2}$'): AvatarLayers.hair,
        RegExp(r'^beard_[0-9]{2}$'): AvatarLayers.beards,
        RegExp(r'^top_[0-9]{2}$'): AvatarLayers.tops,
      };
      patterns.forEach((pattern, ids) {
        expect(sql, contains(pattern.pattern));
        for (final id in ids) {
          expect(pattern.hasMatch(id), isTrue, reason: '$id would be refused');
        }
      });
    });

    test('every tint name passes the server pattern', () {
      final tint = RegExp(r'^[a-z]{3,12}$');
      expect(sql, contains(tint.pattern));
      for (final key in [
        ...AvatarPalettes.hair.keys,
        ...AvatarPalettes.garment.keys,
      ]) {
        expect(tint.hasMatch(key), isTrue, reason: '$key would be refused');
      }
    });
  });
}
