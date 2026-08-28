import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/connection.dart';
import '../../../core/analytics_events.dart';
import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/services/music_playback_service.dart';
import '../../../data/services/outbox.dart';
import '../../../data/services/analytics_service.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/music_track_card.dart';

/// Create Vent Story screen — Image #9.
///
/// Four story sources (Capture Photo / Gallery / Text Only / Audio Note),
/// live preview card, privacy + duration row, single Share-to-Story CTA.
class CreateStoryScreen extends ConsumerStatefulWidget {
  const CreateStoryScreen({super.key});

  @override
  ConsumerState<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

enum _StoryMode { idle, text, photo }

class _CreateStoryScreenState extends ConsumerState<CreateStoryScreen> {
  _StoryMode _mode = _StoryMode.idle;
  Uint8List? _imageBytes;
  String _imageExtension = 'jpg';
  String _imageContentType = 'image/jpeg';
  bool _friendsOnly = false;
  bool _busy = false;
  MusicTrack? _selectedMusic;
  late final MusicPlaybackController _musicPlayback;
  final TextEditingController _caption = TextEditingController();

  @override
  void initState() {
    super.initState();
    _musicPlayback = ref.read(musicPlaybackProvider);
  }

  @override
  void dispose() {
    unawaited(_musicPlayback.stop());
    _caption.dispose();
    super.dispose();
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1600,
    );
    await _ingestPicked(picked);
  }

