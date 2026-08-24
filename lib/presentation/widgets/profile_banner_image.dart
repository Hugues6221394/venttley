import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/colors.dart';

/// A profile background image that can tell "still arriving" apart from
/// "not set".
///
/// These used to collapse into one look: the same widget served as placeholder,
/// error state and empty state, so a background whose storage object had gone
/// missing was indistinguishable from a profile that never set one — and a
/// device that still held the file in its image cache kept showing it, so the
/// same profile looked different on two phones.
///
/// Three behaviours, all of them about not lying:
///   • loading shimmers on a muted surface, so waiting is visibly waiting;
///   • a failure retries a few times with a short backoff before giving up,
///     because CachedNetworkImage will not try again on its own once the error
///     widget is up and the usual cause on a phone is a cold cache on a bad
///     connection;
///   • only after the retries are spent does [fallback] appear, and [onGivenUp]
///     fires so the caller can look into why.
class ProfileBannerImage extends StatefulWidget {
  const ProfileBannerImage({
    super.key,
    required this.url,
    required this.alignment,
    required this.fallback,
    this.onGivenUp,
  });

  final String url;

  /// Where the crop sits: the owner's anchor, already converted.
  final Alignment alignment;

  /// Shown once the retries are exhausted. Differs by surface — the brand
  /// gradient on a public profile, a flat tint on your own card.
  final Widget fallback;

  /// Called once per URL, after the last attempt fails. Deliberately not called
  /// on the first error: most first errors are transient.
  final VoidCallback? onGivenUp;

  @override
  State<ProfileBannerImage> createState() => _ProfileBannerImageState();
}

class _ProfileBannerImageState extends State<ProfileBannerImage> {
  static const _maxAttempts = 3;

  int _attempt = 0;
  bool _retryPending = false;
  bool _reported = false;

  bool get _exhausted => _attempt >= _maxAttempts - 1;

  void _scheduleRetry() {
    // errorWidget builds during layout, so the setState has to wait for the
    // frame to finish. The guard matters because the error widget can be built
    // several times for a single failure.
    if (_retryPending || _exhausted) return;
    _retryPending = true;
    Future.delayed(Duration(milliseconds: 400 * (_attempt + 1)), () {
      if (!mounted) return;
      setState(() {
        _retryPending = false;
        _attempt++;
      });
    });
  }

  void _report(Object? error) {
    if (_reported) return;
    _reported = true;
    // A background that silently degrades is exactly how a broken URL stays
    // invisible, so say so even when there is nothing to be done about it.
    debugPrint('[WARN] banner.image_failed url=${widget.url} err=$error');
    final onGivenUp = widget.onGivenUp;
    if (onGivenUp == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onGivenUp();
    });
  }

  @override
  void didUpdateWidget(ProfileBannerImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _attempt = 0;
      _retryPending = false;
      _reported = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      // Part of the key so a retry actually refetches rather than replaying the
      // cached failure.
      key: ValueKey('${widget.url}#$_attempt'),
      imageUrl: widget.url,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      placeholder: (_, __) => const BannerLoading(),
      errorWidget: (_, __, error) {
        if (_exhausted) {
          _report(error);
          return widget.fallback;
        }
        _scheduleRetry();
        // Still "loading": the fallback is a statement that there is nothing to
        // show, and that is not yet known to be true.
        return const BannerLoading();
      },
    );
  }
}

/// The waiting state for a background that exists but has not arrived. Muted
/// and shimmering rather than branded, so it cannot be mistaken for a profile
/// that simply has no background.
class BannerLoading extends StatelessWidget {
  const BannerLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark
          ? Theme.of(context).colorScheme.surface.withOpacity(0.75)
          : VentlyColors.softMauve.withOpacity(0.28),
      highlightColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor.withOpacity(0.45)
          : Colors.white.withOpacity(0.85),
      child: const ColoredBox(color: Colors.white),
    );
  }
}
