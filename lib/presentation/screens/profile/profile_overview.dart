import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/media_preview_viewer.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/profile_banner_image.dart';
import '../../widgets/profile_banner_editor.dart';
import '../../widgets/tagged_text.dart';
import '../../theme/glass_tokens.dart';
import '../settings/verification_screen.dart';

/// Redesigned public-profile overview (hero + quick actions + friends/personas
/// + highlights/badges), matching the premium pink glassmorphism spec. All
/// values are real (computed from the user's own content); trust score + level
/// are derived heuristics from real signals (verified, karma, standing).
class ProfileOverview extends ConsumerWidget {
  const ProfileOverview({
    super.key,
    required this.me,
    required this.vents,
    required this.whispers,
    required this.tribesCount,
  });

  final AppUser me;
  final List<Post> vents;
  final List<Whisper> whispers;
  final int tribesCount;

  int _level() => (me.karmaPoints ~/ 250 + 1).clamp(1, 99);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(myFriendsProvider).valueOrNull ?? const [];

    final hugsReceived =
        ref.watch(hugsReceivedProvider(me.userId)).valueOrNull ?? 0;
    final postsTotal = vents.length + whispers.length;
    final heartsReceived =
        vents.fold<int>(0, (s, p) => s + p.likesCount) +
        whispers.fold<int>(0, (s, w) => s + w.likesCount);
    final repliesShared =
        vents.fold<int>(0, (s, p) => s + p.commentsCount) +
        whispers.fold<int>(0, (s, w) => s + w.commentsCount);
    final peopleComforted =
        vents.where((p) => p.likesCount > 0 || p.commentsCount > 0).length +
        whispers.where((w) => w.likesCount > 0 || w.commentsCount > 0).length;

