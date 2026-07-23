import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/profile_avatar.dart';
import 'package:vently_app/presentation/widgets/vently_premium_background.dart';

void main() {
  testWidgets('small profile photos decode near their rendered size',
      (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: VentlyTheme.light(),
        home: const ProfileAvatar(
          avatarSeed: 'performance-contract',
          label: 'Test user',
          profilePhotoUrl: 'https://example.invalid/profile.jpg',
          size: 44,
        ),
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.memCacheWidth, 132);
    expect(image.memCacheHeight, 132);
    expect(image.maxWidthDiskCache, 132);
    expect(image.maxHeightDiskCache, 132);
  });

  testWidgets('the default premium background avoids a full-screen stack',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VentlyTheme.light(),
        home: const VentlyPremiumBackground(
          child: SizedBox.expand(key: Key('content')),
        ),
      ),
    );

    final background = find.byType(VentlyPremiumBackground);
    expect(background, findsOneWidget);
    expect(
      find.descendant(of: background, matching: find.byType(Stack)),
      findsNothing,
    );
    expect(find.byKey(const Key('content')), findsOneWidget);
  });
}
