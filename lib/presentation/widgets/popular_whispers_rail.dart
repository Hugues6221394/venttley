import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'post_card.dart' show PostCard;
import 'premium_motion.dart';
import 'profile_avatar.dart';
import 'skeleton.dart';
import 'whisper_carousel_tile.dart';

/// Home module — the Whispers spotlight banner from the launch adverts, with
/// the engagement-ranked carousel underneath. Real data only.
class PopularWhispersRail extends ConsumerWidget {
  const PopularWhispersRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(popularWhispersProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: WhisperRailSkeleton(),
      ),
      error: (_, __) => const _WhispersSpotlightBanner(whispers: []),
      data: (whispers) {
        if (whispers.isEmpty) {
          return const _WhispersSpotlightBanner(whispers: []);
        }
        final shown = whispers.take(8).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _WhispersSpotlightBanner(whispers: shown),
            SizedBox(
              height: 184,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: shown.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final w = shown[i];
                  return WhisperCarouselTile(
                    whisper: w,
                    onTap: () =>
                        context.push('/whispers?whisper=${w.whisperId}'),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Deep-rose gradient card: "Popular right now / Whispers / Tap in. Listen
/// quietly." with a play button, listener avatars, and a live plays badge.
class _WhispersSpotlightBanner extends StatelessWidget {
  const _WhispersSpotlightBanner({required this.whispers});

  final List<Whisper> whispers;

  @override
  Widget build(BuildContext context) {
    final totalPlays = whispers.fold<int>(0, (sum, w) => sum + w.playsCount);
    final faces = whispers.take(4).toList();

    return FadeSlideIn(
      child: Pressable(
        onTap: () => context.go('/whispers'),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          decoration: BoxDecoration(
            gradient: VentlyGradients.banner,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF9E1F50).withOpacity(0.35),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.trending_up_rounded,
                            size: 13, color: Colors.white.withOpacity(0.85)),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'Popular right now',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Whispers',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tap in. Listen quietly.\nJoin the conversation—your way.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.88),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.35),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Explore whispers',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward_rounded,
                              size: 14, color: Colors.white),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 118,
                height: 128,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (totalPlays > 0)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.20),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.30),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.graphic_eq_rounded,
                                  size: 12, color: Colors.white),
                              const SizedBox(width: 4),
                              Text(
                                PostCard.compactNumber(totalPlays),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.22),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.45),
                          width: 1.4,
                        ),
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 34),
                    ),
                    for (var i = 0; i < faces.length; i++)
                      Positioned(
                        left: _faceOffsets[i].dx,
                        top: _faceOffsets[i].dy,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withOpacity(0.8),
                              width: 1.6,
                            ),
                          ),
                          child: ProfileAvatar(
                            avatarSeed: faces[i].authorAvatarSeed,
                            label: faces[i].authorPseudonym,
                            profilePhotoUrl: faces[i].authorProfilePhotoUrl,
                            size: 30,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Orbit positions for up to four listener avatars around the play button.
  static const _faceOffsets = [
    Offset(0, 18),
    Offset(84, 34),
    Offset(8, 90),
    Offset(78, 92),
  ];
}