    // The header runs to the edges of the screen; everything under it keeps
    // the 14pt gutter the cards were built for.
    return Column(
      children: [
        _HeroCard(
          me: me,
          level: _level(),
          posts: postsTotal,
          connections: friends.length,
          hugs: hugsReceived,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 8),
          child: Column(
            children: [
              const _QuickActionsBar(),
              const SizedBox(height: 14),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _FriendsCard(friends: friends)),
                    const SizedBox(width: 12),
                    const Expanded(child: _PersonasCard()),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _HighlightsCard(
                        hearts: heartsReceived,
                        replies: repliesShared,
                        comforted: peopleComforted,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _BadgesCard(userId: me.userId)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────── hero ───────────────────────────────

/// The top of your own profile.
///
/// It was the same page as somebody else's, arranged differently — and worse:
/// a glowing ring around the avatar, three badge pills stacked beside the
/// name, a bio with two unrelated glyphs and an Edit button wrapped into its
/// line, then four large metrics on circular tiles. Five competing weights
/// before anything you could act on.
///
/// This is the arrangement the public profile now uses, for the plain reason
/// that it is the same information about the same person: the background at
/// full width, the avatar on the seam at the left, your three numbers in its
/// row, then name, handle, bio on one margin, then what you can do.
///
/// What went, and why:
///
/// * the glow. A magenta ring with a coloured shadow is a notification, not a
///   frame; your own face does not need announcing;
/// * "Verified Anonymous" and "Level N Listener" as pills. The first restates
///   the handle above it, the second is now one quiet chip;
/// * the trust score. It was `72 + karma/20`, presented as a percentage with
///   the caption "Building" — a number the app invents about you, shown at the
///   same size as the posts you actually wrote. If it comes back it should
///   come back as something with a definition;
/// * "Apply for verified" as a badge. It is an action, so it became a button.
class _HeroCard extends ConsumerWidget {
  const _HeroCard({
    required this.me,
    required this.level,
    required this.posts,
    required this.connections,
    required this.hugs,
  });

  final AppUser me;
  final int level;
  final int posts;
  final int connections;
  final int hugs;

  static const double _avatar = 88;
  static const double _overlap = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bio = (me.bio ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            _OwnProfileCover(me: me),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              right: 16,
              child: _HeroSettingsButton(),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: -_overlap,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      shape: BoxShape.circle,
                    ),
                    child: _GlowAvatar(me: me, size: _avatar),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          _OwnStat(
                            value: posts,
                            label: 'Posts',
                            onTap: () => context.push('/profile/posts'),
                          ),
                          _OwnStat(
                            value: connections,
                            label: 'Connections',
                            onTap: () => context.push('/friends'),
                          ),
                          _OwnStat(value: hugs, label: 'Hugs'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: _overlap + 14),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      me.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        color: context.ink,
                      ),
                    ),
                  ),
                  if (me.isVerified) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.verified_rounded,
                      color: VentlyColors.berryMagenta,
                      size: 18,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    '@${me.anonymousPseudonym}',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: context.ink.withOpacity(0.58),
                    ),
                  ),
                  _LevelChip(level: level),
                ],
              ),
              if (bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                TaggedText(
                  bio,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.42,
                    color: context.ink.withOpacity(0.86),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _EditButton()),
                  if (!me.isVerified) ...[
                    const SizedBox(width: 10),
                    Expanded(child: _VerificationPill()),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Your background, full width, fading into the page.
///
/// Same treatment as a visitor gets, which is the point: the one person who
/// could not see their own chosen photo at a reasonable size was its owner.
class _OwnProfileCover extends ConsumerWidget {
  const _OwnProfileCover({required this.me});
  final AppUser me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = (me.profileBannerUrl ?? '').trim();
    final photo = (me.profilePhotoUrl ?? '').trim();
    final page = Theme.of(context).scaffoldBackgroundColor;

    final Widget image;
    if (banner.isNotEmpty) {
      image = ProfileBannerImage(
        url: banner,
        alignment: Alignment(0, me.profileBannerOffset * 2 - 1),
        fallback: const ColoredBox(color: VentlyColors.roseTint),
        // Your own row is the only one you may repair. If the object is
        // provably gone the column gets cleared, so the page stops claiming a
        // background exists and Edit Profile offers "Add" rather than a
        // "Replace / Move / Remove" that acts on nothing.
        onGivenUp: () async {
          final healed = await ref
              .read(repositoryProvider)
              .healMyProfileBannerIfMissing();
          if (healed) await ref.read(sessionProvider.notifier).restore();
        },
      );
    } else if (photo.isNotEmpty) {
      image = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: ProfileBannerImage(
          url: photo,
          alignment: Alignment.center,
          fallback: const ColoredBox(color: VentlyColors.roseTint),
        ),
      );
    } else {
      image = const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              VentlyColors.berryMagenta,
              Color(0xFFE0729A),
              VentlyColors.softMauve,
            ],
          ),
        ),
      );
    }

    // Shorter when there is nothing to look at. 190 is the right height for a
    // photograph somebody chose; the same 190 of brand gradient is just a
    // large pink area above the name.
    final cover = SizedBox(
      height: banner.isNotEmpty || photo.isNotEmpty ? 190 : 140,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.22),
                  Colors.transparent,
                  page.withOpacity(0.55),
                  page,
                ],
                stops: const [0.0, 0.35, 0.82, 1.0],
              ),
            ),
          ),
        ],
      ),
    );

    if (banner.isEmpty) return cover;
    return Semantics(
      button: true,
      label: 'View your profile background',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showMediaPreview(
          context,
          items: [
            MediaPreviewItem(url: banner, label: 'Your profile background'),
          ],
          title: 'Profile background',
        ),
        child: cover,
      ),
    );
  }
}

/// One of your three numbers.
class _OwnStat extends StatelessWidget {
  const _OwnStat({required this.value, required this.label, this.onTap});

  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                PostCard.compactNumber(value),
                maxLines: 1,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                  color: context.ink,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: context.ink.withOpacity(0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Your level, said once and quietly.
class _LevelChip extends StatelessWidget {
  const _LevelChip({required this.level});
  final int level;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: VentlyColors.berryMagenta.withOpacity(0.08),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        'Level $level',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: VentlyColors.berryMagenta,
        ),
      ),
    );
  }
}

