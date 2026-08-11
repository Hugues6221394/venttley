import 'package:flutter/material.dart';

import 'fade_scale.dart';
import 'shared_axis.dart';

export 'fade_scale.dart';
export 'shared_axis.dart';

/// The app-wide transition theme.
///
/// iOS gets [CupertinoSharedAxisPageTransitionsBuilder]: the shared-axis fade
/// and scale settle layered over Cupertino's own transition, so the native
/// edge-swipe back gesture — which is worth more to an iPhone user than any
/// curve — keeps working. Previously iOS used the plain Cupertino builder,
/// which meant none of the designed motion ran there at all.
class VentlyPageTransitions {
  VentlyPageTransitions._();

  static const PageTransitionsTheme theme = PageTransitionsTheme(builders: {
    TargetPlatform.android: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoSharedAxisPageTransitionsBuilder(),
    TargetPlatform.macOS: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.linux: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.windows: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.fuchsia: SharedAxisPageTransitionsBuilder(),
  });

  /// Available for one-off routes that want the modal feel instead.
  static const PageTransitionsBuilder fadeScale =
      FadeScalePageTransitionsBuilder();
}
