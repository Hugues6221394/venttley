import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tagged_text.dart';

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

  // Derived from real signals — not a flat fake. Verified + karma + standing.
  int _trust() {
    var s = 72;
    if (me.isVerified) s += 12;
    s += (me.karmaPoints ~/ 20).clamp(0, 16);
    return s.clamp(0, 100);
  }

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

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      child: Column(
        children: [
          _HeroCard(
            me: me,
            level: _level(),
            trust: _trust(),
            posts: postsTotal,
            connections: friends.length,
            hugs: hugsReceived,
          ),
          const SizedBox(height: 14),
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
    );
  }
}

// ─────────────────────────────── hero ───────────────────────────────

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.me,
    required this.level,
    required this.trust,
    required this.posts,
    required this.connections,
    required this.hugs,
  });

  final AppUser me;
  final int level;
  final int trust;
  final int posts;
  final int connections;
  final int hugs;

  @override
  Widget build(BuildContext context) {
    final banner = me.profileBannerUrl?.trim() ?? '';
    return GlassCard(
      // Zero here so the banner can run to the card's edges; the old all-16
      // padding moved onto the content below it. GlassCard already clips to its
      // radius, so a full-bleed image keeps the rounded corners.
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Your own background, on your own profile.
          //
          // The public profile renders this in _HeroBanner, but self-viewing
          // redirects to /profile — so without this the person who chose the
          // image was the one person in the app who could never see it, which
          // reads as an upload that silently failed.
          if (banner.isNotEmpty)
            // Presentational only. Editing lives in the avatar's sheet, which
            // already carries the background options — a second entry point
            // here would be a third way to reach one action.
            _OwnProfileBanner(url: banner),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _GlowAvatar(me: me),
                        const SizedBox(width: 14),
                        Expanded(
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
                                        fontWeight: FontWeight.w900,
                                        fontSize: 21,
                                        color: context.ink,
                                      ),
                                    ),
                                  ),
                                  if (me.isVerified) ...[
                                    const SizedBox(width: 6),
                                    const Icon(
                                      Icons.verified_rounded,
                                      color: VentlyColors.berryMagenta,
                                      size: 20,
                                    ),
                                  ],
                                ],
                              ),
                              Text(
                                '@${me.anonymousPseudonym}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.ink.withOpacity(0.58),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  const _Pill(
                                    icon: Icons.shield_outlined,
                                    label: 'Verified Anonymous',
                                  ),
                                  _Pill(
                                    icon: Icons.bar_chart_rounded,
                                    label: 'Level $level Listener',
                                  ),
                                  if (!me.isVerified) _VerificationPill(),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: TaggedText(
                                  (me.bio?.trim().isNotEmpty ?? false)
                                      ? me.bio!.trim()
                                      : 'Here to listen, never to judge.',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.4,
                                    fontWeight: FontWeight.w600,
                                    color: context.ink.withOpacity(0.78),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Icons.monitor_heart_outlined,
                                size: 16,
                                color: VentlyColors.berryMagenta.withOpacity(
                                  0.7,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _EditButton(),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _StatsPanel(
                      posts: posts,
                      connections: connections,
                      hugs: hugs,
                      trust: trust,
                    ),
                  ],
                ),
                // Settings gear floats in the card's top-right corner so it
                // never squeezes the username row.
                Positioned(top: 0, right: 0, child: _HeroSettingsButton()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The chosen background, shown on your own profile card.
class _OwnProfileBanner extends StatelessWidget {
  const _OwnProfileBanner({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, __) =>
                const ColoredBox(color: VentlyColors.roseTint),
            errorWidget: (_, __, ___) =>
                const ColoredBox(color: VentlyColors.roseTint),
          ),
          // Fades into the card so the avatar below sits on a seamless
          // surface rather than against a hard photo edge.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.10),
                  Colors.transparent,
                  Theme.of(context).colorScheme.surface.withOpacity(0.55),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowAvatar extends ConsumerWidget {
  const _GlowAvatar({required this.me});
  final AppUser me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => _showPhotoSheet(context, ref),
      child: SizedBox(
        width: 96,
        height: 96,
        child: Stack(
          children: [
            // Pink glow ring.
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF9FC4), Color(0xFFE05C93)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: VentlyColors.berryMagenta.withOpacity(0.35),
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(4),
              child: ClipOval(
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: ProfileAvatar(
                      avatarSeed: me.avatarSeed,
                      label: me.anonymousPseudonym,
                      profilePhotoUrl: me.profilePhotoUrl,
                      size: 82,
                    ),
                  ),
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
        final ext = picked.path.split('.').last.toLowerCase();
        await ref
            .read(repositoryProvider)
            .uploadMyProfileBanner(
              bytes: bytes,
              extension: ext.isEmpty ? 'jpg' : ext,
              contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
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
            'banner-remove' => 'Background removed.',
            _ => 'Photo updated.',
          }),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not update photo: $e')),
      );
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: context.glass(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: VentlyColors.berryMagenta),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: context.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Apply for verified" pill (shown only for un-verified users). Reflects the
/// caller's verification standing and opens an application sheet (migration 0109).
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

  Future<void> _openApplySheet(BuildContext context, WidgetRef ref) async {
    bool busy = false;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ModalTextControllerScope(
        initialValues: const [''],
        builder: (ctx, controllers) {
          final noteCtl = controllers.single;
          return StatefulBuilder(
            builder: (ctx, setSheet) {
              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 18,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Apply for verification',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: context.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'The verified check is earned. Tell us why your presence lifts '
                      'this community — our team reviews every application.',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.6),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: noteCtl,
                      maxLines: 4,
                      maxLength: 400,
                      decoration: InputDecoration(
                        hintText: 'Your case for verification (optional)',
                        filled: true,
                        fillColor: const Color(0xFFFFF1F6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() => busy = true);
                              try {
                                await ref
                                    .read(repositoryProvider)
                                    .requestVerification(
                                      note: noteCtl.text.trim().isEmpty
                                          ? null
                                          : noteCtl.text.trim(),
                                    );
                                ref.invalidate(myVerificationStatusProvider);
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Application submitted — we\'ll review it soon.',
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (!ctx.mounted) return;
                                setSheet(() => busy = false);
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      e.toString().replaceFirst(
                                        'Exception: ',
                                        '',
                                      ),
                                    ),
                                  ),
                                );
                              }
                            },
                      child: busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Submit application',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
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
                'Edit Profile',
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

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.posts,
    required this.connections,
    required this.hugs,
    required this.trust,
  });

  final int posts;
  final int connections;
  final int hugs;
  final int trust;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      decoration: BoxDecoration(
        color: context.glass(0.45),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.glassBorder),
      ),
      child: Row(
        children: [
          _Stat(
            icon: Icons.article_rounded,
            value: PostCard.compactNumber(posts),
            label: 'Posts',
            sub: 'Vents + Whispers',
            filled: true,
          ),
          _Stat(
            icon: Icons.people_alt_rounded,
            value: PostCard.compactNumber(connections),
            label: 'Connections',
            sub: 'Your circle',
          ),
          _Stat(
            icon: Icons.volunteer_activism_rounded,
            value: PostCard.compactNumber(hugs),
            label: 'Hugs',
            sub: 'Received',
          ),
          _Stat(
            icon: Icons.verified_user_rounded,
            value: '$trust%',
            label: 'Trust Score',
            sub: trust >= 80 ? 'Safe & positive' : 'Building',
            filled: true,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    required this.sub,
    this.filled = false,
  });

  final IconData icon;
  final String value;
  final String label;
  final String sub;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: filled ? VentlyGradients.brand : null,
              color: filled ? null : context.glass(0.7),
            ),
            child: Icon(
              icon,
              size: 20,
              color: filled ? Colors.white : VentlyColors.berryMagenta,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 18,
              color: context.ink,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: context.ink.withOpacity(0.75),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: context.ink.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── quick actions ───────────────────────────

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
          const _CenterAction(),
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

/// The elevated, glowing centre button — the Venttly mark (two rounded bars).
class _CenterAction extends StatelessWidget {
  const _CenterAction();

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: () => context.go('/compose'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.85),
                boxShadow: [
                  BoxShadow(
                    color: VentlyColors.berryMagenta.withOpacity(0.35),
                    blurRadius: 20,
                    spreadRadius: 1,
                  ),
                ],
                border: Border.all(color: Colors.white, width: 3),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [_bar(), const SizedBox(width: 5), _bar()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar() => Container(
    width: 9,
    height: 26,
    decoration: BoxDecoration(
      gradient: VentlyGradients.brand,
      borderRadius: BorderRadius.circular(5),
    ),
  );
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
                          color: Colors.white.withOpacity(0.8),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Text(
                          '+${friends.length - 3}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: context.ink,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const Spacer(),
          const SizedBox(height: 12),
          Material(
            color: Colors.white.withOpacity(0.7),
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
                        'Find Friends',
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
            'Create New',
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
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.45),
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
              color: context.ink,
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
              color: context.ink.withOpacity(0.6),
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
            color: Colors.white.withOpacity(0.7),
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