/// Your avatar, and the way to change it.
///
/// The name is a leftover: it used to wear a magenta gradient ring with a 22px
/// coloured shadow, which on a header this size read as a notification rather
/// than a frame. The page colour behind it does the separating now.
class _GlowAvatar extends ConsumerWidget {
  const _GlowAvatar({required this.me, this.size = 96});
  final AppUser me;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _showPhotoSheet(context, ref),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surface,
                border: Border.all(
                  color: scheme.primary.withOpacity(0.45),
                  width: 1.5,
                ),
              ),
              padding: const EdgeInsets.all(2),
              child: ClipOval(
                child: ProfileAvatar(
                  avatarSeed: me.avatarSeed,
                  label: me.anonymousPseudonym,
                  profilePhotoUrl: me.profilePhotoUrl,
                  size: size - 4,
                ),
              ),
            ),
            // Add-photo affordance (Instagram-style +). Tapping it — or the
            // avatar — opens the gallery / camera / avatar-builder sheet.
            Positioned(
              right: 0,
              bottom: 2,
              child: GestureDetector(
                onTap: () => _showPhotoSheet(context, ref),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: VentlyColors.berryMagenta.withOpacity(0.35),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPhotoSheet(BuildContext context, WidgetRef ref) async {
    final hasPhoto =
        me.profilePhotoUrl != null && me.profilePhotoUrl!.isNotEmpty;
    final hasBanner =
        me.profileBannerUrl != null && me.profileBannerUrl!.isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: VentlyColors.berryMagenta,
              ),
              title: const Text(
                'Choose from gallery',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(
                Icons.camera_alt_outlined,
                color: VentlyColors.berryMagenta,
              ),
              title: const Text(
                'Take a photo',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Remove photo',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            const Divider(height: 8),
            // The background lives in the same sheet as the avatar rather than
            // behind a second hidden control: both are "the pictures on my
            // profile", and a separate entry point for one of them is how an
            // affordance goes unfound.
            ListTile(
              leading: const Icon(
                Icons.wallpaper_rounded,
                color: VentlyColors.berryMagenta,
              ),
              title: Text(
                hasBanner ? 'Change background image' : 'Add background image',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => Navigator.pop(ctx, 'banner'),
            ),
            if (hasBanner)
              ListTile(
                leading: const Icon(
                  Icons.open_with_rounded,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Reposition background',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, 'banner-move'),
              ),
            if (hasBanner)
              ListTile(
                leading: const Icon(
                  Icons.hide_image_outlined,
                  color: VentlyColors.dangerRed,
                ),
                title: const Text(
                  'Remove background image',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, 'banner-remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      if (action == 'remove') {
        await ref.read(repositoryProvider).removeMyProfilePhoto();
      } else if (action == 'banner-remove') {
        await ref.read(repositoryProvider).removeMyProfileBanner();
      } else if (action == 'banner-move') {
        // Re-anchor only. No picker, no upload — the file is already there, so
        // moving the crop is a single UPDATE.
        final result = await showProfileBannerEditor(
          context,
          imageUrl: me.profileBannerUrl,
          initialOffset: me.profileBannerOffset,
          avatarSeed: me.avatarSeed,
          avatarLabel: me.displayName,
          avatarPhotoUrl: me.profilePhotoUrl,
          saveLabel: 'Save position',
        );
        if (result == null) return;
        await ref
            .read(repositoryProvider)
            .setMyProfileBannerOffset(result.offset);
      } else if (action == 'banner') {
        // Wider and lower quality than the avatar on purpose: this is a
        // full-bleed strip behind other content, so detail matters less than
        // the bytes a user on a slow connection has to send.
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 1600,
          maxHeight: 900,
          imageQuality: 80,
        );
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        if (!context.mounted) return;
        // Preview before anything is uploaded. Cancelling here uploads nothing,
        // which is the point: the old flow committed a crop the user had never
        // seen and left them to discover it on their own profile.
        final framed = await showProfileBannerEditor(
          context,
          bytes: bytes,
          initialOffset: 0.5,
          avatarSeed: me.avatarSeed,
          avatarLabel: me.displayName,
          avatarPhotoUrl: me.profilePhotoUrl,
          saveLabel: 'Use this',
        );
        if (framed == null) return;
        final ext = picked.path.split('.').last.toLowerCase();
        await ref
            .read(repositoryProvider)
            .uploadMyProfileBanner(
              bytes: bytes,
              extension: ext.isEmpty ? 'jpg' : ext,
              contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
              offset: framed.offset,
            );
      } else {
        final picked = await ImagePicker().pickImage(
          source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1024,
          imageQuality: 85,
        );
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        final ext = picked.path.split('.').last.toLowerCase();
        await ref
            .read(repositoryProvider)
            .uploadMyProfilePhoto(
              bytes: bytes,
              extension: ext.isEmpty ? 'jpg' : ext,
              contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
            );
      }
      // Re-hydrate the session so the new photo appears immediately.
      await ref.read(sessionProvider.notifier).restore();
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (action) {
            'remove' => 'Photo removed.',
            'banner' => 'Background updated.',
            'banner-move' => 'Position saved.',
            'banner-remove' => 'Background removed.',
            _ => 'Photo updated.',
          }),
        ),
      );
    } catch (e) {
      // Interpolating the raw exception put Postgrest internals on screen. A
      // StateError from the backend is ours and already readable; anything else
      // goes through the translator.
      final text = e is StateError
          ? e.message
          : UserFriendlyErrors.message(
              e,
              fallback: switch (action) {
                'banner' ||
                'banner-move' ||
                'banner-remove' => "Couldn't update your background.",
                _ => "Couldn't update your photo.",
              },
            );
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }
  }
}

