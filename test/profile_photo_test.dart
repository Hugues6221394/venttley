import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  test('AppUser profile photo can be set and cleared independently of avatar',
      () {
    const user = AppUser(
      userId: 'u1',
      anonymousPseudonym: 'nova',
      avatarSeed:
          'v2:silhouette=orb;palette=berry;hair=none;accessory=none;aura=none;outfit=none',
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

  test('friend directory entities retain authoritative profile photos', () {
    final friend = FriendSummary(
      friendshipId: 'friendship-1',
      userId: 'user-2',
      pseudonym: 'GoldenHour',
      avatarSeed: 'golden',
      karma: 20,
      isVerified: false,
      acceptedAt: DateTime(2026, 7, 27),
      profilePhotoUrl: 'https://example.com/friend.jpg',
    );
    final request = FriendRequest(
      friendshipId: 'request-1',
      otherUserId: 'user-3',
      otherPseudonym: 'HealingSlow',
      otherAvatarSeed: 'healing',
      otherKarma: 10,
      createdAt: DateTime(2026, 7, 27),
      isOutgoing: false,
      profilePhotoUrl: 'https://example.com/request.jpg',
    );

    expect(friend.profilePhotoUrl, 'https://example.com/friend.jpg');
    expect(request.profilePhotoUrl, 'https://example.com/request.jpg');
  });

  test('friends screen does not present load failures as an empty circle', () {
    final screen = File('lib/presentation/screens/friends/friends_screen.dart')
        .readAsStringSync();

    expect(screen, contains('friendsAsync.hasError'));
    expect(screen, contains("title: 'Couldn\\'t load friends'"));
    expect(screen, contains('ref.invalidate(myFriendsProvider)'));
  });
}
