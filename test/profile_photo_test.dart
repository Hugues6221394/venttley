import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  test('AppUser profile photo can be set and cleared independently of avatar', () {
    const user = AppUser(
      userId: 'u1',
      anonymousPseudonym: 'nova',
      avatarSeed: 'v2:silhouette=orb;palette=berry;hair=none;accessory=none;aura=none;outfit=none',
      currentMood: 'happy',
      userRole: 'normal',
      isVerified: false,
      safetyTier: 'standard',
      accountStatus: 'active',
    );

    final withPhoto = user.copyWith(
      profilePhotoUrl: 'https://example.com/photo.jpg',
    );
    final cleared = withPhoto.copyWith(profilePhotoUrl: null);

    expect(withPhoto.profilePhotoUrl, 'https://example.com/photo.jpg');
    expect(withPhoto.avatarSeed, user.avatarSeed);
    expect(cleared.profilePhotoUrl, isNull);
    expect(cleared.avatarSeed, user.avatarSeed);
  });
}