  Future<void> _captureFromCamera() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
      maxWidth: 1600,
    );
    await _ingestPicked(picked);
  }

  Future<void> _ingestPicked(XFile? picked) async {
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
    setState(() {
      _mode = _StoryMode.photo;
      _imageBytes = bytes;
      _imageExtension = ext;
      _imageContentType = _mimeFor(ext);
    });
  }

  void _selectText() {
    setState(() {
      _mode = _StoryMode.text;
      _imageBytes = null;
    });
  }

  Future<void> _pickMusic() async {
    final picked = await showMusicPicker(context, selected: _selectedMusic);
    if (picked == null || !mounted) return;
    setState(() => _selectedMusic = picked);
    unawaited(
      AnalyticsService.instance.track(
        Events.musicAttached,
        props: {'provider': picked.provider},
      ),
    );
  }

  bool get _canShare {
    if (_busy) return false;
    if (_mode == _StoryMode.photo) {
      return _imageBytes != null;
    }
    if (_mode == _StoryMode.text) {
      return _caption.text.trim().isNotEmpty;
    }
    return false;
  }

  bool get _shouldUploadImage =>
      _mode == _StoryMode.photo && _imageBytes != null;

  Future<void> _share() async {
    if (!_canShare) return;
    setState(() => _busy = true);
    final captionText = _caption.text.trim();
    final operationId = OutboxService.newOperationId();
    final outbox = await ref.read(outboxProvider.future);
    StagedOutboxMedia? stagedMedia;
    String? imageUrl;
    String? imagePath;
    try {
      final repo = ref.read(repositoryProvider);
      if (_shouldUploadImage) {
        stagedMedia = await outbox.stageMedia(
          operationId: operationId,
          bytes: _imageBytes!,
          extension: _imageExtension,
          contentType: _imageContentType,
          mediaType: 'image',
        );
        final upload = await repo.uploadPostImage(
          bytes: _imageBytes!,
          extension: _imageExtension,
          contentType: _imageContentType,
        );
        imageUrl = upload.url;
        imagePath = upload.path;
      }
      final story = await repo.createPost(
        content: captionText.isEmpty ? 'Shared a moment.' : captionText,
        category: 'late_night',
        mood: 'healing',
        isStory: true,
        storyAudience: _friendsOnly ? 'friends' : 'everyone',
        imagePath: imagePath,
        imageUrl: imageUrl,
        musicTrack: _selectedMusic,
        idempotencyKey: operationId,
      );
      final musicWasDropped = _selectedMusic != null && !story.hasMusic;
      await outbox.discardStagedMedia(stagedMedia?.path);
      ref.invalidate(feedPostsProvider);
      ref.invalidate(homeStatsProvider);
      ref.invalidate(homeFriendStoriesProvider);
      ref.invalidate(friendStoryPostsProvider);
      ref.invalidate(liveStoriesProvider);
      if (!mounted) return;
      context.go('/feed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            musicWasDropped
                ? "Story posted, but music isn't available right now."
                : 'Story posted for 24 hours.',
          ),
        ),
      );
    } catch (e) {
      if (!_shouldUploadImage || stagedMedia != null) {
        try {
          await outbox.enqueue(OutboxKind.post, {
            'content': captionText.isEmpty ? 'Shared a moment.' : captionText,
            'category': 'late_night',
            'mood': 'healing',
            'isStory': true,
            'storyAudience': _friendsOnly ? 'friends' : 'everyone',
            'imagePath': imagePath,
            'imageUrl': imageUrl,
            if (stagedMedia != null) ...stagedMedia.toPayload(),
            if (_selectedMusic != null)
              'musicTrack': _musicTrackPayload(_selectedMusic!),
            if (_selectedMusic != null) ...{
              'musicStartMs': 0,
              'musicDurationMs': 15000,
              'musicVolume': 0.75,
            },
          }, operationId: operationId);
          if (!mounted) return;
          context.go('/feed');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Story queued and will post automatically.'),
            ),
          );
          return;
        } catch (_) {
          // Fall through to the persistent error state below.
        }
      }
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(e, fallback: 'Could not post story.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _Header(onClose: () => context.go('/feed')),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LivePreview(
                      mode: _mode,
                      imageBytes: _imageBytes,
                      caption: _caption.text,
                      musicTrack: _selectedMusic,
                    ),
                    const SizedBox(height: 18),
                    if (_mode == _StoryMode.text || _imageBytes != null)
                      _CaptionField(
                        controller: _caption,
                        onChanged: (_) => setState(() {}),
                        isImage: _imageBytes != null,
                      ),
                    if (_mode == _StoryMode.text || _imageBytes != null)
                      const SizedBox(height: 18),
                    _SourceGrid(
                      mode: _mode,
                      onCapturePhoto: _captureFromCamera,
                      onGallery: _pickFromGallery,
                      onTextOnly: _selectText,
                      onAudioNote: () => context.push('/whispers/new'),
                    ),
                    if (flagEnabled(ref, 'vent_music', fallback: false)) ...[
                      const SizedBox(height: 14),
                      if (_selectedMusic == null)
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _pickMusic,
                            icon: const Icon(Icons.music_note_rounded),
                            label: const Text('Add Music'),
                          ),
                        )
                      else
                        MusicTrackCard(
                          track: _selectedMusic!,
                          onChange: _pickMusic,
                          onRemove: () {
                            unawaited(
                              AnalyticsService.instance.track(
                                Events.musicRemoved,
                              ),
                            );
                            setState(() => _selectedMusic = null);
                          },
                        ),
                    ],
                    const SizedBox(height: 18),
                    _PrivacyDurationCard(
                      friendsOnly: _friendsOnly,
                      onFriendsToggle: (v) => setState(() => _friendsOnly = v),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _canShare ? _share : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: VentlyColors.berryMagenta,
                    disabledBackgroundColor: VentlyColors.berryMagenta
                        .withOpacity(0.45),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.6,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Share to Story',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                            SizedBox(width: 6),
                            Icon(Icons.send_rounded, size: 16),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _mimeFor(String ext) {
    switch (ext.toLowerCase().replaceAll('.', '')) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'heic':
      case 'heif':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }

  Map<String, Object?> _musicTrackPayload(MusicTrack track) => {
    'trackId': track.trackId,
    'provider': track.provider,
    'providerTrackId': track.providerTrackId,
    'title': track.title,
    'artist': track.artist,
    'album': track.album,
    'artworkUrl': track.artworkUrl,
    'previewUrl': track.previewUrl,
    'previewDurationMs': track.previewDurationMs,
    'genre': track.genre,
    'moodTags': track.moodTags,
    'licenseCode': track.licenseCode,
    'attributionText': track.attributionText,
    'cacheAllowed': track.cacheAllowed,
  };
}

// =========================================================================
// HEADER
// =========================================================================

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: VentlyColors.berryMagenta),
            onPressed: onClose,
          ),
          const SizedBox(width: 2),
          const Text(
            'Venttly',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontWeight: FontWeight.w900,
              fontSize: 22,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              color: context.ink.withOpacity(0.78),
            ),
            tooltip: 'Story settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// LIVE PREVIEW
// =========================================================================

