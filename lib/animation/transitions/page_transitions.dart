// [CupertinoPageTransitionsBuilder] lives in the Cupertino library; the
// Material library only references it in docs.
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'fade_scale.dart';
import 'shared_axis.dart';

export 'fade_scale.dart';
export 'shared_axis.dart';

/// The app-wide transition theme.
///
/// iOS keeps the Cupertino builder on purpose: it preserves the native
/// edge-swipe back gesture, which is worth more than a custom curve to an
/// iPhone user. Everything else gets the shared-axis system.
class VentlyPageTransitions {
  VentlyPageTransitions._();

  static const PageTransitionsTheme theme = PageTransitionsTheme(builders: {
    TargetPlatform.android: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.linux: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.windows: SharedAxisPageTransitionsBuilder(),
    TargetPlatform.fuchsia: SharedAxisPageTransitionsBuilder(),
  });

  /// Available for one-off routes that want the modal feel instead.
  static const PageTransitionsBuilder fadeScale =
      FadeScalePageTransitionsBuilder();
}