class _VerificationPill extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(myVerificationStatusProvider).valueOrNull ?? 'none';
    if (status == 'verified') return const SizedBox.shrink();

    final pending = status == 'pending';
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: pending
            ? VentlyColors.softMauve.withOpacity(0.25)
            : VentlyColors.berryMagenta.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: VentlyColors.berryMagenta.withOpacity(pending ? 0.25 : 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pending ? Icons.hourglass_top_rounded : Icons.verified_outlined,
            size: 13,
            color: VentlyColors.berryMagenta,
          ),
          const SizedBox(width: 5),
          Text(
            pending ? 'Verification pending' : 'Apply for verified',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w900,
              color: VentlyColors.berryMagenta,
            ),
          ),
        ],
      ),
    );
    if (pending) return pill;
    return GestureDetector(
      onTap: () => _openApplySheet(context, ref),
      child: pill,
    );
  }

  /// Opens the real application form.
  ///
  /// This used to be a bottom sheet with a single free-text box — "Your case
  /// for verification (optional)" — and a Submit button. Meanwhile
  /// VerificationApplyScreen already existed, with a category picker, public
  /// links and a private evidence field, reachable only from Settings.
  ///
  /// So the affordance somebody actually finds, on their own profile,
  /// submitted the weakest possible application: the reviewer got a paragraph
  /// where the form would have given them a category and a link to check. One
  /// route in now, so there is one thing to keep good.
  void _openApplySheet(BuildContext context, WidgetRef ref) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const VerificationApplyScreen()),
    );
  }
}

class _EditButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.glass(0.7),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/profile/edit'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.edit_outlined,
                size: 15,
                color: VentlyColors.berryMagenta,
              ),
              const SizedBox(width: 6),
              Text(
                'Edit profile',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: context.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings gear that lives in the hero card (top-right of the username row).
/// Moved here from the app bar so the profile header can hug the top of the
/// screen — no more empty "Profile" title band above the card.
class _HeroSettingsButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.glass(0.6),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => context.push('/settings'),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(Icons.settings_outlined, size: 18, color: context.ink),
        ),
      ),
    );
  }
}

