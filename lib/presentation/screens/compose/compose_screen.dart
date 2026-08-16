import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../animation/widgets/animated_button.dart';
import '../../../core/constants.dart';
import '../../../core/connection.dart';
import '../../../core/analytics_events.dart';
import '../../../core/providers.dart';
import '../../../data/services/draft_store.dart';
import '../../../data/services/analytics_service.dart';
import '../../../data/services/moderation_service.dart';
import '../../../data/services/music_playback_service.dart';
import '../../../data/services/outbox.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../theme/vent_card_style.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/mood_chip.dart';
import '../../widgets/music_track_card.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/vently_premium_background.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, this.queryParams = const {}});

  /// Deep-link query params, e.g. `format=poll`, `category=questions`.
  final Map<String, String> queryParams;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  final _pollQ = TextEditingController();
  final _pollA = TextEditingController();
  final _pollB = TextEditingController();
  String _category = 'confessions';
  String _mood = 'healing';
  bool _busy = false;
  bool _success = false;
  bool _includePoll = false;
  bool _isWhisper = false;
  bool _storyFriendsOnly = true;
  String? _cardBackgroundColor;
  String? _cardTextColor;
  MusicTrack? _selectedMusic;
  late final MusicPlaybackController _musicPlayback;

  // Optional attached photo. Bytes live in memory until submit; we
  // only upload on send so a discard costs zero network.
  Uint8List? _pendingImageBytes;
  String _pendingImageExt = 'jpg';
  String _pendingImageMime = 'image/jpeg';

  DraftSaver? _draftSaver;

  @override
  void initState() {
    super.initState();
    _musicPlayback = ref.read(musicPlaybackProvider);
    // Reading providers here is safe; WRITING them is not — initState runs
    // during the route's first build and Riverpod throws "tried to modify a
    // provider while the widget tree was building". So: consume the one-shot
    // intents locally, and defer the resets to after the first frame.
    _isWhisper = ref.read(composeStoryModeProvider);
    _includePoll = ref.read(composeIncludePollProvider);
    String? initialCategory = ref.read(composeInitialCategoryProvider);
    String? initialDraft = ref.read(composeInitialDraftProvider);

    // Deep-link query params (/compose?format=poll&category=…) override the
    // sheet-set intents — applied locally, no provider round-trip.
    final q = widget.queryParams;
    if (q.isNotEmpty) {
      if (q['format'] == 'poll') {
        _includePoll = true;
        initialCategory = 'questions';
      }
      final qCategory = q['category'];
      if (qCategory != null && FeedCategories.all.contains(qCategory)) {
        initialCategory = qCategory;
      }
      final qDraft = q['draft'];
      if (qDraft != null && qDraft.isNotEmpty) initialDraft = qDraft;
    }

    if (initialCategory != null &&
        FeedCategories.all.contains(initialCategory)) {
      _category = initialCategory;
    }
    if (initialDraft != null && initialDraft.isNotEmpty) {
      _controller.text = initialDraft;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(composeStoryModeProvider.notifier).state = false;
      ref.read(composeIncludePollProvider.notifier).state = false;
      ref.read(composeInitialCategoryProvider.notifier).state = null;
      ref.read(composeInitialDraftProvider.notifier).state = null;
    });

    // Crash-safe draft: restore what the user typed last time (unless an
    // explicit draft was handed in) and auto-save while they type.
    ref.read(draftStoreProvider.future).then((store) {
      if (!mounted) return;
      _draftSaver = DraftSaver(
        store: store,
        draftKey: 'compose',
        controller: _controller,
      );
      if (_draftSaver!.restore()) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_musicPlayback.stop());
    _draftSaver?.dispose();
    _controller.dispose();
    _pollQ.dispose();
    _pollA.dispose();
    _pollB.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto({required ImageSource source}) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ext = picked.path.split('.').last.toLowerCase();
      setState(() {
        _pendingImageBytes = bytes;
        _pendingImageExt = ext == 'jpeg' ? 'jpg' : ext;
        _pendingImageMime = picked.mimeType ?? 'image/jpeg';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not pick image: $e')));
    }
  }

  Future<void> _openPhotoSourceSheet() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.photo_library_outlined,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Choose from library',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.photo_camera_outlined,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Take a photo',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
    if (source != null) await _pickPhoto(source: source);
  }

  Future<void> _openStyleSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final effectiveText = VentCardStyle.readableTextFor(
            _cardBackgroundColor,
            _cardTextColor,
          );
          final availableTextColors = _cardBackgroundColor == null
              ? <String?>[null]
              : VentCardStyle.textColors
                    .where(
                      (color) =>
                          VentCardStyle.readableTextFor(
                            _cardBackgroundColor,
                            color,
                          ) ==
                          color,
                    )
                    .toList();

          void refresh(VoidCallback update) {
            setState(update);
            setSheetState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Vent style',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Choose a card and word color. Unreadable combinations are filtered out.',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.62),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Background',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final color in VentCardStyle.backgrounds)
                        _ComposeColorSwatch(
                          color: color == null
                              ? Theme.of(context).cardColor
                              : VentCardStyle.parse(color)!,
                          label: VentCardStyle.backgroundLabel(color),
                          selected: _cardBackgroundColor == color,
                          onTap: () => refresh(() {
                            _cardBackgroundColor = color;
                            _cardTextColor = VentCardStyle.readableTextFor(
                              color,
                              _cardTextColor,
                            );
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Words',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final color in availableTextColors)
                        _ComposeColorSwatch(
                          color: color == null
                              ? Theme.of(context).colorScheme.onSurface
                              : VentCardStyle.parse(color)!,
                          label: VentCardStyle.textLabel(color),
                          selected: effectiveText == color,
                          onTap: () => refresh(() => _cardTextColor = color),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openMusicPicker() async {
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

  Future<bool> _confirmMusicPreview() async {
    final track = _selectedMusic;
    if (track == null) return true;
    final me = ref.read(sessionProvider);
    final persona = ref.read(activePersonaProvider);
    final body = _controller.text.trim();
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Preview your Vent',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      persona?.pseudonym ?? me?.displayName ?? 'Anonymous',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(body, maxLines: 8, overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 12),
                    MusicTrackCard(track: track),
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        Icon(Icons.favorite_border, size: 18),
                        SizedBox(width: 4),
                        Text('0'),
                        SizedBox(width: 18),
                        Icon(Icons.chat_bubble_outline, size: 18),
                        SizedBox(width: 4),
                        Text('0'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    child: const Text('Publish'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await ref.read(musicPlaybackProvider).stop();
    return result ?? false;
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
  };

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingImageBytes == null) return;
    if (_includePoll) {
      if (_pollQ.text.trim().length < 4 ||
          _pollA.text.trim().isEmpty ||
          _pollB.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Add a poll question and two options, or untoggle the poll.',
            ),
          ),
        );
        return;
      }
    }
    if (_selectedMusic != null) {
      final confirmed = await _confirmMusicPreview();
      if (!confirmed || !mounted) return;
    }
    setState(() => _busy = true);
    final moderation = await ref.read(moderationServiceProvider).review(text);
    if (!mounted) return;
    if (moderation.isBlocked) {
      setState(() => _busy = false);
      _showBlocked(moderation);
      return;
    }
    if (moderation.isWarn) {
      final proceed = await _confirmWarn(moderation);
      if (!proceed) {
        setState(() => _busy = false);
        return;
      }
    }
    final space = ref.read(composeTargetSpaceProvider);
    final selectedTribe = ref.read(composeTargetTribeProvider);
    final repository = ref.read(repositoryProvider);
    final tribe =
        selectedTribe ??
        (space == null ? null : await repository.tribeBySlug(space.tribeSlug));
    if (!mounted) return;
    final effectiveTribeId = space?.tribeId ?? tribe?.tribeId;
    final effectiveTribeSlug = space?.tribeSlug ?? tribe?.slug;
    if (_includePoll &&
        tribe != null &&
        !TribeGovernanceSettings.fromJson(
          tribe.managementSettings,
        ).allowPolls) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Polls are disabled in this Tribe.')),
      );
      return;
    }
    final persona = ref.read(activePersonaProvider);
    final operationId = OutboxService.newOperationId();
    final outbox = await ref.read(outboxProvider.future);

    StagedOutboxMedia? stagedMedia;
    Future<void> queuePost({String? imagePath, String? imageUrl}) async {
      await outbox.enqueue(OutboxKind.post, {
        'content': text,
        'category': _category,
        'mood': _mood,
        'tribeId': effectiveTribeId,
        'spaceId': space?.spaceId,
        'personaId': persona?.personaId,
        'isStory': _isWhisper,
        'storyAudience': 'friends',
        'imagePath': imagePath,
        'imageUrl': imageUrl,
        'cardBackgroundColor': _cardBackgroundColor,
        'cardTextColor': VentCardStyle.readableTextFor(
          _cardBackgroundColor,
          _cardTextColor,
        ),
        if (_selectedMusic != null)
          'musicTrack': _musicTrackPayload(_selectedMusic!),
        if (stagedMedia != null) ...stagedMedia.toPayload(),
      }, operationId: operationId);
      await _draftSaver?.clear();
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "You're offline - your vent is queued and will post automatically.",
          ),
        ),
      );
      context.pop();
    }

    // Encrypt the original bytes before upload. If either the upload or the
    // row write fails, the same outbox operation can finish both steps later.
    String? imagePath;
    String? imageUrl;
    if (_pendingImageBytes != null) {
      try {
        stagedMedia = await outbox.stageMedia(
          operationId: operationId,
          bytes: _pendingImageBytes!,
          extension: _pendingImageExt,
          contentType: _pendingImageMime,
          mediaType: 'image',
        );
        final up = await ref
            .read(repositoryProvider)
            .uploadPostImage(
              bytes: _pendingImageBytes!,
              extension: _pendingImageExt,
              contentType: _pendingImageMime,
            );
        imagePath = up.path;
        imageUrl = up.url;
      } catch (e) {
        if (!mounted) return;
        if (!_includePoll && stagedMedia != null) {
          await queuePost();
          return;
        }
        await outbox.discardStagedMedia(stagedMedia?.path);
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
        return;
      }
    }

    final Post post;
    try {
      post = await ref
          .read(repositoryProvider)
          .createPost(
            content: text.isEmpty ? '' : text,
            category: _category,
            mood: _mood,
            tribeId: effectiveTribeId,
            spaceId: space?.spaceId,
            personaId: persona?.personaId,
            isStory: _isWhisper,
            storyAudience: 'friends',
            imagePath: imagePath,
            imageUrl: imageUrl,
            pollQuestion: _includePoll ? _pollQ.text.trim() : null,
            pollOptions: _includePoll
                ? [_pollA.text.trim(), _pollB.text.trim()]
                : null,
            cardBackgroundColor: _cardBackgroundColor,
            cardTextColor: VentCardStyle.readableTextFor(
              _cardBackgroundColor,
              _cardTextColor,
            ),
            musicTrack: _selectedMusic,
            idempotencyKey: operationId,
          );
    } catch (e) {
      // Offline or flaky network: queue the vent for automatic retry so
      // the user's words are never lost. Polls don't replay (rare combo).
      if (!_includePoll) {
        await queuePost(imagePath: imagePath, imageUrl: imageUrl);
        return;
      }
      await outbox.discardStagedMedia(stagedMedia?.path);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't post: $e — your draft is saved.")),
      );
      return;
    }
    await outbox.discardStagedMedia(stagedMedia?.path);
    final musicWasDropped = _selectedMusic != null && !post.hasMusic;
    await _draftSaver?.clear();
    // Crisis tag — readers see the helpline banner if the safety classifier
    // surfaced self-harm signals. 'high' = Tier-1 keyword match (more
    // confident), 'elevated' = Tier-2 LLM-only signal. Best-effort: the post
    // is already saved, we just decorate it.
    if (moderation.surfaceCrisisHelpline) {
      final level =
          moderation.categories.contains(HazardCategory.selfHarm) &&
              moderation.reasons.any((r) => r.contains('care about you'))
          ? 'high'
          : 'elevated';
      unawaited(ref.read(repositoryProvider).setPostCrisis(post.postId, level));
    }
    ref.read(composeTargetTribeProvider.notifier).state = null;
    ref.read(composeTargetSpaceProvider.notifier).state = null;
    ref.read(composeStoryModeProvider.notifier).state = false;
    ref.read(composeIncludePollProvider.notifier).state = false;
    ref.read(composeInitialCategoryProvider.notifier).state = null;
    // Live insertion: bump every feed the new vent might appear in
    // so SpaceHome / Tribe / global Feed pick up the row immediately
    // without waiting for the realtime tick.
    ref.invalidate(feedPostsProvider);
    if (space != null) {
      for (final s in [
        'fresh',
        'trending',
        'helpful',
        'unanswered',
        'keeper',
      ]) {
        ref.invalidate(
          spacePostsProvider(SpaceFeedQuery(spaceId: space.spaceId, sort: s)),
        );
      }
      ref.invalidate(spaceByIdProvider(space.spaceId));
      ref.invalidate(spacesByTribeProvider(space.tribeId));
    }
    if (!mounted) return;
    // Success beat: the button morphs to a check for a moment before the
    // route changes, so posting feels acknowledged rather than abrupt.
    setState(() {
      _busy = false;
      _success = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 550));
    if (!mounted) return;
    if (space != null) {
      context.go('/tribe/${space.tribeSlug}/space/${space.spaceId}');
    } else if (effectiveTribeSlug != null) {
      context.go('/tribe/$effectiveTribeSlug');
    } else {
      context.go('/feed');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          musicWasDropped
              ? "Vent posted, but music isn't available right now."
              : tribe == null
              ? (_isWhisper
                    ? 'Story posted for 24 hours.'
                    : 'Vent posted anonymously.')
              : 'Posted to ${tribe.name}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_isWhisper) {
      return _buildStoryComposer(context);
    }
    final Tribe? target = ref.watch(composeTargetTribeProvider);
    final personas = ref.watch(myPersonasProvider).valueOrNull ?? const [];
    final activePersona = ref.watch(activePersonaProvider);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/feed'),
        ),
        title: Text(_isWhisper ? 'New Story' : 'New Vent'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _submit,
            child: const Text('Post'),
          ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (target != null)
                  GlassCard(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    borderRadius: 14,
                    child: Row(
                      children: [
                        Icon(
                          Icons.diversity_3,
                          size: 16,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Posting in ${target.name}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            ref
                                    .read(composeTargetTribeProvider.notifier)
                                    .state =
                                null;
                            ref
                                    .read(composeTargetSpaceProvider.notifier)
                                    .state =
                                null;
                          },
                          tooltip: 'Post to general feed instead',
                        ),
                      ],
                    ),
                  ),
                if (personas.isNotEmpty)
                  GlassCard(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    borderRadius: 14,
                    child: Row(
                      children: [
                        Icon(
                          Icons.theater_comedy_outlined,
                          size: 16,
                          color: scheme.secondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            activePersona == null
                                ? 'Posting as your default handle'
                                : 'Posting as @${activePersona.pseudonym}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.secondary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _showPersonaPicker(
                            context,
                            personas,
                            activePersona,
                          ),
                          child: const Text('Switch'),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    const Text(
                      'Category',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final c in FeedCategories.all)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: ChoiceChip(
                                  label: Text(FeedCategories.label(c)),
                                  selected: _category == c,
                                  onSelected: (_) =>
                                      setState(() => _category = c),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Mood',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final m in Moods.all)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: ChoiceChip(
                                  avatar: Text(Moods.emoji(m)),
                                  label: Text(Moods.label(m)),
                                  selected: _mood == m,
                                  onSelected: (_) => setState(() => _mood = m),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_pendingImageBytes != null)
                  _PendingImageChip(
                    bytes: _pendingImageBytes!,
                    onClear: () => setState(() => _pendingImageBytes = null),
                  ),
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.all(12),
                    borderRadius: 20,
                    tint: VentCardStyle.parse(_cardBackgroundColor),
                    borderColor: _cardBackgroundColor == null
                        ? null
                        : VentCardStyle.parse(
                            VentCardStyle.readableTextFor(
                              _cardBackgroundColor,
                              _cardTextColor,
                            ),
                          )?.withOpacity(0.16),
                    child: TagAutocomplete(
                      controller: _controller,
                      fill: true,
                      child: TextField(
                        controller: _controller,
                        cursorColor: VentCardStyle.parse(
                          VentCardStyle.readableTextFor(
                            _cardBackgroundColor,
                            _cardTextColor,
                          ),
                        ),
                        style: TextStyle(
                          color: VentCardStyle.parse(
                            VentCardStyle.readableTextFor(
                              _cardBackgroundColor,
                              _cardTextColor,
                            ),
                          ),
                          fontSize: 16,
                          height: 1.45,
                        ),
                        maxLength: 1000,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText:
                              'Drop the thought. Keep names out, keep it real.',
                          filled: true,
                          fillColor: Colors.transparent,
                          hintStyle: TextStyle(
                            color: VentCardStyle.parse(
                              VentCardStyle.readableTextFor(
                                _cardBackgroundColor,
                                _cardTextColor,
                              ),
                            )?.withOpacity(0.55),
                          ),
                          counterStyle: TextStyle(
                            color: VentCardStyle.parse(
                              VentCardStyle.readableTextFor(
                                _cardBackgroundColor,
                                _cardTextColor,
                              ),
                            )?.withOpacity(0.72),
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      TextButton.icon(
                        onPressed: _openPhotoSourceSheet,
                        icon: Icon(
                          _pendingImageBytes != null
                              ? Icons.image
                              : Icons.image_outlined,
                          size: 18,
                          color: scheme.primary,
                        ),
                        label: Text(
                          _pendingImageBytes != null ? 'Photo on' : 'Photo',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _openStyleSheet,
                        icon: Icon(
                          Icons.palette_outlined,
                          size: 18,
                          color: scheme.primary,
                        ),
                        label: const Text('Style'),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _includePoll = !_includePoll),
                        icon: Icon(
                          _includePoll ? Icons.poll : Icons.poll_outlined,
                          size: 18,
                          color: scheme.primary,
                        ),
                        label: Text(_includePoll ? 'Poll on' : 'Poll'),
                      ),
                      if (flagEnabled(ref, 'vent_music', fallback: false))
                        TextButton.icon(
                          onPressed: _openMusicPicker,
                          icon: Icon(
                            _selectedMusic == null
                                ? Icons.music_note_outlined
                                : Icons.music_note_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                          label: Text(
                            _selectedMusic == null ? 'Music' : 'Music on',
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _isWhisper = !_isWhisper),
                        icon: Icon(
                          _isWhisper
                              ? Icons.nightlight
                              : Icons.nightlight_outlined,
                          size: 18,
                          color: scheme.primary,
                        ),
                        label: Text(_isWhisper ? 'Story - 24h' : '24h Story'),
                      ),
                      const SizedBox(width: 8),
                      MoodChip(mood: _mood, dense: true),
                    ],
                  ),
                ),
                if (_selectedMusic != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MusicTrackCard(
                      track: _selectedMusic!,
                      onChange: _openMusicPicker,
                      onRemove: () {
                        unawaited(
                          AnalyticsService.instance.track(Events.musicRemoved),
                        );
                        setState(() => _selectedMusic = null);
                      },
                    ),
                  ),
                if (_includePoll)
                  GlassCard(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(12),
                    borderRadius: 16,
                    child: Column(
                      children: [
                        TextField(
                          controller: _pollQ,
                          maxLength: 120,
                          decoration: const InputDecoration(
                            labelText: 'Poll question',
                            hintText: 'e.g. Should I text them back?',
                            counterText: '',
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _pollA,
                                maxLength: 60,
                                decoration: const InputDecoration(
                                  labelText: 'Option A',
                                  counterText: '',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _pollB,
                                maxLength: 60,
                                decoration: const InputDecoration(
                                  labelText: 'Option B',
                                  counterText: '',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                SafeArea(
                  top: false,
                  child: AnimatedButton(
                    label: 'Post Anonymously',
                    state: _success
                        ? VentlyButtonState.success
                        : _busy
                        ? VentlyButtonState.loading
                        : VentlyButtonState.idle,
                    onPressed: _submit,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStoryComposer(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      color: VentlyColors.berryMagenta,
                      onPressed: () => context.go('/feed'),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Venttly',
                      style: TextStyle(
                        color: Color(0xFFB91452),
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Story settings',
                      icon: const Icon(Icons.settings_outlined),
                      color: context.ink,
                      onPressed: () => context.push('/settings'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Column(
                    children: [
                      Container(
                        height: 430,
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0xFFFFB8CD),
                              Color(0xFFE56F9B),
                              Color(0xFFBD0E53),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: VentlyColors.berryMagenta.withOpacity(
                                0.20,
                              ),
                              blurRadius: 24,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: VentlyColors.deepBurgundy.withOpacity(
                                  0.16,
                                ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text(
                                'LIVE PREVIEW',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Center(
                              child: Container(
                                width: 106,
                                height: 106,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.18),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.22),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.favorite_rounded,
                                  color: Colors.white,
                                  size: 48,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            TextField(
                              controller: _controller,
                              maxLength: 220,
                              maxLines: 4,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                height: 1.28,
                              ),
                              decoration: InputDecoration(
                                counterText: '',
                                hintText: 'Share your mood today...',
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.88),
                                  fontWeight: FontWeight.w800,
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                            ),
                            const Spacer(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      GridView.count(
                        crossAxisCount: 2,
                        childAspectRatio: 1.2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          _StoryCreateOption(
                            icon: Icons.camera_alt_outlined,
                            label: 'Capture Photo',
                            color: VentlyColors.berryMagenta,
                            onTap: () => _selectStoryPreset(
                              category: 'funny_confessions',
                              mood: 'happy',
                            ),
                          ),
                          _StoryCreateOption(
                            icon: Icons.image_outlined,
                            label: 'Gallery',
                            color: const Color(0xFFF79ABD),
                            onTap: () => _selectStoryPreset(
                              category: 'healing_corner',
                              mood: 'healing',
                            ),
                          ),
                          _StoryCreateOption(
                            icon: Icons.edit_note_rounded,
                            label: 'Text Only',
                            color: const Color(0xFF008F4C),
                            onTap: () => _selectStoryPreset(
                              category: 'late_night',
                              mood: 'overthinking',
                            ),
                          ),
                          _StoryCreateOption(
                            icon: Icons.mic_none_rounded,
                            label: 'Audio Note',
                            color: VentlyColors.berryMagenta,
                            pale: true,
                            onTap: () => _selectStoryPreset(
                              category: 'late_night',
                              mood: 'hopeful',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.74),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: VentlyColors.softMauve.withOpacity(0.38),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.visibility_outlined,
                                  color: VentlyColors.berryMagenta,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Privacy Settings',
                                        style: TextStyle(
                                          color: context.ink,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        'Friends only',
                                        style: TextStyle(
                                          color: context.ink,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _storyFriendsOnly,
                                  onChanged: (value) =>
                                      setState(() => _storyFriendsOnly = value),
                                  activeColor: VentlyColors.berryMagenta,
                                ),
                              ],
                            ),
                            Divider(
                              color: VentlyColors.softMauve.withOpacity(0.22),
                            ),
                            Row(
                              children: [
                                const Icon(
                                  Icons.timer_outlined,
                                  color: VentlyColors.berryMagenta,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Story Duration',
                                    style: TextStyle(
                                      color: context.ink,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                const Text(
                                  '24 Hours',
                                  style: TextStyle(
                                    color: VentlyColors.softMauve,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
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
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB91452),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      elevation: 8,
                      shadowColor: VentlyColors.berryMagenta.withOpacity(0.26),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Share to Story',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(Icons.send_rounded, color: Colors.white),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectStoryPreset({required String category, required String mood}) {
    setState(() {
      _category = category;
      _mood = mood;
    });
  }

  void _showPersonaPicker(
    BuildContext context,
    List<Persona> personas,
    Persona? active,
  ) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Post as',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: const Text('Default handle'),
                trailing: active == null ? const Icon(Icons.check) : null,
                onTap: () {
                  ref.read(activePersonaProvider.notifier).state = null;
                  Navigator.pop(ctx);
                },
              ),
              for (final p in personas)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: AnonymousAvatar(
                    seed: p.avatarSeed,
                    label: p.pseudonym,
                    size: 30,
                  ),
                  title: Text('@${p.pseudonym}'),
                  trailing: active?.personaId == p.personaId
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    ref.read(activePersonaProvider.notifier).state = p;
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBlocked(ModerationResult res) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(
              Icons.shield_outlined,
              color: Theme.of(ctx).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('Held back by safety AI'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in res.reasons) Text('• $r'),
            if (res.surfaceCrisisHelpline) ...[
              const SizedBox(height: 12),
              const Text(
                'If you\'re in crisis right now, you\'re not alone:',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              for (final r in kCrisisResources)
                Text('• ${r.label} — ${r.reach}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmWarn(ModerationResult res) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: const Text('Heads up'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in res.reasons) Text('• $r'),
                if (res.surfaceCrisisHelpline) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'We care about you. Crisis lines are available 24/7.',
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Edit'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Post anyway'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _ComposeColorSwatch extends StatelessWidget {
  const _ComposeColorSwatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final outline = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).dividerColor.withOpacity(0.55);
    final checkColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : const Color(0xFF21161B);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: outline, width: selected ? 3 : 1),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: outline.withOpacity(0.2),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: selected
                    ? Icon(Icons.check_rounded, color: checkColor, size: 22)
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryCreateOption extends StatelessWidget {
  const _StoryCreateOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.pale = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool pale;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.68),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.38)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: pale ? const Color(0xFFFFEAF1) : color,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: pale ? color : Colors.white, size: 26),
            ),
            const SizedBox(height: 14),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small preview chip rendered above the editor when a photo is
/// staged. Tap "✕" to discard before sending.
class _PendingImageChip extends StatelessWidget {
  const _PendingImageChip({required this.bytes, required this.onClear});
  final Uint8List bytes;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.memory(
              bytes,
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: InkWell(
              onTap: onClear,
              customBorder: const CircleBorder(),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
