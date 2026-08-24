import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/colors.dart';
import 'profile_avatar.dart';

/// The result of editing a background: the anchor the user settled on, and
/// whether they want it saved at all.
class BannerEditResult {
  const BannerEditResult({required this.offset});

  /// 0 = top of the image, 1 = bottom. Matches
  /// `users.profile_banner_offset`.
  final double offset;
}

/// Drag-to-reposition and preview, in one sheet.
///
/// These are the same interaction, not two features: you cannot judge a crop
/// without seeing it in the frame it will live in, and you cannot pick a frame
/// without dragging. So the preview *is* the editor — a real 168pt banner strip
/// at the real corner radius, with the avatar overlapping exactly where it will
/// on the profile, and the image moving under your finger.
///
/// Why an anchor rather than a crop: a fraction survives the three different
/// heights this strip is drawn at (168 on a public profile with a banner, 116
/// without, 104 on your own card). A baked crop would be correct at one of them
/// and wrong at the other two, and would make re-framing mean re-uploading.
///
/// Used for a freshly picked file (via [bytes]) and for re-anchoring one already
/// uploaded (via [imageUrl]), because "change where it sits" should not care
/// which of those you are doing.
class ProfileBannerEditorSheet extends StatefulWidget {
  const ProfileBannerEditorSheet({
    super.key,
    this.bytes,
    this.imageUrl,
    required this.initialOffset,
    required this.avatarSeed,
    required this.avatarLabel,
    this.avatarPhotoUrl,
    required this.saveLabel,
  }) : assert(
         bytes != null || imageUrl != null,
         'needs either picked bytes or an existing url',
       );

  final Uint8List? bytes;
  final String? imageUrl;
  final double initialOffset;
  final String avatarSeed;
  final String avatarLabel;
  final String? avatarPhotoUrl;
  final String saveLabel;

  @override
  State<ProfileBannerEditorSheet> createState() =>
      _ProfileBannerEditorSheetState();
}

class _ProfileBannerEditorSheetState extends State<ProfileBannerEditorSheet> {
  static const double _bannerHeight = 168;

  late double _offset = widget.initialOffset.clamp(0.0, 1.0);

  void _drag(DragUpdateDetails d) {
    setState(() {
      // Dragging down should reveal what is *above* the current window, which
      // means decreasing the anchor. The divisor is the strip height rather than
      // a constant so the gesture feels the same regardless of frame size.
      _offset = (_offset - d.delta.dy / _bannerHeight).clamp(0.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Alignment's y axis runs -1 (top) … 1 (bottom); the stored anchor is
    // 0 … 1. One line of conversion, kept here so nothing else has to know.
    final alignment = Alignment(0, _offset * 2 - 1);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Position your background',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Drag the image to choose what shows. This is exactly how your '
              'profile will look.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: context.ink.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 14),

            // The preview is the real thing: same height, same radius, same
            // avatar overlap and same bottom fade as the profile hero, so there
            // is no gap between what you approve and what ships.
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                height: _bannerHeight,
                width: double.infinity,
                child: GestureDetector(
                  onVerticalDragUpdate: _drag,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.bytes != null)
                        Image.memory(
                          widget.bytes!,
                          fit: BoxFit.cover,
                          alignment: alignment,
                          gaplessPlayback: true,
                        )
                      else
                        CachedNetworkImage(
                          imageUrl: widget.imageUrl!,
                          fit: BoxFit.cover,
                          alignment: alignment,
                          placeholder: (_, __) =>
                              const ColoredBox(color: VentlyColors.roseTint),
                          errorWidget: (_, __, ___) =>
                              const ColoredBox(color: VentlyColors.roseTint),
                        ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.22),
                              Colors.transparent,
                              scheme.surface.withOpacity(0.55),
                            ],
                            stops: const [0.0, 0.5, 1.0],
                          ),
                        ),
                      ),
                      // The avatar is here because it is the thing most likely
                      // to ruin a crop: a face centred in the photo ends up
                      // hidden behind it, and you can only see that happening
                      // if it is in the preview.
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: scheme.surface,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.primary,
                                width: 2.5,
                              ),
                            ),
                            child: ClipOval(
                              child: ProfileAvatar(
                                avatarSeed: widget.avatarSeed,
                                label: widget.avatarLabel,
                                profilePhotoUrl: widget.avatarPhotoUrl,
                                size: 56,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Positioned(top: 8, left: 10, child: _DragHint()),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        BannerEditResult(offset: _offset),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        widget.saveLabel,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DragHint extends StatelessWidget {
  const _DragHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        borderRadius: BorderRadius.circular(99),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_vert_rounded, size: 13, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'Drag to reposition',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the editor. Returns null when the user cancels.
Future<BannerEditResult?> showProfileBannerEditor(
  BuildContext context, {
  Uint8List? bytes,
  String? imageUrl,
  required double initialOffset,
  required String avatarSeed,
  required String avatarLabel,
  String? avatarPhotoUrl,
  required String saveLabel,
}) {
  return showModalBottomSheet<BannerEditResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => ProfileBannerEditorSheet(
      bytes: bytes,
      imageUrl: imageUrl,
      initialOffset: initialOffset,
      avatarSeed: avatarSeed,
      avatarLabel: avatarLabel,
      avatarPhotoUrl: avatarPhotoUrl,
      saveLabel: saveLabel,
    ),
  );
}