class _QuickActionsBar extends StatelessWidget {
  const _QuickActionsBar();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Action(
            icon: Icons.edit_outlined,
            label: 'Drop',
            onTap: () => context.go('/compose'),
          ),
          _Action(
            icon: Icons.help_outline_rounded,
            label: 'Ask',
            onTap: () => context.push('/questions'),
          ),
          // The glowing mark in the middle is gone.
          //
          // It opened /compose — the same screen as Drop, two controls to its
          // left in the same row. So the row had four labelled actions and one
          // unlabelled duplicate of the first, drawn as two vertical bars
          // inside a glowing white disc, which on a row of buttons reads as a
          // pause control. Four things that each do one thing.
          _Action(
            icon: Icons.menu_book_rounded,
            label: 'Story',
            onTap: () => context.push('/compose/story'),
          ),
          _Action(
            icon: Icons.groups_rounded,
            label: 'Tribes',
            onTap: () => context.push('/tribes'),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.glass(0.65),
                  border: Border.all(
                    color: VentlyColors.softMauve.withOpacity(0.4),
                  ),
                ),
                child: Icon(icon, color: VentlyColors.berryMagenta, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: context.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── friends card ───────────────────────────

class _FriendsCard extends StatelessWidget {
  const _FriendsCard({required this.friends});
  final List<FriendSummary> friends;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.people_alt_rounded, title: 'Friends'),
          const SizedBox(height: 6),
          Text(
            'Meaningful friendships start here.',
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: context.ink.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 14),
          if (friends.isEmpty)
            Text(
              'No friends yet.',
              style: TextStyle(
                fontSize: 12,
                color: context.ink.withOpacity(0.5),
              ),
            )
          else
            SizedBox(
              height: 34,
              child: Stack(
                children: [
                  for (var i = 0; i < friends.take(3).length; i++)
                    Positioned(
                      left: i * 22.0,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: ProfileAvatar(
                          avatarSeed: friends[i].avatarSeed,
                          label: friends[i].pseudonym,
                          profilePhotoUrl: friends[i].profilePhotoUrl,
                          size: 30,
                        ),
                      ),
                    ),
                  if (friends.length > 3)
                    Positioned(
                      left: 3 * 22.0,
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: GlassTokens.cardChip(context),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: GlassTokens.cardEdge(context),
                            width: 2,
                          ),
                        ),
                        child: Text(
                          '+${friends.length - 3}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: GlassTokens.onCard(context),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const Spacer(),
          const SizedBox(height: 12),
          // The "Find Friends" grey, which was white at 70% with berry text on
          // it: about 1.8:1, the washed-out pink-on-grey it always looked
          // like. It reads in neither theme — in light it is a near-white pill
          // on a white card, in dark it is a bright slab with faint type.
          Material(
            color: GlassTokens.cardChip(context),
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => context.push('/friends'),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        'Find friends',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                          color: VentlyColors.berryMagenta,
                        ),
                      ),
                    ),
                    SizedBox(width: 5),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 15,
                      color: VentlyColors.berryMagenta,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── personas card ───────────────────────────

class _PersonasCard extends ConsumerWidget {
  const _PersonasCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(myPersonasProvider).valueOrNull ?? const [];
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Expanded(
                child: _CardTitle(
                  icon: Icons.theater_comedy_outlined,
                  title: 'Personas',
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: VentlyColors.softMauve),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Switch identities. Stay true to you.',
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: context.ink.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final p in personas.take(3))
                Expanded(child: _PersonaChip(persona: p)),
              Expanded(
                child: _PersonaCreate(
                  onTap: () => _createPersona(context, ref),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createPersona(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => ModalTextControllerScope(
        initialValues: const [''],
        builder: (ctx, controllers) {
          final controller = controllers.single;
          return AlertDialog(
            title: const Text('New persona'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 24,
              decoration: const InputDecoration(hintText: 'Persona name'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref
          .read(repositoryProvider)
          .createPersona(
            pseudonym: name,
            avatarSeed: 'persona-${DateTime.now().millisecondsSinceEpoch}',
          );
      ref.invalidate(myPersonasProvider);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t create that persona. Please try again.'),
        ),
      );
    }
  }
}

class _PersonaChip extends ConsumerWidget {
  const _PersonaChip({required this.persona});
  final Persona persona;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(activePersonaProvider.notifier).state = persona,
      child: Column(
        children: [
          ProfileAvatar(
            avatarSeed: persona.avatarSeed,
            label: persona.pseudonym,
            size: 46,
          ),
          const SizedBox(height: 5),
          Text(
            persona.pseudonym,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: context.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonaCreate extends StatelessWidget {
  const _PersonaCreate({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: VentlyColors.softMauve,
                width: 1.5,
                style: BorderStyle.solid,
              ),
            ),
            child: const Icon(
              Icons.add_rounded,
              color: VentlyColors.berryMagenta,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Create new',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: context.ink,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── highlights card ───────────────────────────

class _HighlightsCard extends StatelessWidget {
  const _HighlightsCard({
    required this.hearts,
    required this.replies,
    required this.comforted,
  });

  final int hearts;
  final int replies;
  final int comforted;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            icon: Icons.trending_up_rounded,
            title: "This week's highlights",
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  icon: Icons.favorite_rounded,
                  value: hearts,
                  label: 'Hearts\nReceived',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  icon: Icons.chat_bubble_outline_rounded,
                  value: replies,
                  label: 'Replies\nShared',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  icon: Icons.auto_awesome_rounded,
                  value: comforted,
                  label: 'People\nComforted',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            "You're making a difference.",
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.ink.withOpacity(0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      // The "This week" pillars: white at 45%, which lands on about #737373
      // over a black page, carrying off-white type. That is 3.1:1 for the
      // value and 2.0:1 for the label — the "Hearts Receiv ed" mush that has
      // been in every screenshot of this screen.
      decoration: BoxDecoration(
        color: GlassTokens.cardChip(context),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: VentlyColors.berryMagenta, size: 18),
          const SizedBox(height: 6),
          Text(
            '$value',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 17,
              color: GlassTokens.onCard(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: GlassTokens.onCardMuted(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── badges card ───────────────────────────

class _BadgesCard extends ConsumerWidget {
  const _BadgesCard({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogue = ref.watch(badgeCatalogueProvider).valueOrNull ?? const [];
    final earned =
        ref.watch(badgesForUserProvider(userId)).valueOrNull ?? const [];
    final byKey = {for (final b in catalogue) b.key: b};
    final earnedDefs = earned
        .map((e) => byKey[e.key])
        .whereType<BadgeDefinition>()
        .take(4)
        .toList();

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Expanded(
                child: _CardTitle(
                  icon: Icons.emoji_events_rounded,
                  title: 'Badges',
                ),
              ),
              Text(
                'See all',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: VentlyColors.berryMagenta,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (earnedDefs.isEmpty)
            Text(
              'No badges yet — keep showing up.',
              style: TextStyle(
                fontSize: 12,
                color: context.ink.withOpacity(0.55),
              ),
            )
          else
            Row(
              children: [
                for (final b in earnedDefs)
                  Expanded(child: _BadgeMedallion(def: b)),
              ],
            ),
        ],
      ),
    );
  }
}

class _BadgeMedallion extends StatelessWidget {
  const _BadgeMedallion({required this.def});
  final BadgeDefinition def;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [Colors.white, VentlyColors.softMauve.withOpacity(0.35)],
            ),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: VentlyColors.berryMagenta.withOpacity(0.15),
                blurRadius: 8,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(def.icon, style: const TextStyle(fontSize: 22)),
        ),
        const SizedBox(height: 5),
        Text(
          def.label,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 9,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: context.ink.withOpacity(0.7),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────── shared ───────────────────────────

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: GlassTokens.cardChip(context),
          ),
          child: Icon(icon, size: 17, color: VentlyColors.berryMagenta),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
              color: context.ink,
            ),
          ),
        ),
      ],
    );
  }
}