class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.mode,
    required this.imageBytes,
    required this.caption,
    required this.musicTrack,
  });
  final _StoryMode mode;
  final Uint8List? imageBytes;
  final String caption;
  final MusicTrack? musicTrack;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 9 / 14,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageBytes != null)
              Image.memory(imageBytes!, fit: BoxFit.cover)
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFFFD8E5),
                      Color(0xFFFF91B7),
                      Color(0xFFB91452),
                    ],
                  ),
                ),
              ),
            if (imageBytes != null)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x66000000)],
                  ),
                ),
              ),
            Positioned(
              left: 16,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.36),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: VentlyColors.berryMagenta,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'LIVE PREVIEW',
                      style: TextStyle(
                        color: context.ink,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (imageBytes == null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.22),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.favorite_rounded,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      caption.trim().isEmpty
                          ? 'Share your mood today…'
                          : caption.trim(),
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              )
            else if (caption.trim().isNotEmpty)
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: Text(
                  caption.trim(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            if (musicTrack != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 18,
                child: Material(
                  color: Colors.transparent,
                  child: MusicTrackCard(track: musicTrack!, compact: true),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// CAPTION FIELD
// =========================================================================

class _CaptionField extends StatelessWidget {
  const _CaptionField({
    required this.controller,
    required this.onChanged,
    required this.isImage,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool isImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.42)),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        maxLength: 280,
        maxLines: 3,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          border: InputBorder.none,
          counterText: '',
          hintText: isImage
              ? 'Add an optional caption…'
              : 'Type the moment you want to share…',
          hintStyle: TextStyle(
            color: context.ink.withOpacity(0.42),
            fontWeight: FontWeight.w700,
          ),
        ),
        style: TextStyle(
          color: context.ink,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );
  }
}

// =========================================================================
// 2×2 SOURCE GRID
// =========================================================================

class _SourceGrid extends StatelessWidget {
  const _SourceGrid({
    required this.mode,
    required this.onCapturePhoto,
    required this.onGallery,
    required this.onTextOnly,
    required this.onAudioNote,
  });
  final _StoryMode mode;
  final VoidCallback onCapturePhoto;
  final VoidCallback onGallery;
  final VoidCallback onTextOnly;
  final VoidCallback onAudioNote;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.2,
      children: [
        _SourceTile(
          label: 'Capture Photo',
          icon: Icons.photo_camera_rounded,
          bg: VentlyColors.berryMagenta,
          iconColor: Colors.white,
          onTap: onCapturePhoto,
        ),
        _SourceTile(
          label: 'Gallery',
          icon: Icons.photo_library_outlined,
          bg: const Color(0xFFFFD8E5),
          iconColor: VentlyColors.berryMagenta,
          onTap: onGallery,
        ),
        _SourceTile(
          label: 'Text Only',
          icon: Icons.edit_note_rounded,
          bg: const Color(0xFF2E7D44),
          iconColor: Colors.white,
          selected: mode == _StoryMode.text,
          onTap: onTextOnly,
        ),
        _SourceTile(
          label: 'Audio Note',
          icon: Icons.mic_none_rounded,
          bg: const Color(0xFFFFE3EC),
          iconColor: VentlyColors.berryMagenta,
          onTap: onAudioNote,
        ),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.label,
    required this.icon,
    required this.bg,
    required this.iconColor,
    required this.onTap,
    this.selected = false,
  });
  final String label;
  final IconData icon;
  final Color bg;
  final Color iconColor;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? VentlyColors.berryMagenta
                  : VentlyColors.softMauve.withOpacity(0.42),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// PRIVACY + DURATION CARD
// =========================================================================

class _PrivacyDurationCard extends StatelessWidget {
  const _PrivacyDurationCard({
    required this.friendsOnly,
    required this.onFriendsToggle,
  });
  final bool friendsOnly;
  final ValueChanged<bool> onFriendsToggle;

  @override
  Widget build(BuildContext context) {
    // Material, not a decorated Container: the ListTiles below paint their
    // background and ink splashes onto the nearest Material ancestor, so a
    // plain colour box between them and the sheet swallows those effects —
    // and trips a debug assertion on every build.
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: VentlyColors.softMauve.withOpacity(0.40)),
      ),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(
              Icons.remove_red_eye_outlined,
              color: VentlyColors.berryMagenta,
            ),
            title: Text(
              'Privacy Settings',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 13.5,
              ),
            ),
            subtitle: Text(
              friendsOnly ? 'Friends only' : 'Everyone on Venttly',
              style: TextStyle(
                color: context.ink.withOpacity(0.62),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            trailing: Switch.adaptive(
              value: friendsOnly,
              activeColor: VentlyColors.berryMagenta,
              onChanged: onFriendsToggle,
            ),
          ),
          Divider(color: VentlyColors.softMauve.withOpacity(0.30), height: 1),
          ListTile(
            leading: const Icon(
              Icons.timer_outlined,
              color: VentlyColors.berryMagenta,
            ),
            title: Text(
              'Story Duration',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 13.5,
              ),
            ),
            trailing: const Text(
              '24 Hours',
              style: TextStyle(
                color: VentlyColors.berryMagenta,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
