import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/avatar/avatar_design.dart';

void main() {
  test('avatar design round-trips an outfit choice in the seed', () {
    const design = AvatarDesign(
      silhouette: AvatarSilhouette.blob,
      palette: AvatarPalette.teal,
      hair: AvatarHair.curl,
      accessory: AvatarAccessory.glasses,
      aura: AvatarAura.sparkle,
      outfit: AvatarOutfit.hoodie,
    );

    final parsed = AvatarDesign.tryParse(design.toSeed());

    expect(parsed, isNotNull);
    expect(parsed!.outfit, AvatarOutfit.hoodie);
    expect(parsed.toSeed(), contains('outfit=hoodie'));
  });

  test('legacy v2 avatar seeds without outfit default to none', () {
    final parsed = AvatarDesign.tryParse(
      'v2:silhouette=heart;palette=berry;hair=wave;accessory=bow;aura=glow',
    );

    expect(parsed, isNotNull);
    expect(parsed!.outfit, AvatarOutfit.none);
  });
}
