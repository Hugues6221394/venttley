import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import '../theme/vently_tokens.dart';
import 'profile_avatar.dart';

/// Compact whisper card for Home discovery rails.
class WhisperCarouselTile extends StatelessWidget {
  const WhisperCarouselTile({
    super.key,
    required this.whisper,
    required this.onTap,
  });

  final Whisper whisper;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = whisper.backgroundImageUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VentlyTokens.radiusCard),
      child: Container(
        width: 132,
        height: 176,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(VentlyTokens.radiusCard),
          boxShadow: [
            BoxShadow(
              color: VentlyColors.deepBurgundy.withOpacity(0.1),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bg != null && bg.isNotEmpty)
              CachedNetworkImage(
                imageUrl: bg,
                fit: BoxFit.cover,
                placeholder: (_, __) => _gradient(),
                errorWidget: (_, __, ___) => _gradient(),
              )
            else
              _gradient(),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.08),
                    Colors.black.withOpacity(0.72),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.42),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _formatSecs(whisper.audioDurationSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.92),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: VentlyColors.berryMagenta,
                    size: 28,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      ProfileAvatar(
                        avatarSeed: whisper.authorAvatarSeed,
                        label: whisper.authorDisplayName,
                        profilePhotoUrl: whisper.authorProfilePhotoUrl,
                        size: 22,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          whisper.authorDisplayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '#${FeedCategories.label(whisper.category).replaceAll(' ', '')}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.graphic_eq_rounded,
                        size: 11,
                        color: Colors.white.withOpacity(0.8),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        _shortCount(whisper.playsCount),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gradient() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            VentlyTokens.messageBlue.withOpacity(0.85),
            VentlyColors.deepBurgundy,
          ],
        ),
      ),
    );
  }

  static String _formatSecs(int secs) {
    final mm = secs ~/ 60;
    final ss = (secs % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  static String _shortCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
